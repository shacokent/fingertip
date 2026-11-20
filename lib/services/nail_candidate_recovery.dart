import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'probability_contour.dart';
import 'segmentation_geometry.dart';

const _resolution = 128;
const _fingers = ['拇指', '食指', '中指', '无名指', '小指'];

/// Rechecks uncovered fingertips in the original-resolution photo. A hand
/// landmark only selects a search window: two local segmentations must agree
/// before a new nail can be returned. Existing masks are left untouched.
Future<List<NailRegion>> recoverPhotoNails({
  required Uint8List pngBytes,
  required int imageWidth,
  required int imageHeight,
  required List<NailRegion> nails,
  required List<HandObservation> hands,
  required Future<List<double>> Function(Float32List) predictCrop,
  void Function(String)? onStage,
}) async {
  if (imageWidth <= 0 ||
      imageHeight <= 0 ||
      hands.isEmpty ||
      nails.length >= 12) {
    return nails;
  }
  final photoSize = Size(imageWidth.toDouble(), imageHeight.toDouble());
  final targets = _targets(hands, photoSize)
      .where((target) => !nails.any((nail) => _coveredTarget(nail, target)))
      .toList();
  if (targets.isEmpty) return nails;
  final windows = await compute(_prepareWindows, (
    bytes: pngBytes,
    photoSize: photoSize,
    targets: targets,
  ));
  if (windows.isEmpty) return nails;

  final output = List<NailRegion>.of(nails);
  var nextId =
      1 + nails.fold<int>(-1, (largest, nail) => math.max(largest, nail.id));
  for (var index = 0; index < targets.length && output.length < 12; index++) {
    final target = targets[index];
    final candidates = <_Candidate>[];
    onStage?.call('复查指尖 ${index + 1}/${targets.length}');
    for (final window in windows[index]) {
      try {
        final prediction = await predictCrop(window.tensor);
        final current = await compute(_searchWindow, (
          crop: window.crop,
          target: target,
          image: photoSize,
          p: prediction,
        ));
        final matching = _agreedCandidate(current, candidates, output, target);
        if (matching != null) {
          final label = output.any((nail) => nail.label == target.label)
              ? '甲面 ${nextId + 1}'
              : target.label;
          final region = await compute(_trace, (
            candidate: matching,
            target: target,
            id: nextId,
            label: label,
          ));
          if (region != null) {
            output.add(region);
            nextId++;
            break;
          }
        }
        candidates.addAll(current);
      } catch (_) {
        // A failed supplementary window must not discard the full-photo result.
      }
    }
  }
  return output;
}

class _Target {
  const _Target(this.tip, this.down, this.length, this.label);
  final Offset tip, down;
  final double length;
  final String label;
  Offset get right => Offset(down.dy, -down.dx);
  Offset get aim => tip + down * (length * .22);
}

Iterable<_Target> _targets(List<HandObservation> hands, Size photo) sync* {
  final valid = hands
      .where((hand) => hand.points.length == 21)
      .take(2)
      .toList();
  final bounds = Offset.zero & photo;
  for (var hi = 0; hi < valid.length; hi++) {
    final hand = valid[hi];
    final confidences = hand.pointConfidences;
    Offset pixel(int i) => Offset(
      hand.points[i].dx * photo.width,
      hand.points[i].dy * photo.height,
    );
    for (var finger = 0; finger < _fingers.length; finger++) {
      final tipIndex = 4 + finger * 4, jointIndex = tipIndex - 1;
      // Vision estimates hidden points too. Use its confidence when supplied;
      // MediaPipe does not expose confidence on each individual joint.
      if (confidences != null &&
          (confidences.length != 21 ||
              !(confidences[tipIndex] >= .55 &&
                  confidences[jointIndex] >= .55))) {
        continue;
      }
      final tip = pixel(tipIndex);
      final vector = pixel(jointIndex) - tip;
      final length = vector.distance;
      if (!bounds.contains(tip) ||
          !length.isFinite ||
          length < 5 ||
          length > photo.shortestSide * .45) {
        continue;
      }
      final prefix = valid.length == 1
          ? ''
          : switch (hand.handedness.toLowerCase()) {
              'left' => '左手·',
              'right' => '右手·',
              _ => '第 ${hi + 1} 只手·',
            };
      yield _Target(tip, vector / length, length, '$prefix${_fingers[finger]}');
    }
  }
}

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

bool _coveredTarget(NailRegion nail, _Target target) =>
    nail.enabled &&
    _insideMask(nail, target.aim) &&
    (nail.center - target.aim).distance < target.length * .64;

bool _insideMask(NailRegion nail, Offset imagePoint) {
  final local = nail.toLocal(imagePoint);
  final u = local.dx / nail.width + .5, v = local.dy / nail.height + .5;
  if (!(u >= 0 && u < 1 && v >= 0 && v < 1)) return false;
  final x = (u * nail.maskWidth).floor(), y = (v * nail.maskHeight).floor();
  return nail.maskRgba[(y * nail.maskWidth + x) * 4 + 3] >= 128;
}

