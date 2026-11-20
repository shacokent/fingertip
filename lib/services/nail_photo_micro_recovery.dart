import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'nail_photo_candidates.dart';
import 'segmentation_geometry.dart';

const _side = 128;
const _pixels = _side * _side;
const _modelFloor = .38;

/// Rechecks small exposed plates near accepted nails at native photo scale.
/// Two model orientations must agree. A light polish cohort can additionally
/// separate touching, similarly painted slivers before the model checks them.
Future<List<NailRegion>> recoverMicroPhotoNails({
  required Uint8List pngBytes,
  required int imageWidth,
  required int imageHeight,
  required List<NailRegion> nails,
  required List<HandObservation> hands,
  required PhotoViewPredictor predictView,
  int firstUnusedId = 0,
  void Function(String)? onStage,
}) async {
  final anchors = nails
      .where((nail) => nail.enabled && !nail.isManual)
      .toList();
  if (anchors.length < 3 || anchors.length >= 10 || nails.length >= 12) {
    return nails;
  }
  final prepared = await compute(_prepare, (
    bytes: pngBytes,
    width: imageWidth,
    height: imageHeight,
    anchors: anchors,
    handCount: hands.length,
  ));
  if (prepared.windows.isEmpty) return nails;
  final result = List<NailRegion>.of(nails);
  var nextId = math.max(
    firstUnusedId,
    result.fold<int>(-1, (id, nail) => math.max(id, nail.id)) + 1,
  );
  for (final window in prepared.windows) {
    onStage?.call('复查指尖小甲面');
    final first = await predictView(window.tensor, 0);
    final second = await predictView(window.tensor, 2);
    if (first.length != _pixels || second.length != _pixels) continue;
    final recovered = await compute(_findNails, (
      window: window,
      first: first,
      second: second,
      nails: result,
      medianArea: prepared.medianArea,
      medianSpan: prepared.medianSpan,
    ));
    for (final local in recovered) {
      final center =
          local.center + Offset(window.left.toDouble(), window.top.toDouble());
      result.add(
        NailRegion(
          id: nextId,
          label: '甲面 ${nextId + 1}',
          center: center,
          width: local.width,
          height: local.height,
          angle: local.angle,
          maskRgba: local.maskRgba,
          maskWidth: local.maskWidth,
          maskHeight: local.maskHeight,
        ),
      );
      nextId++;
      if (result.length >= 12 || result.length >= nails.length + 2) {
        return result;
      }
    }
  }
  return result;
}

class _Window {
  const _Window(this.left, this.top, this.side, this.tensor, this.polish);

  final int left, top, side;
  final Float32List tensor;
  final List<int> polish;

  double get scale => side / _side;
  Offset toPhoto(Offset point) =>
      Offset(left.toDouble(), top.toDouble()) + point * scale;
}

typedef _Preparation = ({
  List<_Window> windows,
  double medianArea,
  double medianSpan,
});

_Preparation _prepare(
  ({
    Uint8List bytes,
    int width,
    int height,
    List<NailRegion> anchors,
    int handCount,
  })
  input,
) {
  final photo = img.decodePng(input.bytes);
  if (photo == null ||
      photo.width != input.width ||
      photo.height != input.height) {
    return (windows: [], medianArea: 0, medianSpan: 0);
  }
  final areas = [for (final nail in input.anchors) _area(nail)];
  final spans = [
    for (final nail in input.anchors) math.max(nail.width, nail.height),
  ];
  final area = _median(areas);
  final span = _median(spans);
  if (area < 16 || span < 8) {
    return (windows: [], medianArea: area, medianSpan: span);
  }
  final polish = _polishWindows(photo, input.anchors, area);
  if (polish.isNotEmpty ||
      (input.handCount == 1 && input.anchors.length >= 5)) {
    return (windows: polish, medianArea: area, medianSpan: span);
  }
  final selected = <NailRegion>{};
  for (final value in <double Function(NailRegion)>[
    (nail) => nail.center.dx,
    (nail) => -nail.center.dx,
    (nail) => nail.center.dy,
    (nail) => -nail.center.dy,
  ]) {
    selected.add(input.anchors.reduce((a, b) => value(a) <= value(b) ? a : b));
  }
  while (selected.length < math.min(5, input.anchors.length)) {
    double distance(NailRegion nail) => _nearest(nail.center, selected);
    selected.add(
      input.anchors
          .where((nail) => !selected.contains(nail))
          .reduce((a, b) => distance(a) >= distance(b) ? a : b),
    );
  }
  final windows = <_Window>[];
  for (final anchor in selected) {
    final side =
        (3.8 *
                math
                    .max(anchor.width, anchor.height)
                    .clamp(.85 * span, 1.2 * span))
            .round();
    final window = _crop(photo, anchor.center, side);
    if (window != null) windows.add(window);
  }
  return (windows: windows, medianArea: area, medianSpan: span);
}

