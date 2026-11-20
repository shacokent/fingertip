import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'mask_refinement.dart';
import 'nail_segmentation.dart';

NailRegion tuneMask(
  NailRegion original, {
  required double expansion,
  required double feather,
}) => original.copyWith(
  maskRgba: refineNailMask(
    original.maskRgba,
    original.maskWidth,
    original.maskHeight,
    expansion: expansion.clamp(-5.0, 5.0),
    feather: feather.clamp(.15, 5.0),
    closeHoles: false,
  ),
);

/// Local UV points, clockwise from the nail tip. They follow the actual mask
/// rather than forcing every manually corrected nail into the same ellipse.
List<Offset> contourFromMask(NailRegion region, {int points = 8}) {
  if (points < 4 || points > 32) throw ArgumentError.value(points, 'points');
  final w = region.maskWidth, h = region.maskHeight;
  var weight = 0.0, sx = 0.0, sy = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final a = region.maskRgba[(y * w + x) * 4 + 3] / 255;
      weight += a;
      sx += (x + .5) / w * a;
      sy += (y + .5) / h * a;
    }
  }
  final center = weight > 0
      ? Offset(sx / weight, sy / weight)
      : const Offset(.5, .5);
  bool inside(Offset p) {
    if (p.dx < 0 || p.dy < 0 || p.dx >= 1 || p.dy >= 1) return false;
    return region.maskRgba[((p.dy * h).floor() * w + (p.dx * w).floor()) * 4 +
            3] >=
        96;
  }

  return List.generate(points, (index) {
    final angle = -math.pi / 2 + index * math.pi * 2 / points;
    final direction = Offset(math.cos(angle), math.sin(angle));
    var edge = center;
    for (var step = 1; step <= 240; step++) {
      final p = center + direction * (step / 240);
      if (inside(p)) edge = p;
      if (p.dx < 0 || p.dy < 0 || p.dx > 1 || p.dy > 1) break;
    }
    if ((edge - center).distance < .02) {
      edge = center + Offset(direction.dx * .42, direction.dy * .45);
    }
    return Offset(edge.dx.clamp(.005, .995), edge.dy.clamp(.005, .995));
  });
}

NailRegion applyContour(
  NailRegion original,
  List<Offset> normalizedPoints, {
  double expansion = 0,
  double feather = .35,
}) {
  if (normalizedPoints.length < 4 ||
      normalizedPoints.length > 32 ||
      normalizedPoints.any((p) => !p.dx.isFinite || !p.dy.isFinite)) {
    throw ArgumentError('A nail contour needs 4–32 finite control points.');
  }
  final controls = normalizedPoints
      .map((p) => Offset(p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0)))
      .toList();
  final curve = <Offset>[];
  for (var index = 0; index < controls.length; index++) {
    final count = controls.length;
    final p0 = controls[(index + count - 1) % count];
    final p1 = controls[index], p2 = controls[(index + 1) % count];
    final p3 = controls[(index + 2) % count];
    for (var step = 0; step < 8; step++) {
      final t = step / 8, t2 = t * t, t3 = t2 * t;
      final p =
          (p1 * 2 +
              (p2 - p0) * t +
              (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 +
              (p0 * -1 + p1 * 3 - p2 * 3 + p3) * t3) *
          .5;
      curve.add(Offset(p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0)));
    }
  }
  final w = original.maskWidth, h = original.maskHeight;
  final rgba = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final py = (y + .5) / h;
    for (var x = 0; x < w; x++) {
      final px = (x + .5) / w;
      var inside = false;
      for (var i = 0, j = curve.length - 1; i < curve.length; j = i++) {
        final a = curve[i], b = curve[j];
        if ((a.dy > py) != (b.dy > py) &&
            px < (b.dx - a.dx) * (py - a.dy) / (b.dy - a.dy) + a.dx) {
          inside = !inside;
        }
      }
      if (inside) {
        final i = (y * w + x) * 4;
        rgba[i] = rgba[i + 1] = rgba[i + 2] = rgba[i + 3] = 255;
      }
    }
  }
  if (!rgba.contains(255)) return original;
  return original.copyWith(
    maskRgba: refineNailMask(
      rgba,
      w,
      h,
      expansion: expansion,
      feather: feather,
      closeHoles: false,
    ),
  );
}

