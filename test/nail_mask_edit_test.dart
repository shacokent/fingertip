import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/mask_refinement.dart';
import 'package:offline_nail_demo/services/nail_mask_edit.dart';
import 'package:offline_nail_demo/services/nail_segmentation.dart';

void main() {
  test(
    'coverage closes small holes, strengthens the interior and stays local',
    () {
      const width = 32, height = 48;
      final raw = Uint8List(width * height * 4);
      for (var y = 8; y < 40; y++) {
        for (var x = 7; x < 25; x++) {
          final i = (y * width + x) * 4;
          raw[i] = raw[i + 1] = raw[i + 2] = raw[i + 3] = 145;
        }
      }
      final hole = (24 * width + 16) * 4;
      raw.fillRange(hole, hole + 4, 0);
      final result = refineNailMask(raw, width, height);
      expect(result[hole + 3], 255);
      expect(result[(12 * width + 12) * 4 + 3], 255);
      expect(result[3], 0);
      expect(result[(24 * width + 5) * 4 + 3], 0);
      expect(result[(24 * width + 6) * 4 + 3], greaterThan(0));
      expect(result.any((a) => a > 0 && a < 255), isTrue);
      for (var i = 0; i < result.length; i += 4) {
        expect(result[i], result[i + 3]);
        expect(result[i + 1], result[i + 3]);
        expect(result[i + 2], result[i + 3]);
      }
    },
  );

  test(
    'dragged contour replaces the shape and width tuning uses a base mask',
    () {
      final nail = NailRegion.manual(7, const Offset(80, 100), 640);
      final controls = contourFromMask(nail);
      expect(controls, hasLength(8));
      final edited = [...controls];
      edited[2] = const Offset(.67, .5);
      final shaped = applyContour(nail, edited);
      expect(shaped.id, nail.id);
      expect(shaped.center, nail.center);
      expect(shaped.maskRgba, isNot(orderedEquals(nail.maskRgba)));
      int area(NailRegion n) => List.generate(
        n.maskWidth * n.maskHeight,
        (i) => n.maskRgba[i * 4 + 3],
      ).where((a) => a >= 128).length;
      final contracted = tuneMask(shaped, expansion: -2, feather: 1);
      final expanded = tuneMask(shaped, expansion: 2, feather: 1);
      expect(area(contracted), lessThan(area(expanded)));
      expect(expanded.maskRgba[3], 0);
      expect(() => applyContour(nail, [Offset.zero]), throwsArgumentError);
      expect(refineNailMask(Uint8List(16), 2, 2), everyElement(0));
    },
  );

  test(
    'local fitting accepts a detected region only when it covers the tap',
    () async {
      final image = img.Image(width: 256, height: 256);
      img.fill(image, color: img.ColorRgb8(220, 175, 150));
      final bytes = Uint8List.fromList(img.encodePng(image));
      final hit = await fitManualNail(
        pngBytes: bytes,
        id: 101,
        center: const Offset(128, 128),
        imageWidth: 256,
        imageHeight: 256,
        engine: _LocalDetector(hit: true),
      );
      expect(hit.id, 101);
      expect(hit.isManual, isTrue);
      expect(hit.label, '局部贴合');
      expect((hit.center - const Offset(128, 128)).distance, lessThan(2));
      final miss = await fitManualNail(
        pngBytes: bytes,
        id: 102,
        center: const Offset(128, 128),
        imageWidth: 256,
        imageHeight: 256,
        engine: _LocalDetector(hit: false),
      );
      expect(miss.label, '手动甲面');
      expect(miss.center, const Offset(128, 128));
      expect(miss.angle.isFinite, isTrue);
      expect(miss.maskRgba.any((a) => a > 0), isTrue);
      expect(contourFromMask(miss), hasLength(8));
    },
  );

  test(
    'refit preserves chosen axes without rotating asymmetric photo coverage',
    () {
      final fitted = _asymmetricFit();
      for (final angle in [math.pi / 2, math.pi, -math.pi]) {
        final previous = NailRegion.manual(
          42,
          const Offset(100, 120),
          640,
        ).copyWith(width: 110, height: 110, angle: angle, enabled: false);
        final result = preserveRefitOrientation(fitted, previous);
        expect(result.angle, angle);
        expect(result.center, previous.center);
        expect(result.width, previous.width);
        expect(result.height, previous.height);
        expect(result.id, previous.id);
        expect(result.label, previous.label);
        expect(result.isManual, previous.isManual);
        expect(result.enabled, previous.enabled);
        // An L-shaped mask is deliberately asymmetric: merely copying the angle
        // would move these occupied and empty points to different photo positions.
        expect(_alphaAt(result, const Offset(93, 101)), greaterThan(240));
        expect(_alphaAt(result, const Offset(105, 133)), greaterThan(240));
        expect(_alphaAt(result, const Offset(109, 101)), lessThan(10));
        var intersection = 0, union = 0;
        for (var y = 80; y <= 160; y++) {
          for (var x = 80; x <= 120; x++) {
            // Sample between the original pixel-edge half-alpha positions so
            // threshold rounding cannot add an entire artificial boundary row.
            final point = Offset(x + .23, y + .37);
            final before = _alphaAt(fitted, point) >= 128;
            final after = _alphaAt(result, point) >= 128;
            if (before && after) intersection++;
            if (before || after) union++;
          }
        }
        expect(intersection / union, greaterThan(.94));
      }
    },
  );

  test(
    'refit contains new coverage but never shrinks or recenters user frame',
    () {
      final fitted = _asymmetricFit();
      final previous = NailRegion.manual(
        7,
        const Offset(98, 122),
        640,
      ).copyWith(width: 15, height: 20, angle: .7);
      final result = preserveRefitOrientation(fitted, previous);
      expect(result.angle, .7);
      expect(result.center, previous.center);
      expect(result.width, greaterThan(previous.width));
      expect(result.height, greaterThan(previous.height));
      expect(_alphaAt(result, const Offset(93, 101)), greaterThan(230));
      expect(_alphaAt(result, const Offset(105, 133)), greaterThan(230));
      final fallback = NailRegion.manual(999, Offset.zero, 500);
      expect(
        identical(preserveRefitOrientation(fallback, previous), previous),
        isTrue,
      );
      final empty = fitted.copyWith(
        maskRgba: Uint8List(fitted.maskRgba.length),
      );
      expect(
        identical(preserveRefitOrientation(empty, previous), previous),
        isTrue,
      );
    },
  );
}

