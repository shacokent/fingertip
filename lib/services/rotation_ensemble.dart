import 'dart:typed_data';

/// Clockwise rotations preserve planar RGB/NCHW channel ordering.
Float32List rotateNchw(Float32List input, int turns, {int side = 128}) {
  final plane = side * side;
  if (side <= 0 || input.length != 3 * plane) {
    throw ArgumentError('Expected three square RGB planes.');
  }
  final rotation = turns % 4;
  final output = Float32List(input.length);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final (sx, sy) = switch (rotation) {
        1 => (y, side - 1 - x),
        2 => (side - 1 - x, side - 1 - y),
        3 => (side - 1 - y, x),
        _ => (x, y),
      };
      for (var channel = 0; channel < 3; channel++) {
        output[channel * plane + y * side + x] =
            input[channel * plane + sy * side + sx];
      }
    }
  }
  return output;
}

List<double> restoreMaskOrientation(
  List<double> input,
  int turns, {
  int side = 128,
}) {
  if (side <= 0 || input.length != side * side) {
    throw ArgumentError('Expected a square probability map.');
  }
  final rotation = turns % 4;
  final output = List<double>.filled(input.length, 0);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final (rx, ry) = switch (rotation) {
        1 => (side - 1 - y, x),
        2 => (side - 1 - x, side - 1 - y),
        3 => (y, side - 1 - x),
        _ => (x, y),
      };
      output[y * side + x] = input[ry * side + rx];
    }
  }
  return output;
}