/// Refit updates coverage in photo space while keeping the user's chosen
/// texture axes. Replacing [fitted.angle] alone would rotate the new mask away
/// from the photographed nail, especially after a 90/180-degree correction.
NailRegion preserveRefitOrientation(NailRegion fitted, NailRegion previous) {
  // A heuristic fallback carries no reliable new segmentation information.
  // Keep the user's corrected shape instead of replacing it with a template.
  if (fitted.label == '手动甲面') return previous;
  for (final region in [fitted, previous]) {
    if (!region.angle.isFinite ||
        !region.center.dx.isFinite ||
        !region.center.dy.isFinite ||
        !region.width.isFinite ||
        !region.height.isFinite ||
        region.width <= 0 ||
        region.height <= 0 ||
        region.maskWidth <= 0 ||
        region.maskHeight <= 0 ||
        region.maskRgba.length != region.maskWidth * region.maskHeight * 4) {
      throw ArgumentError('Refit geometry and mask must be valid.');
    }
  }

  final sourceWidth = fitted.maskWidth, sourceHeight = fitted.maskHeight;
  final c = math.cos(fitted.angle), s = math.sin(fitted.angle);
  var maxX = 0.0, maxY = 0.0, occupied = false;
  // Include occupied pixel cells, not the empty corners of a rotated source
  // rectangle. Keep the previous center and dimensions unless coverage would
  // otherwise be clipped by that frame.
  for (var y = 0; y < sourceHeight; y++) {
    for (var x = 0; x < sourceWidth; x++) {
      if (fitted.maskRgba[(y * sourceWidth + x) * 4 + 3] == 0) continue;
      occupied = true;
      for (var dy = 0; dy <= 1; dy++) {
        for (var dx = 0; dx <= 1; dx++) {
          final local = Offset(
            ((x + dx) / sourceWidth - .5) * fitted.width,
            ((y + dy) / sourceHeight - .5) * fitted.height,
          );
          final image =
              fitted.center +
              Offset(c * local.dx - s * local.dy, s * local.dx + c * local.dy);
          final target = previous.toLocal(image);
          maxX = math.max(maxX, target.dx.abs());
          maxY = math.max(maxY, target.dy.abs());
        }
      }
    }
  }
  if (!occupied) return previous;
  double contain(double oldSize, double requiredSize, int pixels) {
    if (requiredSize <= oldSize) return oldSize;
    // One destination pixel of padding per side retains the resampled fringe.
    return pixels > 2 ? requiredSize * pixels / (pixels - 2) : requiredSize;
  }

  final width = contain(previous.width, maxX * 2, previous.maskWidth);
  final height = contain(previous.height, maxY * 2, previous.maskHeight);
  final rgba = Uint8List(previous.maskWidth * previous.maskHeight * 4);
  final pc = math.cos(previous.angle), ps = math.sin(previous.angle);
  for (var y = 0; y < previous.maskHeight; y++) {
    for (var x = 0; x < previous.maskWidth; x++) {
      final local = Offset(
        ((x + .5) / previous.maskWidth - .5) * width,
        ((y + .5) / previous.maskHeight - .5) * height,
      );
      final image =
          previous.center +
          Offset(pc * local.dx - ps * local.dy, ps * local.dx + pc * local.dy);
      final source = fitted.toLocal(image);
      final sx = (source.dx / fitted.width + .5) * sourceWidth - .5;
      final sy = (source.dy / fitted.height + .5) * sourceHeight - .5;
      final ix = sx.floor(), iy = sy.floor();
      final fx = sx - ix, fy = sy - iy;
      var alpha = 0.0;
      for (var dy = 0; dy < 2; dy++) {
        for (var dx = 0; dx < 2; dx++) {
          final px = ix + dx, py = iy + dy;
          if (px < 0 || py < 0 || px >= sourceWidth || py >= sourceHeight) {
            continue;
          }
          alpha +=
              fitted.maskRgba[(py * sourceWidth + px) * 4 + 3] *
              (dx == 0 ? 1 - fx : fx) *
              (dy == 0 ? 1 - fy : fy);
        }
      }
      final a = alpha.round().clamp(0, 255),
          index = (y * previous.maskWidth + x) * 4;
      rgba[index] = rgba[index + 1] = rgba[index + 2] = rgba[index + 3] = a;
    }
  }
  return previous.copyWith(width: width, height: height, maskRgba: rgba);
}