NailRegion _asymmetricFit() {
  const w = 20, h = 40;
  final mask = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if ((x >= 4 && x <= 7 && y >= 6 && y <= 29) ||
          (x >= 8 && x <= 15 && y >= 24 && y <= 29)) {
        final i = (y * w + x) * 4;
        mask[i] = mask[i + 1] = mask[i + 2] = mask[i + 3] = 255;
      }
    }
  }
  return NailRegion(
    id: 1,
    label: '局部贴合',
    center: const Offset(100, 120),
    width: 40,
    height: 80,
    angle: 0,
    maskRgba: mask,
    maskWidth: w,
    maskHeight: h,
  );
}

double _alphaAt(NailRegion region, Offset photoPoint) {
  final local = region.toLocal(photoPoint);
  final x = (local.dx / region.width + .5) * region.maskWidth - .5;
  final y = (local.dy / region.height + .5) * region.maskHeight - .5;
  final ix = x.floor(), iy = y.floor(), fx = x - x.floor(), fy = y - y.floor();
  var alpha = 0.0;
  for (var dy = 0; dy < 2; dy++) {
    for (var dx = 0; dx < 2; dx++) {
      final px = ix + dx, py = iy + dy;
      if (px >= 0 &&
          py >= 0 &&
          px < region.maskWidth &&
          py < region.maskHeight) {
        alpha +=
            region.maskRgba[(py * region.maskWidth + px) * 4 + 3] *
            (dx == 0 ? 1 - fx : fx) *
            (dy == 0 ? 1 - fy : fy);
      }
    }
  }
  return alpha;
}

class _LocalDetector extends NailSegmentationEngine {
  _LocalDetector({required this.hit});
  final bool hit;
  @override
  Future<List<NailRegion>> detect(
    Float32List tensor, {
    required int width,
    required int height,
    List<HandObservation> hands = const [],
  }) async => [
    NailRegion.manual(
      0,
      hit ? Offset(width / 2, height / 2) : const Offset(2, 2),
      width.toDouble(),
    ).copyWith(width: 30, height: 45),
  ];
}