_Window? _crop(
  img.Image photo,
  Offset center,
  int size, [
  List<int> Function(int left, int top, int side)? polish,
]) {
  final side = math.min(size, math.min(photo.width, photo.height));
  if (side < 24) return null;
  final left = (center.dx - side / 2).round().clamp(0, photo.width - side);
  final top = (center.dy - side / 2).round().clamp(0, photo.height - side);
  final sample = img.copyResize(
    img.copyCrop(photo, x: left, y: top, width: side, height: side),
    width: _side,
    height: _side,
    interpolation: img.Interpolation.average,
  );
  final tensor = Float32List(3 * _pixels);
  for (final pixel in sample) {
    final i = pixel.y * _side + pixel.x;
    tensor[i] = pixel.r / 127.5 - 1;
    tensor[i + _pixels] = pixel.g / 127.5 - 1;
    tensor[i + 2 * _pixels] = pixel.b / 127.5 - 1;
  }
  return _Window(
    left,
    top,
    side,
    tensor,
    polish?.call(left, top, side) ?? const [],
  );
}

class _Footprint {
  _Footprint(this.pixels, int stride) {
    var left = stride, right = 0, top = pixels.first ~/ stride, bottom = 0;
    var xSum = 0, ySum = 0;
    for (final pixel in pixels) {
      final x = pixel % stride, y = pixel ~/ stride;
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
      xSum += x;
      ySum += y;
    }
    box = Rect.fromLTRB(
      left.toDouble(),
      top.toDouble(),
      right + 1.0,
      bottom + 1.0,
    );
    center = Offset(xSum / pixels.length + .5, ySum / pixels.length + .5);
  }

  final List<int> pixels;
  late final Rect box;
  late final Offset center;

  double get span => math.max(box.width, box.height);
  double get aspect => span / math.min(box.width, box.height);
}

typedef _Piece = ({_Footprint footprint, double mean, double peak});

List<NailRegion> _findNails(
  ({
    _Window window,
    List<double> first,
    List<double> second,
    List<NailRegion> nails,
    double medianArea,
    double medianSpan,
  })
  input,
) {
  final w = input.window;
  final polish = w.polish;
  if (polish.isNotEmpty) {
    bool verified(List<double> field) {
      var count = 0;
      var peak = 0.0;
      for (final i in polish) {
        peak = math.max(peak, field[i]);
        if (field[i] >= _modelFloor) count++;
      }
      return count >= polish.length * .48 && peak >= .82;
    }

    if (!verified(input.first) || !verified(input.second)) return [];
    if (_overlap(_Footprint(polish, _side), w, input.nails) >= .19) return [];
    return _extract(w, polish);
  }
  List<_Piece> pieces(List<double> field) {
    final result = <_Piece>[];
    for (final pixels in connectedComponents(
      field,
      _side,
      _side,
      threshold: _modelFloor,
    )) {
      final area = pixels.length * w.scale * w.scale;
      if (area < input.medianArea * .075 || area > input.medianArea * .95) {
        continue;
      }
      var sum = 0.0, peak = 0.0;
      for (final i in pixels) {
        sum += field[i];
        peak = math.max(peak, field[i]);
      }
      final mean = sum / pixels.length;
      if (mean < .58 || peak < .80) continue;
      final foot = _Footprint(pixels, _side);
      final box = foot.box;
      if (box.left < 5 ||
          box.top < 5 ||
          box.right > _side - 5 ||
          box.bottom > _side - 5 ||
          math.min(box.width, box.height) < 4 ||
          foot.aspect > 4 ||
          _nearest(w.toPhoto(foot.center), input.nails) >
              input.medianSpan * 1.7 ||
          _overlap(foot, w, input.nails) >= .18) {
        continue;
      }
      result.add((footprint: foot, mean: mean, peak: peak));
    }
    return result;
  }

  final first = pieces(input.first);
  final second = pieces(input.second);
  final result = <NailRegion>[];
  for (final a in first) {
    final left = a.footprint;
    for (final b in second) {
      final right = b.footprint;
      if (math.max(a.mean, b.mean) < .61 ||
          math.max(a.peak, b.peak) < .86 ||
          (left.center - right.center).distance >
              .30 * math.max(left.span, right.span)) {
        continue;
      }
      final overlap = left.box.intersect(right.box);
      if (overlap.isEmpty) continue;
      final common = overlap.width * overlap.height;
      final combined =
          left.box.width * left.box.height +
          right.box.width * right.box.height -
          common;
      if (common < combined * .32) continue;
      result.addAll(_extract(w, a.mean >= b.mean ? left.pixels : right.pixels));
      break;
    }
  }
  return result;
}

