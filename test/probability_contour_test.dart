import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/probability_contour.dart';
import 'package:offline_nail_demo/services/segmentation_geometry.dart';

void main() {
  test(
    'photo contour suppresses sampling kinks without repainting the nail',
    () {
      const width = 64, height = 96;
      final mask = Uint8List(width * height * 4);
      for (var y = 8; y < 88; y++) {
        final left = y >= 18 && y < 78 && (y ~/ 3).isOdd ? 14 : 12;
        for (var x = left; x < 52; x++) {
          final index = (y * width + x) * 4;
          mask.fillRange(index, index + 4, 255);
        }
      }
      final nail = NailRegion(
        id: 7,
        label: '甲面',
        center: const Offset(91, 120),
        width: width.toDouble(),
        height: height.toDouble(),
        angle: .62,
        maskRgba: mask,
      );
      final refined = finishDetectedNailContour(nail);
      expect(refined.id, nail.id);
      expect(refined.center, nail.center);
      expect(refined.width, nail.width);
      expect(refined.height, nail.height);
      expect(refined.angle, nail.angle);
      expect(refined.maskWidth, 128);
      expect(refined.maskHeight, 192);

      double roughness(NailRegion candidate) {
        final w = candidate.maskWidth, h = candidate.maskHeight;
        final left = <double>[];
        for (var y = 22; y < 73; y++) {
          final row = ((y + .5) * h / height).floor();
          var edge = 0;
          while (candidate.maskRgba[(row * w + edge) * 4 + 3] < 128) {
            edge++;
          }
          left.add(edge * width / w);
        }
        var total = 0.0;
        for (var i = 1; i + 1 < left.length; i++) {
          total += (left[i - 1] - 2 * left[i] + left[i + 1]).abs();
        }
        return total;
      }

      final oldRoughness = roughness(nail);
      expect(roughness(refined), lessThan(oldRoughness * .7));
      int alpha(double x, double y) =>
          refined.maskRgba[((y * 2).floor() * refined.maskWidth +
                      (x * 2).floor()) *
                  4 +
              3];
      expect(
        alpha(12.75, 8.75),
        255,
        reason: 'Supported corner remains covered',
      );
      expect(alpha(10, 48), 0, reason: 'Does not grow polish onto the skin');
      expect(alpha(25, 40), 255, reason: 'No feathering in the nail interior');
      expect(
        finishDetectedNailContour(
          NailRegion.manual(2, const Offset(1, 1), 600),
        ).isManual,
        isTrue,
      );
    },
  );

  test('subpixel curved nail has solid coverage and a one-pixel AA edge', () {
    const width = 52, height = 76, outWidth = 156, outHeight = 228;
    const cx = 25.17, cy = 37.39, rx = 16.2, ry = 28.4;
    final probabilities = List<double>.generate(width * height, (index) {
      final dx = (index % width + .5 - cx) / rx;
      final dy = (index ~/ width + .5 - cy) / ry;
      final radius = math.sqrt(dx * dx + dy * dy);
      return (.5 + (1 - radius) * rx).clamp(0.0, 1.0);
    });
    final result = refineProbabilityContour(
      probabilities,
      width,
      height,
      outputWidth: outWidth,
      outputHeight: outHeight,
    );
    var sum = 0.0, weightedX = 0.0, weightedY = 0.0;
    var translucent = 0, occupied = 0;
    for (var y = 0; y < outHeight; y++) {
      for (var x = 0; x < outWidth; x++) {
        final alpha = result[(y * outWidth + x) * 4 + 3] / 255;
        final px = (x + .5) / outWidth * width;
        final py = (y + .5) / outHeight * height;
        sum += alpha;
        weightedX += px * alpha;
        weightedY += py * alpha;
        if (alpha > 0) occupied++;
        if (alpha > 0 && alpha < 1) translucent++;
        final radius = math.sqrt(
          math.pow((px - cx) / rx, 2) + math.pow((py - cy) / ry, 2),
        );
        if (radius < .92) expect(alpha, 1);
        if (radius > 1.04) expect(alpha, 0);
      }
    }
    final area = sum / (outWidth / width) / (outHeight / height);
    expect(area / (math.pi * rx * ry), closeTo(1, .018));
    expect(weightedX / sum, closeTo(cx, .12));
    expect(weightedY / sum, closeTo(cy, .12));
    expect(translucent / occupied, lessThan(.035));
    expect(result[3], 0);
  });

  test('preserves coherent corners and a deep concavity without a hull', () {
    const width = 48, height = 64, outputWidth = 144, outputHeight = 192;
    final p = List<double>.generate(width * height, (index) {
      final x = index % width, y = index ~/ width;
      final inFrame = x >= 6 && x < 42 && y >= 5 && y < 59;
      final inNotch = x >= 19 && x < 29 && y >= 5 && y < 25;
      return inFrame && !inNotch ? 1 : 0;
    });
    // A disconnected one-pixel error is not an additional nail fragment.
    p[61 * width + 2] = 1;
    final result = refineProbabilityContour(
      p,
      width,
      height,
      outputWidth: outputWidth,
      outputHeight: outputHeight,
    );
    int alpha(double x, double y) =>
        result[((y / height * outputHeight).floor() * outputWidth +
                    (x / width * outputWidth).floor()) *
                4 +
            3];
    expect(alpha(6.8, 5.8), 255, reason: 'Top outer corner remains covered');
    expect(alpha(41.2, 58.2), 255, reason: 'Bottom corner remains covered');
    expect(alpha(18.2, 24.2), 255, reason: 'Notch side corner is not shaved');
    expect(alpha(19.8, 25.8), 255);
    expect(alpha(24, 12), 0, reason: 'Concavity is not filled by a hull');
    expect(alpha(24, 23.5), 0);
    expect(alpha(4.8, 30), 0, reason: 'No default dilation into the skin');
    expect(alpha(2.5, 61.5), 0);
    var area = 0.0;
    for (var i = 3; i < result.length; i += 4) {
      area += result[i] / 255 / 9;
    }
    expect(area / (36 * 54 - 10 * 20), closeTo(1, .008));
  });

  test('real bundled-model component stays within its probability extent', () {
    final bytes = File(
      'test/fixtures/upstream_hand_probabilities.f32',
    ).readAsBytesSync();
    final data = ByteData.sublistView(bytes);
    final raw = List<double>.generate(
      128 * 128,
      (index) => data.getFloat32(index * 4, Endian.little),
    );
    final components = connectedComponents(raw, 128, 128, threshold: .5);
    components.sort((a, b) => b.length.compareTo(a.length));
    final selected = components.first;
    final isolated = List<double>.filled(raw.length, 0);
    for (final index in selected) {
      isolated[index] = raw[index];
    }
    final output = refineProbabilityContour(
      isolated,
      128,
      128,
      outputWidth: 256,
      outputHeight: 256,
    );
    final left = selected.map((i) => i % 128).reduce(math.min);
    final right = selected.map((i) => i % 128 + 1).reduce(math.max);
    final top = selected.map((i) => i ~/ 128).reduce(math.min);
    final bottom = selected.map((i) => i ~/ 128 + 1).reduce(math.max);
    var area = 0.0, solid = 0;
    final antialiased = <(int, int)>[];
    for (var y = 0; y < 256; y++) {
      for (var x = 0; x < 256; x++) {
        final alpha = output[(y * 256 + x) * 4 + 3];
        area += alpha / 255 / 4;
        if (alpha == 255) solid++;
        if (alpha == 0) continue;
        if (alpha < 255) antialiased.add((x, y));
        expect((x + .5) / 2, inInclusiveRange(left - .5, right + .5));
        expect((y + .5) / 2, inInclusiveRange(top - .5, bottom + .5));
      }
    }
    expect(area / selected.length, inInclusiveRange(.88, 1.03));
    expect(solid, greaterThan(selected.length * 3));
    // This full-photo fixture makes each nail small in the output. Validate
    // the actual AA band width rather than imposing an area-dependent ratio.
    for (final (x, y) in antialiased) {
      var nearBoundary = false;
      for (var dy = -2; dy <= 2; dy++) {
        for (var dx = -2; dx <= 2; dx++) {
          final px = x + dx, py = y + dy;
          if (px < 0 ||
              py < 0 ||
              px >= 256 ||
              py >= 256 ||
              output[(py * 256 + px) * 4 + 3] == 0) {
            nearBoundary = true;
          }
        }
      }
      expect(nearBoundary, isTrue, reason: 'No broad translucent interior');
    }
    expect(output[3], 0);
  });

  test('empty probabilities remain empty and invalid input is rejected', () {
    expect(
      refineProbabilityContour(List.filled(24 * 36, 0), 24, 36),
      everyElement(0),
    );
    expect(
      () => refineProbabilityContour([double.nan], 1, 1),
      throwsArgumentError,
    );
    expect(
      () => refineProbabilityContour([1], 1, 1, threshold: 0),
      throwsArgumentError,
    );
  });
}
