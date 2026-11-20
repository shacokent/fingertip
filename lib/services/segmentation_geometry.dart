import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import '../models/nail_models.dart';
import 'mask_refinement.dart';

/// Fraction of the visible nail mask supported by one aligned model view.
double nailViewSupport(
  NailRegion nail,
  List<double> probabilities,
  Rect view, {
  int side = 128,
}) {
  if (probabilities.length != side * side || view.isEmpty) return 0;
  final ca = math.cos(nail.angle), sa = math.sin(nail.angle);
  final ex = (ca.abs() * nail.width + sa.abs() * nail.height) / 2;
  final ey = (sa.abs() * nail.width + ca.abs() * nail.height) / 2;
  final x0 = (((nail.center.dx - ex - view.left) / view.width) * side)
      .floor()
      .clamp(0, side);
  final x1 = (((nail.center.dx + ex - view.left) / view.width) * side)
      .ceil()
      .clamp(0, side);
  final y0 = (((nail.center.dy - ey - view.top) / view.height) * side)
      .floor()
      .clamp(0, side);
  final y1 = (((nail.center.dy + ey - view.top) / view.height) * side)
      .ceil()
      .clamp(0, side);
  var total = 0, supported = 0;
  for (var y = y0; y < y1; y++) {
    final dy = view.top + (y + .5) / side * view.height - nail.center.dy;
    for (var x = x0; x < x1; x++) {
      final dx = view.left + (x + .5) / side * view.width - nail.center.dx;
      final u = .5 + (ca * dx + sa * dy) / nail.width;
      final v = .5 + (-sa * dx + ca * dy) / nail.height;
      if (u < 0 || u >= 1 || v < 0 || v >= 1) continue;
      final i =
          (v * nail.maskHeight).floor() * nail.maskWidth +
          (u * nail.maskWidth).floor();
      if (nail.maskRgba[i * 4 + 3] < 128) continue;
      total++;
      if (probabilities[y * side + x] >= _nailThreshold) supported++;
    }
  }
  return total == 0 ? 0 : supported / total;
}

/// Eight-connected components. Empty model output stays empty; no template fill.
List<List<int>> connectedComponents(
  List<double> p,
  int width,
  int height, {
  double threshold = .5,
  int minArea = 3,
}) {
  if (width < 0 || height < 0) {
    throw ArgumentError('Probability map dimensions must be non-negative.');
  }
  if (p.length != width * height) {
    throw ArgumentError('Probability map dimensions do not match.');
  }
  final visited = Uint8List(p.length);
  final result = <List<int>>[];
  for (var start = 0; start < p.length; start++) {
    if (visited[start] != 0 || !p[start].isFinite || p[start] < threshold) {
      continue;
    }
    final queue = <int>[start];
    visited[start] = 1;
    for (var q = 0; q < queue.length; q++) {
      final x = queue[q] % width, y = queue[q] ~/ width;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) continue;
          final i = ny * width + nx;
          if (visited[i] == 0 && p[i].isFinite && p[i] >= threshold) {
            visited[i] = 1;
            queue.add(i);
          }
        }
      }
    }
    if (queue.length >= minArea) result.add(queue);
  }
  return result;
}

const _nailThreshold = .38;
const _nailMinMean = .57;
const _nailMinArea = 3;
const _nailMaxFraction = .08;

/// Validates each connected prediction before it may participate in fusion.
/// Kept pixels retain the model's original probability; rejected pixels are 0.
List<double> filterNailProbabilities(
  List<double> probabilities,
  int width,
  int height, {
  double maxFraction = _nailMaxFraction,
}) {
  if (!maxFraction.isFinite || maxFraction <= 0 || maxFraction > 1) {
    throw ArgumentError.value(maxFraction, 'maxFraction');
  }
  final components = connectedComponents(
    probabilities,
    width,
    height,
    threshold: _nailThreshold,
    minArea: _nailMinArea,
  );
  final kept = List<double>.filled(probabilities.length, 0);
  for (final pixels in components) {
    if (pixels.length > width * height * maxFraction) continue;
    final mean =
        pixels.fold<double>(0, (sum, i) => sum + probabilities[i]) /
        pixels.length;
    if (mean < _nailMinMean) continue;
    for (final i in pixels) {
      kept[i] = probabilities[i];
    }
  }
  return kept;
}