/// The tap is an explicit user seed. Crop inference can recover a small nail
/// lost at the full-image resolution; it must actually cover that seed before
/// being accepted. Otherwise return an honestly labelled, editable proposal.
Future<NailRegion> fitManualNail({
  required Uint8List pngBytes,
  required int id,
  required Offset center,
  required int imageWidth,
  required int imageHeight,
  NailSegmentationEngine? engine,
}) async {
  if (!center.dx.isFinite ||
      !center.dy.isFinite ||
      imageWidth <= 0 ||
      imageHeight <= 0) {
    throw ArgumentError('Manual nail dimensions and position must be valid.');
  }
  final prepared = await compute(
    _prepareManualCrop,
    _ManualRequest(pngBytes, center, id, imageWidth, imageHeight),
  );
  final detector = engine ?? NailSegmentationEngine();
  try {
    final candidates = await detector.detect(
      prepared.tensor,
      width: prepared.width,
      height: prepared.height,
    );
    NailRegion? best;
    var bestDistance = double.infinity;
    final seed = prepared.center - prepared.origin;
    for (final nail in candidates) {
      final local = nail.toLocal(seed);
      final u = local.dx / nail.width + .5, v = local.dy / nail.height + .5;
      if (u < 0 || v < 0 || u >= 1 || v >= 1) continue;
      final index =
          ((v * nail.maskHeight).floor() * nail.maskWidth +
                  (u * nail.maskWidth).floor()) *
              4 +
          3;
      if (nail.maskRgba[index] < 64) continue;
      final distance =
          (nail.center - seed).distance /
          math.max(1, math.sqrt(nail.width * nail.height));
      if (distance < bestDistance) {
        best = nail;
        bestDistance = distance;
      }
    }
    if (best != null) {
      return NailRegion(
        id: id,
        label: '局部贴合',
        center: best.center + prepared.origin,
        width: best.width,
        height: best.height,
        angle: best.angle,
        maskRgba: best.maskRgba,
        maskWidth: best.maskWidth,
        maskHeight: best.maskHeight,
        isManual: true,
      );
    }
  } catch (_) {
    // An optional local inference failure must not prevent manual correction.
  } finally {
    if (engine == null) {
      try {
        await detector.close();
      } catch (_) {
        // A native cleanup error must not discard a usable manual proposal.
      }
    }
  }
  return prepared.fallback;
}

class _ManualRequest {
  const _ManualRequest(
    this.bytes,
    this.center,
    this.id,
    this.width,
    this.height,
  );
  final Uint8List bytes;
  final Offset center;
  final int id, width, height;
}

class _ManualCrop {
  const _ManualCrop(
    this.tensor,
    this.width,
    this.height,
    this.origin,
    this.center,
    this.fallback,
  );
  final Float32List tensor;
  final int width, height;
  final Offset origin, center;
  final NailRegion fallback;
}