List<NailRegion> _extract(_Window window, List<int> pixels) {
  final field = Float64List(_pixels);
  for (final i in pixels) {
    field[i] = 1;
  }
  return extractNails(
    field,
    _side,
    _side,
    window.side,
    window.side,
    alreadyFiltered: true,
  ).take(1).toList();
}

double _overlap(_Footprint piece, _Window window, List<NailRegion> nails) {
  final step = math.max(1, piece.pixels.length ~/ 160);
  var covered = 0, total = 0;
  for (var k = 0; k < piece.pixels.length; k += step) {
    final i = piece.pixels[k];
    final point = window.toPhoto(Offset(i % _side + .5, i ~/ _side + .5));
    if (nails.any((nail) => _contains(nail, point))) covered++;
    total++;
  }
  return covered / total;
}

bool _contains(NailRegion nail, Offset point) {
  if ((point.dx - nail.center.dx).abs() > nail.width + nail.height ||
      (point.dy - nail.center.dy).abs() > nail.width + nail.height) {
    return false;
  }
  final local = nail.toLocal(point);
  final u = local.dx / nail.width + .5, v = local.dy / nail.height + .5;
  if (u < 0 || u >= 1 || v < 0 || v >= 1) return false;
  final i =
      (v * nail.maskHeight).floor() * nail.maskWidth +
      (u * nail.maskWidth).floor();
  return nail.maskRgba[4 * i + 3] >= 128;
}

double _nearest(Offset point, Iterable<NailRegion> nails) => nails.fold(
  double.infinity,
  (distance, nail) => math.min(distance, (nail.center - point).distance),
);

double _area(NailRegion nail) {
  var count = 0;
  for (var i = 3; i < nail.maskRgba.length; i += 4) {
    if (nail.maskRgba[i] >= 128) count++;
  }
  return count * nail.width * nail.height / (nail.maskWidth * nail.maskHeight);
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  values.sort();
  final mid = values.length ~/ 2;
  return values.length.isOdd
      ? values[mid]
      : (values[mid - 1] + values[mid]) / 2;
}

class _Colors {
  final red = <double>[], green = <double>[], blue = <double>[];

  void add(img.Pixel pixel) {
    red.add(pixel.r.toDouble());
    green.add(pixel.g.toDouble());
    blue.add(pixel.b.toDouble());
  }

  int get length => red.length;

  ({double spread, double light}) get median {
    final r = _median(red), g = _median(green), b = _median(blue);
    return (
      spread: math.max(r, math.max(g, b)) - math.min(r, math.min(g, b)),
      light: (r + g + b) / 3,
    );
  }
}