/// Maps must be in the same canonical orientation and have identical dimensions.
/// Filtering before max prevents a rejected view's background from being revived.
List<double> mergeValidatedProbabilities(
  List<List<double>> views,
  int width,
  int height, {
  double maxFraction = _nailMaxFraction,
}) {
  if (width < 0 || height < 0) {
    throw ArgumentError('Probability map dimensions must be non-negative.');
  }
  final merged = List<double>.filled(width * height, 0);
  if (!maxFraction.isFinite || maxFraction <= 0 || maxFraction > 1) {
    throw ArgumentError.value(maxFraction, 'maxFraction');
  }
  for (final view in views) {
    final filtered = filterNailProbabilities(
      view,
      width,
      height,
      maxFraction: maxFraction,
    );
    for (var i = 0; i < merged.length; i++) {
      merged[i] = math.max(merged[i], filtered[i]);
    }
  }
  return merged;
}

double _principalAngle(
  List<int> pixels,
  Offset center,
  int maskWidth,
  int maskHeight,
  int imageWidth,
  int imageHeight,
) {
  var xx = 0.0, yy = 0.0, xy = 0.0;
  for (final i in pixels) {
    final dx = ((i % maskWidth + .5) / maskWidth - center.dx) * imageWidth;
    final dy = ((i ~/ maskWidth + .5) / maskHeight - center.dy) * imageHeight;
    xx += dx * dx;
    yy += dy * dy;
    xy += dx * dy;
  }
  var angle = .5 * math.atan2(2 * xy, xx - yy) - math.pi / 2;
  while (angle > math.pi / 2) {
    angle -= math.pi;
  }
  while (angle < -math.pi / 2) {
    angle += math.pi;
  }
  return angle;
}