class _Crop {
  const _Crop(this.center, this.down, this.side);
  final Offset center, down;
  final double side;
  Offset get right => Offset(down.dy, -down.dx);
  double get step => side / _resolution;
  Offset imagePoint(double x, double y) =>
      center +
      right * ((x - _resolution / 2) * step) +
      down * ((y - _resolution / 2) * step);
  Offset cropPoint(Offset p) {
    final delta = p - center;
    return Offset(
      _dot(delta, right) / step + _resolution / 2 - .5,
      _dot(delta, down) / step + _resolution / 2 - .5,
    );
  }
}

typedef _Window = ({_Crop crop, Float32List tensor});

List<List<_Window>> _prepareWindows(
  ({Uint8List bytes, Size photoSize, List<_Target> targets}) input,
) {
  final photo = img.decodeImage(input.bytes);
  if (photo == null ||
      photo.width != input.photoSize.width ||
      photo.height != input.photoSize.height) {
    return const [];
  }
  const plane = _resolution * _resolution;
  return [
    for (final target in input.targets)
      [
        for (final (factor, rotate) in const [
          (2.6, true),
          (2.6, false),
          (3.8, true),
          (3.8, false),
        ])
          if (!rotate || target.down.dy.abs() < .95)
            _buildWindow(photo, target, factor, rotate, plane),
      ],
  ];
}

_Window _buildWindow(
  img.Image photo,
  _Target target,
  double factor,
  bool rotate,
  int plane,
) {
  final crop = _Crop(
    target.aim,
    rotate ? target.down : const Offset(0, 1),
    (target.length * factor)
        .clamp(18.0, math.max(18, math.min(photo.width, photo.height) * .78))
        .toDouble(),
  );
  final tensor = Float32List(plane * 3);
  for (var y = 0; y < _resolution; y++) {
    for (var x = 0; x < _resolution; x++) {
      final location = crop.imagePoint(x + .5, y + .5);
      final pixel = photo.getPixelInterpolate(
        (location.dx - .5).clamp(0, photo.width - 1),
        (location.dy - .5).clamp(0, photo.height - 1),
        interpolation: img.Interpolation.linear,
      );
      final offset = y * _resolution + x;
      tensor[offset] = pixel.r / 127.5 - 1;
      tensor[offset + plane] = pixel.g / 127.5 - 1;
      tensor[offset + plane * 2] = pixel.b / 127.5 - 1;
    }
  }
  return (crop: crop, tensor: tensor);
}

class _Candidate {
  const _Candidate(
    this.crop,
    this.center,
    this.pixels,
    this.probabilities,
    this.area,
    this.mean,
    this.score,
  );
  final _Crop crop;
  final Offset center;
  final List<int> pixels;
  final List<double> probabilities;
  final double area, mean, score;

  Offset imagePoint(int pixel) =>
      crop.imagePoint(pixel % _resolution + .5, pixel ~/ _resolution + .5);
}

List<_Candidate> _searchWindow(
  ({_Crop crop, _Target target, Size image, List<double> p}) input,
) {
  final crop = input.crop, target = input.target;
  final bounds = Offset.zero & input.image;
  final candidates = <_Candidate>[];
  for (final component in connectedComponents(
    input.p,
    _resolution,
    _resolution,
    threshold: .38,
    minArea: 12,
  )) {
    final area = component.length * crop.step * crop.step;
    final normalizedArea = area / (target.length * target.length);
    if (area < 13 || normalizedArea < .035 || normalizedArea > 1.5) continue;
    var center = Offset.zero;
    var sum = 0.0, peak = 0.0;
    var insideCount = 0;
    for (final pixel in component) {
      final point = crop.imagePoint(
        pixel % _resolution + .5,
        pixel ~/ _resolution + .5,
      );
      center += point;
      if (bounds.contains(point)) insideCount++;
      final value = input.p[pixel];
      sum += value;
      peak = math.max(peak, value);
    }
    center /= component.length.toDouble();
    final mean = sum / component.length;
    if (insideCount < component.length * .94 || mean < .64 || peak < .84) {
      continue;
    }
    final delta = center - target.tip;
    final along = _dot(delta, target.down) / target.length;
    final across = _dot(delta, target.right).abs() / target.length;
    if (along < -.47 || along > .82 || across > .55) continue;
    final score = mean - (along - .10).abs() * .20 - across * .22;
    candidates.add(
      _Candidate(crop, center, component, input.p, area, mean, score),
    );
  }
  candidates.sort((a, b) => b.score.compareTo(a.score));
  return candidates.take(3).toList();
}

