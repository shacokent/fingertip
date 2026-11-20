import 'dart:math' as math;
import 'dart:typed_data';

export 'probability_contour.dart' show refineProbabilityContour;

/// Cleans a single accepted nail, not the detection probability map. Distances
/// are local mask pixels; the adjustment never changes candidate counts.
Uint8List refineNailMask(
  Uint8List rgba,
  int width,
  int height, {
  double expansion = .65,
  double feather = .35,
  bool closeHoles = true,
}) {
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw ArgumentError('Mask dimensions do not match the pixels.');
  }
  if (!expansion.isFinite || !feather.isFinite || feather < 0) {
    throw ArgumentError('Mask adjustments must be finite.');
  }
  var binary = Uint8List(width * height);
  for (var i = 0; i < binary.length; i++) {
    // The old probability-derived edge often has low opacity despite belonging
    // to a validated nail. Treat it as coverage, then feather only the outline.
    binary[i] = rgba[i * 4 + 3] >= 64 ? 1 : 0;
  }
  _removeIsolatedPixels(binary, width, height);
  if (!binary.contains(1)) return Uint8List(rgba.length);
  if (closeHoles) {
    final closed = _erode(_dilate(binary, width, height), width, height);
    // Closing fills tiny border notches, but finite-image erosion can shave
    // confirmed corners or tips. Never discard original connected coverage.
    for (var i = 0; i < binary.length; i++) {
      closed[i] |= binary[i];
    }
    binary = closed;
    _fillHoles(binary, width, height);
  }
  final toInside = _distance(binary, width, height, 1);
  final toOutside = _distance(binary, width, height, 0);
  final output = Uint8List(rgba.length);
  final edgeWidth = math.max(.15, feather);
  for (var i = 0; i < binary.length; i++) {
    var signed = toOutside[i] - toInside[i];
    signed += binary[i] == 1 ? -.5 : .5;
    final t = ((signed + expansion) / edgeWidth + .5).clamp(0.0, 1.0);
    final alpha = (t * t * (3 - 2 * t) * 255).round();
    final p = i * 4;
    output[p] = output[p + 1] = output[p + 2] = output[p + 3] = alpha;
  }
  return output;
}

Uint8List _dilate(Uint8List input, int width, int height) {
  final result = Uint8List(input.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx >= 0 &&
              ny >= 0 &&
              nx < width &&
              ny < height &&
              input[ny * width + nx] == 1) {
            result[y * width + x] = 1;
          }
        }
      }
    }
  }
  return result;
}

Uint8List _erode(Uint8List input, int width, int height) {
  final result = Uint8List(input.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      var keep = true;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 ||
              ny < 0 ||
              nx >= width ||
              ny >= height ||
              input[ny * width + nx] == 0) {
            keep = false;
          }
        }
      }
      result[y * width + x] = keep ? 1 : 0;
    }
  }
  return result;
}

void _removeIsolatedPixels(Uint8List mask, int width, int height) {
  final isolated = <int>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = y * width + x;
      if (mask[index] == 0) continue;
      var neighbor = false;
      for (var dy = -1; dy <= 1 && !neighbor; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final nx = x + dx, ny = y + dy;
          if (nx >= 0 &&
              ny >= 0 &&
              nx < width &&
              ny < height &&
              mask[ny * width + nx] != 0) {
            neighbor = true;
            break;
          }
        }
      }
      if (!neighbor) isolated.add(index);
    }
  }
  for (final index in isolated) {
    mask[index] = 0;
  }
}

void _fillHoles(Uint8List mask, int width, int height) {
  final outside = Uint8List(mask.length);
  final queue = <int>[];
  void visit(int index) {
    if (mask[index] == 0 && outside[index] == 0) {
      outside[index] = 1;
      queue.add(index);
    }
  }

  for (var x = 0; x < width; x++) {
    visit(x);
    visit((height - 1) * width + x);
  }
  for (var y = 0; y < height; y++) {
    visit(y * width);
    visit(y * width + width - 1);
  }
  for (var cursor = 0; cursor < queue.length; cursor++) {
    final index = queue[cursor], x = index % width, y = index ~/ width;
    if (x > 0) visit(index - 1);
    if (x + 1 < width) visit(index + 1);
    if (y > 0) visit(index - width);
    if (y + 1 < height) visit(index + width);
  }
  for (var i = 0; i < mask.length; i++) {
    if (outside[i] == 0) mask[i] = 1;
  }
}

Float32List _distance(Uint8List mask, int width, int height, int target) {
  final d = Float32List(mask.length);
  final far = (width + height).toDouble();
  for (var i = 0; i < d.length; i++) {
    d[i] = mask[i] == target ? 0 : far;
  }
  const diagonal = 1.41421356237;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (x > 0) d[i] = math.min(d[i], d[i - 1] + 1);
      if (y > 0) {
        d[i] = math.min(d[i], d[i - width] + 1);
        if (x > 0) d[i] = math.min(d[i], d[i - width - 1] + diagonal);
        if (x + 1 < width) d[i] = math.min(d[i], d[i - width + 1] + diagonal);
      }
    }
  }
  for (var y = height - 1; y >= 0; y--) {
    for (var x = width - 1; x >= 0; x--) {
      final i = y * width + x;
      if (x + 1 < width) d[i] = math.min(d[i], d[i + 1] + 1);
      if (y + 1 < height) {
        d[i] = math.min(d[i], d[i + width] + 1);
        if (x > 0) d[i] = math.min(d[i], d[i + width - 1] + diagonal);
        if (x + 1 < width) d[i] = math.min(d[i], d[i + width + 1] + diagonal);
      }
    }
  }
  return d;
}
