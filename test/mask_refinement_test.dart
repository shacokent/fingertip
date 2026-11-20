import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/services/mask_refinement.dart';

void main() {
  test(
    'crisp default preserves connected corners, closes notches and holes',
    () {
      const width = 24, height = 32;
      final mask = Uint8List(width * height * 4);
      void pixel(int x, int y, int alpha) {
        final index = (y * width + x) * 4;
        mask[index] = mask[index + 1] = mask[index + 2] = mask[index + 3] =
            alpha;
      }

      for (var y = 5; y < 27; y++) {
        for (var x = 5; x < 19; x++) {
          pixel(x, y, 140);
        }
      }
      // A concave one-pixel notch, enclosed hole and diagonal connected tip.
      pixel(11, 5, 0);
      pixel(12, 15, 0);
      pixel(4, 4, 140);
      // A true background speck should not grow into a patch of polish.
      pixel(1, 29, 255);
      final result = refineNailMask(mask, width, height);
      int alpha(int x, int y) => result[(y * width + x) * 4 + 3];
      expect(
        alpha(11, 5),
        255,
        reason: 'Small missing border corner is filled',
      );
      expect(
        alpha(12, 15),
        255,
        reason: 'Opaque coverage has no internal holes',
      );
      expect(alpha(4, 4), 255, reason: 'Original diagonal corner is preserved');
      expect(alpha(5, 5), 255);
      expect(
        alpha(8, 8),
        255,
        reason: 'Low confidence must not mean thin polish',
      );
      expect(alpha(1, 29), 0, reason: 'An isolated speck is not a nail');
      expect(alpha(0, 0), 0);
      expect(alpha(2, 15), 0, reason: 'Expansion remains local to the edge');
      for (var i = 0; i < result.length; i += 4) {
        expect(result[i], result[i + 3]);
        expect(result[i + 1], result[i + 3]);
        expect(result[i + 2], result[i + 3]);
      }
    },
  );

  test('narrow antialias band replaces a translucent halo', () {
    const width = 24, height = 32;
    final mask = Uint8List(width * height * 4);
    for (var y = 6; y < 26; y++) {
      for (var x = 6; x < 18; x++) {
        for (var c = 0; c < 4; c++) {
          mask[(y * width + x) * 4 + c] = 160;
        }
      }
    }
    final crisp = refineNailMask(mask, width, height);
    final soft = refineNailMask(mask, width, height, feather: 2.5);
    int translucentCount(Uint8List pixels) {
      var count = 0;
      for (var i = 3; i < pixels.length; i += 4) {
        if (pixels[i] > 8 && pixels[i] < 247) count++;
      }
      return count;
    }

    expect(translucentCount(crisp), lessThan(translucentCount(soft)));
    for (var y = 8; y < 24; y++) {
      for (var x = 8; x < 16; x++) {
        expect(crisp[(y * width + x) * 4 + 3], 255);
      }
    }
    expect(crisp[(15 * width + 3) * 4 + 3], 0);
  });

  test(
    'frame-edge coverage survives and empty or isolated input stays empty',
    () {
      const width = 12, height = 18;
      final edge = Uint8List(width * height * 4);
      for (var y = 0; y < 11; y++) {
        for (var x = 0; x < 7; x++) {
          for (var c = 0; c < 4; c++) {
            edge[(y * width + x) * 4 + c] = 255;
          }
        }
      }
      final result = refineNailMask(edge, width, height);
      expect(
        result[3],
        255,
        reason: 'Closing cannot cut a confirmed frame corner',
      );
      expect(result[(10 * width) * 4 + 3], 255);
      expect(result[(17 * width + 11) * 4 + 3], 0);
      final empty = Uint8List(width * height * 4);
      expect(refineNailMask(empty, width, height), everyElement(0));
      empty[(8 * width + 6) * 4 + 3] = 255;
      expect(refineNailMask(empty, width, height), everyElement(0));
    },
  );
}