_Candidate? _agreedCandidate(
  List<_Candidate> current,
  List<_Candidate> previous,
  List<NailRegion> existing,
  _Target target,
) {
  for (final a in current) {
    for (final b in previous) {
      // Near-identical crops do not count as corroboration.
      if ((a.crop.down - b.crop.down).distance < .24 &&
          (a.crop.side - b.crop.side).abs() < a.crop.side * .15) {
        continue;
      }
      if ((a.center - b.center).distance > math.max(4, target.length * .21) ||
          a.area / b.area < .51 ||
          a.area / b.area > 1.96 ||
          math.max(a.mean, b.mean) < .70) {
        continue;
      }
      final chosen = a.score >= b.score - .035 && a.crop.side < b.crop.side
          ? a
          : b.score >= a.score - .035 && b.crop.side < a.crop.side
          ? b
          : a.score >= b.score
          ? a
          : b;
      if (!_duplicates(chosen, existing)) return chosen;
    }
  }
  return null;
}

bool _duplicates(_Candidate candidate, List<NailRegion> existing) {
  for (final nail in existing) {
    if (!nail.enabled) continue;
    if ((nail.center - candidate.center).distance >
        math.max(nail.width, nail.height) + math.sqrt(candidate.area)) {
      continue;
    }
    var count = 0, overlap = 0;
    final stride = math.max(1, candidate.pixels.length ~/ 120);
    for (var i = 0; i < candidate.pixels.length; i += stride) {
      count++;
      if (_insideMask(nail, candidate.imagePoint(candidate.pixels[i]))) {
        overlap++;
      }
    }
    if (overlap >= count * .30 ||
        (_insideMask(nail, candidate.center) &&
            (nail.center - candidate.center).distance <
                math.sqrt(candidate.area) * .42)) {
      return true;
    }
  }
  return false;
}

NailRegion? _trace(
  ({_Candidate candidate, _Target target, int id, String label}) input,
) {
  final candidate = input.candidate, target = input.target;
  var xmin = double.infinity, ymin = double.infinity;
  var xmax = -double.infinity, ymax = -double.infinity;
  final component = Uint8List(_resolution * _resolution);
  for (final pixel in candidate.pixels) {
    component[pixel] = 1;
    final location = candidate.imagePoint(pixel) - candidate.center;
    final x = _dot(location, target.right), y = _dot(location, target.down);
    xmin = math.min(xmin, x);
    ymin = math.min(ymin, y);
    xmax = math.max(xmax, x);
    ymax = math.max(ymax, y);
  }
  final step = candidate.crop.step;
  final width = xmax - xmin + 3 * step, height = ymax - ymin + 3 * step;
  if (math.min(width, height) < math.max(3, target.length * .11) ||
      math.max(width, height) > target.length * 1.78 ||
      math.max(width, height) / math.min(width, height) > 4.3) {
    return null;
  }
  final center =
      candidate.center +
      target.right * ((xmin + xmax) / 2) +
      target.down * ((ymin + ymax) / 2);
  final fieldWidth = (width / step).ceil().clamp(5, _resolution);
  final fieldHeight = (height / step).ceil().clamp(5, _resolution);
  double probability(Offset p) {
    final loc = candidate.crop.cropPoint(p);
    final x = loc.dx.floor(), y = loc.dy.floor();
    final tx = loc.dx - x, ty = loc.dy - y;
    var value = 0.0;
    for (var dy = 0; dy < 2; dy++) {
      for (var dx = 0; dx < 2; dx++) {
        final px = x + dx, py = y + dy;
        if (px < 0 || px >= _resolution || py < 0 || py >= _resolution) {
          continue;
        }
        final index = py * _resolution + px;
        if (component[index] != 0) {
          value +=
              candidate.probabilities[index] *
              (dx == 0 ? 1 - tx : tx) *
              (dy == 0 ? 1 - ty : ty);
        }
      }
    }
    return value.clamp(0, 1).toDouble();
  }

  final field = [
    for (var y = 0; y < fieldHeight; y++)
      for (var x = 0; x < fieldWidth; x++)
        probability(
          center +
              target.right * (((x + .5) / fieldWidth - .5) * width) +
              target.down * (((y + .5) / fieldHeight - .5) * height),
        ),
  ];
  const maskWidth = 96, maskHeight = 144;
  final mask = refineProbabilityContour(
    field,
    fieldWidth,
    fieldHeight,
    outputWidth: maskWidth,
    outputHeight: maskHeight,
    threshold: .40,
    simplifyTolerance: .52,
    maxSmoothing: .62,
  );
  if (!mask.contains(255)) return null;
  return NailRegion(
    id: input.id,
    label: input.label,
    center: center,
    width: width,
    height: height,
    angle: math.atan2(target.down.dy, target.down.dx) - math.pi / 2,
    maskRgba: mask,
    maskWidth: maskWidth,
    maskHeight: maskHeight,
  );
}
