import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/services/rotation_ensemble.dart';

void main() {
  test('RGB rotation keeps channels separate and reverses 180 degrees', () {
    final input = Float32List.fromList([
      1,
      2,
      3,
      4,
      11,
      12,
      13,
      14,
      21,
      22,
      23,
      24,
    ]);
    expect(rotateNchw(input, 2, side: 2), [
      4,
      3,
      2,
      1,
      14,
      13,
      12,
      11,
      24,
      23,
      22,
      21,
    ]);
  });
  test('all orientation maps restore the original spatial coordinates', () {
    final input = Float32List.fromList(List.generate(27, (i) => i.toDouble()));
    for (var turns = 0; turns < 4; turns++) {
      final rotated = rotateNchw(input, turns, side: 3);
      final restored = restoreMaskOrientation(
        rotated.sublist(0, 9),
        turns,
        side: 3,
      );
      expect(restored, input.sublist(0, 9));
    }
  });
  test('clockwise 90-degree rotation uses the expected matrix', () {
    final input = Float32List.fromList(
      List.generate(12, (i) => (i % 4 + 1).toDouble()),
    );
    expect(rotateNchw(input, 1, side: 2).sublist(0, 4), [3, 1, 4, 2]);
  });
  test('invalid tensor and probability sizes fail explicitly', () {
    expect(() => rotateNchw(Float32List(10), 2), throwsArgumentError);
    expect(() => restoreMaskOrientation([1], 0, side: 2), throwsArgumentError);
  });
}