_ManualCrop _prepareManualCrop(_ManualRequest request) {
  final decoded = img.decodeImage(request.bytes);
  if (decoded == null) throw const FormatException('无法读取甲面照片。');
  var image = img.bakeOrientation(decoded);
  if (image.width != request.width || image.height != request.height) {
    image = img.copyResize(image, width: request.width, height: request.height);
  }
  final w = image.width, h = image.height;
  final center = Offset(
    request.center.dx.clamp(0.0, w - 1.0),
    request.center.dy.clamp(0.0, h - 1.0),
  );
  final edge = math.max(
    1,
    math.min(math.min(w, h), math.max(128, (math.min(w, h) * .52).round())),
  );
  final left = (center.dx - edge / 2).round().clamp(0, w - edge);
  final top = (center.dy - edge / 2).round().clamp(0, h - edge);
  final crop = img.copyCrop(image, x: left, y: top, width: edge, height: edge);
  final input = img.copyResize(
    crop,
    width: 128,
    height: 128,
    interpolation: img.Interpolation.average,
  );
  final tensor = Float32List(3 * 128 * 128);
  for (var y = 0; y < 128; y++) {
    for (var x = 0; x < 128; x++) {
      final p = input.getPixel(x, y), i = y * 128 + x;
      tensor[i] = p.r / 127.5 - 1;
      tensor[16384 + i] = p.g / 127.5 - 1;
      tensor[32768 + i] = p.b / 127.5 - 1;
    }
  }
  final fallback = _proposePhotoContour(image, request.id, center);
  return _ManualCrop(
    tensor,
    edge,
    edge,
    Offset(left.toDouble(), top.toDouble()),
    center,
    fallback,
  );
}

NailRegion _proposePhotoContour(img.Image image, int id, Offset center) {
  final dimension = math.min(image.width, image.height).toDouble();
  final width = math.max(8.0, dimension * .075);
  final height = math.max(12.0, dimension * .115);
  double luminance(double x, double y) {
    final p = image.getPixel(
      x.round().clamp(0, image.width - 1),
      y.round().clamp(0, image.height - 1),
    );
    return p.r * .299 + p.g * .587 + p.b * .114;
  }

  var xx = 0.0, yy = 0.0, xy = 0.0;
  final radius = (width * .72).round();
  for (var y = -radius; y <= radius; y += 2) {
    for (var x = -radius; x <= radius; x += 2) {
      final px = center.dx + x, py = center.dy + y;
      final gx = luminance(px + 1, py) - luminance(px - 1, py);
      final gy = luminance(px, py + 1) - luminance(px, py - 1);
      final weight = math.exp(-(x * x + y * y) / (width * width * .42));
      xx += gx * gx * weight;
      yy += gy * gy * weight;
      xy += gx * gy * weight;
    }
  }
  final anisotropy =
      math.sqrt((xx - yy) * (xx - yy) + 4 * xy * xy) / math.max(1, xx + yy);
  final angle = anisotropy > .14 ? .5 * math.atan2(2 * xy, xx - yy) : 0.0;
  final ca = math.cos(angle), sa = math.sin(angle);
  const template = [
    Offset(.5, .035),
    Offset(.85, .15),
    Offset(.96, .47),
    Offset(.89, .86),
    Offset(.5, .97),
    Offset(.11, .86),
    Offset(.04, .47),
    Offset(.15, .15),
  ];
  final controls = <Offset>[];
  for (final uv in template) {
    final local = Offset((uv.dx - .5) * width, (uv.dy - .5) * height);
    final direction = Offset(
      ca * local.dx - sa * local.dy,
      sa * local.dx + ca * local.dy,
    );
    var bestScale = 1.0, bestScore = 3.5;
    // Modest, prior-bounded edge adjustment. This is only an editable proposal,
    // not a claim that image gradients are a reliable nail segmentation model.
    for (var step = 7; step <= 13; step++) {
      final scale = step / 10;
      final point = center + direction * scale;
      final unit = direction / math.max(1, direction.distance);
      final gradient =
          (luminance(point.dx + unit.dx, point.dy + unit.dy) -
                  luminance(point.dx - unit.dx, point.dy - unit.dy))
              .abs();
      final score = gradient * math.exp(-math.pow((scale - 1) / .42, 2));
      if (score > bestScore) {
        bestScore = score;
        bestScale = scale;
      }
    }
    controls.add(
      Offset(.5 + (uv.dx - .5) * bestScale, .5 + (uv.dy - .5) * bestScale),
    );
  }
  final original = NailRegion.manual(
    id,
    center,
    image.width.toDouble(),
  ).copyWith(width: width, height: height, angle: angle);
  return applyContour(original, controls, feather: .35);
}