List<NailRegion> extractNails(
  List<double> probabilities,
  int maskWidth,
  int maskHeight,
  int imageWidth,
  int imageHeight, {
  List<HandObservation> hands = const [],
  bool alreadyFiltered = false,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) {
    throw ArgumentError('Image dimensions must be positive.');
  }
  final working = alreadyFiltered
      ? probabilities
      : filterNailProbabilities(probabilities, maskWidth, maskHeight);
  final components = connectedComponents(
    working,
    maskWidth,
    maskHeight,
    threshold: _nailThreshold,
    minArea: _nailMinArea,
  );
  final candidates = <({List<int> pixels, Offset center, double confidence})>[];
  for (final component in components) {
    // Several accepted views may join after fusion. The normal path still
    // applies the validated 8% cap; explicit prefiltered input permits 20%.
    final maxFraction = alreadyFiltered ? .2 : _nailMaxFraction;
    if (component.length > maskWidth * maskHeight * maxFraction) continue;
    final meanProbability =
        component.fold<double>(0, (sum, i) => sum + working[i]) /
        component.length;
    var sx = 0.0, sy = 0.0;
    for (final i in component) {
      sx += (i % maskWidth + .5) / maskWidth;
      sy += (i ~/ maskWidth + .5) / maskHeight;
    }
    final center = Offset(sx / component.length, sy / component.length);
    candidates.add((
      pixels: component,
      center: center,
      confidence: meanProbability,
    ));
  }
  candidates.sort((a, b) {
    final confidence = b.confidence.compareTo(a.confidence);
    return confidence != 0
        ? confidence
        : b.pixels.length.compareTo(a.pixels.length);
  });
  final usedFingers = <int>{};
  final results = <NailRegion>[];
  const names = ['拇指', '食指', '中指', '无名指', '小指'];
  const tips = [4, 8, 12, 16, 20];
  const joints = [3, 7, 11, 15, 19];
  final validHands = hands
      .where(
        (h) =>
            h.points.length == 21 &&
            h.points.every((p) => p.dx.isFinite && p.dy.isFinite),
      )
      .take(2)
      .toList();
  final targets =
      <
        ({int key, int handIndex, int finger, Offset target, Offset direction})
      >[];
  for (var hi = 0; hi < validHands.length; hi++) {
    final hand = validHands[hi];
    for (var f = 0; f < 5; f++) {
      final tip = hand.points[tips[f]], joint = hand.points[joints[f]];
      final direction = Offset(
        (joint.dx - tip.dx) * imageWidth,
        (joint.dy - tip.dy) * imageHeight,
      );
      // A missing/degenerate joint must not invent an orientation or identity.
      if (direction.distance < 1) continue;
      targets.add((
        key: hi * 5 + f,
        handIndex: hi,
        finger: f,
        target: Offset.lerp(tip, joint, .24)!,
        direction: direction,
      ));
    }
  }
  String handPrefix(int index) {
    String side(HandObservation hand) =>
        switch (hand.handedness.toLowerCase()) {
          'left' => '左手',
          'right' => '右手',
          _ => '手',
        };
    final label = side(validHands[index]);
    final duplicate = validHands.where((h) => side(h) == label).length > 1;
    return duplicate ? '$label${index + 1}' : label;
  }

  for (final candidate in candidates) {
    if (results.length >= 12) break;
    var label = '甲面 ${results.length + 1}';
    var angle = _principalAngle(
      candidate.pixels,
      candidate.center,
      maskWidth,
      maskHeight,
      imageWidth,
      imageHeight,
    );
    var bestDistance = double.infinity;
    ({int key, int handIndex, int finger, Offset target, Offset direction})?
    nearest;
    for (final target in targets) {
      final distance = (target.target - candidate.center).distance;
      if (distance < bestDistance) {
        bestDistance = distance;
        nearest = target;
      }
    }
    // Hand landmarks provide identity/direction only. An uncertain match must
    // never erase a candidate supported by the nail segmentation model.
    if (nearest != null &&
        bestDistance <= .14 &&
        !usedFingers.contains(nearest.key)) {
      final prefix = validHands.length > 1
          ? '${handPrefix(nearest.handIndex)}·'
          : '';
      label = '$prefix${names[nearest.finger]}';
      angle =
          math.atan2(nearest.direction.dy, nearest.direction.dx) - math.pi / 2;
      usedFingers.add(nearest.key);
    }
    final mean = Offset(
      candidate.center.dx * imageWidth,
      candidate.center.dy * imageHeight,
    );
    final ca = math.cos(angle), sa = math.sin(angle);
    var xmin = double.infinity, xmax = -double.infinity;
    var ymin = double.infinity, ymax = -double.infinity;
    for (final i in candidate.pixels) {
      final dx = (i % maskWidth + .5) / maskWidth * imageWidth - mean.dx;
      final dy = (i ~/ maskWidth + .5) / maskHeight * imageHeight - mean.dy;
      final x = ca * dx + sa * dy, y = -sa * dx + ca * dy;
      xmin = math.min(xmin, x);
      xmax = math.max(xmax, x);
      ymin = math.min(ymin, y);
      ymax = math.max(ymax, y);
    }
    final padding = math.max(imageWidth / maskWidth, imageHeight / maskHeight);
    xmin -= padding;
    xmax += padding;
    ymin -= padding;
    ymax += padding;
    final localCenter = Offset((xmin + xmax) / 2, (ymin + ymax) / 2);
    final center =
        mean +
        Offset(
          ca * localCenter.dx - sa * localCenter.dy,
          sa * localCenter.dx + ca * localCenter.dy,
        );
    final width = xmax - xmin, height = ymax - ymin;
    const mw = 64, mh = 96;
    final rgba = Uint8List(mw * mh * 4);
    final member = Uint8List(maskWidth * maskHeight);
    for (final i in candidate.pixels) {
      member[i] = 1;
    }
    // Bilinear interpolation of this component only, never other predictions.
    double sample(double x, double y) {
      final ix = x.floor(),
          iy = y.floor(),
          fx = x - x.floor(),
          fy = y - y.floor();
      var value = 0.0;
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final px = ix + dx, py = iy + dy;
          if (px < 0 || py < 0 || px >= maskWidth || py >= maskHeight) continue;
          final i = py * maskWidth + px;
          if (member[i] == 0) continue;
          value +=
              working[i] * (dx == 0 ? 1 - fx : fx) * (dy == 0 ? 1 - fy : fy);
        }
      }
      return ((value - .28) / .5).clamp(0.0, 1.0);
    }

    for (var y = 0; y < mh; y++) {
      for (var x = 0; x < mw; x++) {
        final lx = ((x + .5) / mw - .5) * width;
        final ly = ((y + .5) / mh - .5) * height;
        final px = center.dx + ca * lx - sa * ly;
        final py = center.dy + sa * lx + ca * ly;
        final alpha = sample(
          px / imageWidth * maskWidth - .5,
          py / imageHeight * maskHeight - .5,
        );
        final i = (y * mw + x) * 4, a = (alpha * 255).round();
        rgba[i] = rgba[i + 1] = rgba[i + 2] = rgba[i + 3] = a;
      }
    }
    results.add(
      NailRegion(
        id: results.length,
        label: label,
        center: center,
        width: width,
        height: height,
        angle: angle,
        maskRgba: refineNailMask(rgba, mw, mh),
      ),
    );
  }
  results.sort((a, b) => a.center.dx.compareTo(b.center.dx));
  return results;
}