List<_Window> _polishWindows(
  img.Image photo,
  List<NailRegion> anchors,
  double medianArea,
) {
  final lightValues = <double>[];
  for (final nail in anchors) {
    final core = _Colors(), surround = _Colors();
    final cos = math.cos(nail.angle), sin = math.sin(nail.angle);
    for (var sy = 0; sy < 19; sy++) {
      for (var sx = 0; sx < 19; sx++) {
        final u = (sx + .5) / 19, v = (sy + .5) / 19;
        final x = (u - .5) * nail.width, y = (v - .5) * nail.height;
        final pixel = photo.getPixelSafe(
          (nail.center.dx + cos * x - sin * y).round(),
          (nail.center.dy + sin * x + cos * y).round(),
        );
        if (!pixel.isValid) continue;
        final index =
            (v * nail.maskHeight).floor() * nail.maskWidth +
            (u * nail.maskWidth).floor();
        final alpha = nail.maskRgba[index * 4 + 3];
        if (alpha >= 200) core.add(pixel);
        if (alpha < 16) surround.add(pixel);
      }
    }
    if (core.length < 12 || surround.length < 12) continue;
    final c = core.median, s = surround.median;
    if (c.spread <= 22 &&
        c.light >= 125 &&
        s.spread - c.spread >= 18 &&
        c.light - s.light >= 20) {
      lightValues.add(c.light);
    }
  }
  if (lightValues.length < 3 || lightValues.length * 2 < anchors.length) {
    return [];
  }
  final floor = _median(lightValues) * .62 * 3;
  final scale = math.min(1.0, 768 / math.max(photo.width, photo.height));
  final width = (scale * photo.width).round(),
      height = (scale * photo.height).round();
  final sample = scale == 1
      ? photo
      : img.copyResize(
          photo,
          width: width,
          height: height,
          interpolation: img.Interpolation.average,
        );
  final area = medianArea * scale * scale;
  final raw = Uint8List(width * height);
  for (final p in sample) {
    final spread =
        math.max(p.r, math.max(p.g, p.b)) - math.min(p.r, math.min(p.g, p.b));
    if (spread <= 17 && p.r + p.g + p.b >= floor) raw[p.y * width + p.x] = 1;
  }
  final expanded = Uint8List(raw.length);
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final i = y * width + x;
      if (raw[i] == 0) continue;
      for (var dy = -1; dy <= 1; dy++) {
        final row = i + dy * width;
        expanded[row - 1] = expanded[row] = expanded[row + 1] = 1;
      }
    }
  }
  final mask = Float64List(raw.length);
  final radius = math.sqrt(area) * 2.2;
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final i = y * width + x;
      if (expanded[i] == 0) continue;
      var solid = true;
      for (var dy = -1; dy <= 1 && solid; dy++) {
        final row = i + dy * width;
        solid =
            expanded[row - 1] == 1 &&
            expanded[row] == 1 &&
            expanded[row + 1] == 1;
      }
      if (!solid) continue;
      final point = Offset((x + .5) / scale, (y + .5) / scale);
      if (_nearest(point, anchors) > (radius + math.sqrt(area)) / scale) {
        continue;
      }
      if (!anchors.any((nail) => _coversWithMargin(nail, point, 1 / scale))) {
        mask[i] = 1;
      }
    }
  }
  final regions = <({_Footprint footprint, double score})>[];
  for (final component in connectedComponents(
    mask,
    width,
    height,
    minArea: math.max(8, (.08 * area).round()),
  )) {
    if (component.length > 1.35 * area) continue;
    final foot = _Footprint(component, width);
    if (foot.aspect > 4.2 ||
        component.length < foot.box.width * foot.box.height * .19 ||
        _nearest(foot.center / scale, anchors) > radius / scale) {
      continue;
    }
    final core = _Colors(), surround = _Colors();
    final ring = <int>{};
    for (final i in component) {
      final x = i % width, y = i ~/ width;
      core.add(sample.getPixel(x, y));
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
          final neighbor = ny * width + nx;
          if (mask[neighbor] == 0) ring.add(neighbor);
        }
      }
    }
    for (final i in ring) {
      surround.add(sample.getPixel(i % width, i ~/ width));
    }
    if (surround.length < 12) continue;
    final c = core.median, s = surround.median;
    if (s.spread - c.spread < 14 || c.light - s.light < 17) continue;
    regions.add((
      footprint: foot,
      score: s.spread - c.spread + c.light - s.light,
    ));
  }
  regions.sort((a, b) => b.score.compareTo(a.score));
  final windows = <_Window>[];
  for (final region in regions.take(2)) {
    final foot = region.footprint;
    final support = foot.pixels.toSet();
    final window = _crop(
      photo,
      foot.center / scale,
      (foot.span / scale * 2.65).round(),
      (left, top, side) {
        final pixels = <int>[];
        for (var y = 0; y < _side; y++) {
          final py = ((top + (y + .5) * side / _side) * scale).floor();
          for (var x = 0; x < _side; x++) {
            final px = ((left + (x + .5) * side / _side) * scale).floor();
            if (support.contains(py * width + px)) pixels.add(y * _side + x);
          }
        }
        return pixels;
      },
    );
    if (window != null && window.polish.isNotEmpty) windows.add(window);
  }
  return windows;
}

bool _coversWithMargin(NailRegion nail, Offset point, double margin) {
  if (_contains(nail, point)) return true;
  for (final offset in [
    Offset(-margin, 0),
    Offset(margin, 0),
    Offset(0, -margin),
    Offset(0, margin),
  ]) {
    if (_contains(nail, point + offset)) return true;
  }
  return false;
}
