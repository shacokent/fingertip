import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'nail_photo_candidates.dart' show PhotoViewPredictor;
import 'probability_contour.dart';
import 'segmentation_geometry.dart';

/// A narrow recovery path for a visually consistent manicure. Three trusted
/// model masks must share a pigment that is distinct from nearby skin. Color
/// can propose a region, but two ONNX views must independently support it.
Future<List<NailRegion>> recoverConsistentPolishNails({
  required Uint8List pngBytes,
  required int imageWidth,
  required int imageHeight,
  required List<NailRegion> nails,
  required Set<int> trustedIds,
  required PhotoViewPredictor predictView,
  int firstUnusedId = 0,
  void Function(String)? onStage,
}) async {
  if (trustedIds.length < 3 || nails.length >= 12) return nails;
  final proposals = await compute(_proposals, (
    bytes: pngBytes,
    nails: nails,
    trustedIds: trustedIds,
    width: imageWidth,
    height: imageHeight,
    firstUnusedId: firstUnusedId,
  ));
  final output = List<NailRegion>.of(nails);
  for (final proposal in proposals) {
    if (output.length >= 12) break;
    onStage?.call('复查有色甲面');
    final first = await predictView(proposal.tensor, 0);
    final second = await predictView(proposal.tensor, 2);
    final a = _evidence(first, proposal.cropMask);
    final b = _evidence(second, proposal.cropMask);
    if (math.min(a.coverage, b.coverage) < .12 ||
        math.max(a.coverage, b.coverage) < .20 ||
        math.min(a.peak, b.peak) < .80) {
      continue;
    }
    output.add(proposal.region);
  }
  return output;
}

({double coverage, double peak}) _evidence(
  List<double> field,
  List<int> cropMask,
) {
  if (field.length != _side * _side || cropMask.isEmpty) {
    return (coverage: 0, peak: 0);
  }
  var hits = 0;
  var peak = 0.0;
  for (final index in cropMask) {
    final value = field[index];
    if (!value.isFinite) continue;
    if (value >= .38) hits++;
    peak = math.max(peak, value);
  }
  return (coverage: hits / cropMask.length, peak: peak);
}

const _side = 128;

class _Anchor {
  const _Anchor(this.region, this.chroma, this.surround, this.area);
  final NailRegion region;
  final Offset chroma, surround;
  final double area;
}

class _Proposal {
  const _Proposal(this.region, this.tensor, this.cropMask);
  final NailRegion region;
  final Float32List tensor;
  final List<int> cropMask;
}

Offset _chroma(img.Pixel pixel) =>
    Offset((pixel.r - pixel.g).toDouble(), (pixel.b - pixel.g).toDouble());

Offset _medianChroma(List<Offset> values) {
  double median(List<double> values) {
    values.sort();
    return values[values.length ~/ 2];
  }

  return Offset(
    median(values.map((c) => c.dx).toList()),
    median(values.map((c) => c.dy).toList()),
  );
}

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

_Anchor? _anchor(img.Image photo, NailRegion region) {
  final width = region.maskWidth, height = region.maskHeight;
  if (width < 4 || height < 4 || region.maskRgba.length != width * height * 4) {
    return null;
  }
  final inside = <Offset>[], outside = <Offset>[];
  final c = math.cos(region.angle), s = math.sin(region.angle);
  var covered = 0;
  for (var y = 0; y < height; y += 3) {
    for (var x = 0; x < width; x += 3) {
      final lx = ((x + .5) / width - .5) * region.width;
      final ly = ((y + .5) / height - .5) * region.height;
      final p = region.center + Offset(c * lx - s * ly, s * lx + c * ly);
      if (p.dx < 0 || p.dy < 0 || p.dx >= photo.width || p.dy >= photo.height) {
        continue;
      }
      final alpha = region.maskRgba[(y * width + x) * 4 + 3];
      final value = _chroma(photo.getPixel(p.dx.floor(), p.dy.floor()));
      if (alpha >= 128) covered++;
      if (alpha >= 190) inside.add(value);
      if (alpha <= 16) outside.add(value);
    }
  }
  if (inside.length < 10 || outside.length < 8) return null;
  final chroma = _medianChroma(inside);
  final surround = _medianChroma(outside);
  if (chroma.distance < 26 || (chroma - surround).distance < 24) return null;
  final area = region.width * region.height * covered * 9 / (width * height);
  return _Anchor(region, chroma, surround, area);
}

List<_Proposal> _proposals(
  ({
    Uint8List bytes,
    List<NailRegion> nails,
    Set<int> trustedIds,
    int width,
    int height,
    int firstUnusedId,
  })
  input,
) {
  final photo = img.decodePng(input.bytes);
  if (photo == null ||
      photo.width != input.width ||
      photo.height != input.height) {
    return const [];
  }
  final anchors = [
    for (final nail in input.nails)
      if (input.trustedIds.contains(nail.id) && nail.enabled && !nail.isManual)
        ?_anchor(photo, nail),
  ];
  var group = <_Anchor>[];
  for (final anchor in anchors) {
    final direction = anchor.chroma / anchor.chroma.distance;
    final similar = anchors
        .where(
          (other) =>
              _dot(other.chroma, direction) >= other.chroma.distance * .85 &&
              _dot(other.chroma - other.surround, direction) >= 15,
        )
        .toList();
    if (similar.length > group.length) group = similar;
  }
  if (group.length < 3) return const [];
  final chroma = group.map((anchor) => anchor.chroma).reduce((a, b) => a + b);
  final direction = chroma / chroma.distance;
  final strengths = group.map((anchor) => anchor.chroma.distance).toList()
    ..sort();
  final threshold = math.max(22.0, strengths[strengths.length ~/ 2] * .46);
  final areas = group.map((anchor) => anchor.area).toList()..sort();
  final medianArea = areas[areas.length ~/ 2];

  final longest = math.max(photo.width, photo.height);
  final sampled = longest <= 768
      ? photo
      : img.copyResize(
          photo,
          width: math.max(1, (photo.width * 768 / longest).round()),
          height: math.max(1, (photo.height * 768 / longest).round()),
          interpolation: img.Interpolation.average,
        );
  final sw = sampled.width, sh = sampled.height;
  final sx = photo.width / sw, sy = photo.height / sh;
  final mask = Uint8List(sw * sh);
  for (final pixel in sampled) {
    final color = _chroma(pixel);
    if (color.distance >= threshold &&
        _dot(color, direction) >= color.distance * .92) {
      mask[pixel.y * sw + pixel.x] = 1;
    }
  }
  final closed = _close(mask, sw, sh);
  final components = connectedComponents(
    closed.map((value) => value.toDouble()).toList(),
    sw,
    sh,
    minArea: 9,
  )..sort((a, b) => b.length.compareTo(a.length));

  var nextId = input.nails.fold<int>(
    input.firstUnusedId,
    (id, nail) => math.max(id, nail.id + 1),
  );
  final results = <_Proposal>[];
  for (final pixels in components) {
    if (results.length == 2) break;
    final area = pixels.length * sx * sy;
    if (area < medianArea * .17 || area > medianArea * 1.8) continue;
    final positions = [
      for (final pixel in pixels)
        Offset((pixel % sw + .5) * sx, (pixel ~/ sw + .5) * sy),
    ];
    final mean =
        positions.reduce((a, b) => a + b) / positions.length.toDouble();
    if (group.every(
      (anchor) =>
          (anchor.region.center - mean).distance > math.sqrt(medianArea) * 3.5,
    )) {
      continue;
    }
    var overlaps = 0;
    final known = input.nails
        .where(
          (nail) =>
              nail.enabled &&
              (nail.center - mean).distance <
                  math.max(nail.width, nail.height) * 1.4,
        )
        .toList();
    for (var i = 0; i < positions.length; i += 3) {
      if (known.any((nail) => _insideMask(nail, positions[i]))) overlaps++;
    }
    if (overlaps * 3 / positions.length > .30) continue;

    final proposal = _prepare(
      photo,
      pixels,
      positions,
      mean,
      area,
      sw,
      sh,
      sx,
      sy,
      nextId,
      input.nails.length + results.length + 1,
    );
    if (proposal != null) {
      nextId++;
      results.add(proposal);
    }
  }
  return results;
}

bool _insideMask(NailRegion nail, Offset point) {
  final p = nail.toLocal(point);
  final x = ((p.dx / nail.width + .5) * nail.maskWidth).floor();
  final y = ((p.dy / nail.height + .5) * nail.maskHeight).floor();
  return x >= 0 &&
      y >= 0 &&
      x < nail.maskWidth &&
      y < nail.maskHeight &&
      nail.maskRgba[(y * nail.maskWidth + x) * 4 + 3] >= 128;
}

// Close only one-sample holes. Larger gaps remain transparent.
Uint8List _close(Uint8List input, int width, int height) {
  final dilated = Uint8List(input.length);
  final closed = Uint8List.fromList(input);
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      final i = y * width + x;
      dilated[i] =
          input[i] |
          input[i - 1] |
          input[i + 1] |
          input[i - width] |
          input[i + width];
    }
  }
  for (var y = 2; y < height - 2; y++) {
    for (var x = 2; x < width - 2; x++) {
      final i = y * width + x;
      closed[i] =
          dilated[i] &
          dilated[i - 1] &
          dilated[i + 1] &
          dilated[i - width] &
          dilated[i + width];
    }
  }
  return closed;
}

_Proposal? _prepare(
  img.Image photo,
  List<int> pixels,
  List<Offset> positions,
  Offset mean,
  double area,
  int sw,
  int sh,
  double sx,
  double sy,
  int id,
  int index,
) {
  var xx = 0.0, yy = 0.0, xy = 0.0;
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final point in positions) {
    final p = point - mean;
    xx += p.dx * p.dx;
    yy += p.dy * p.dy;
    xy += p.dx * p.dy;
    minX = math.min(minX, p.dx);
    maxX = math.max(maxX, p.dx);
    minY = math.min(minY, p.dy);
    maxY = math.max(maxY, p.dy);
  }
  final angle = .5 * math.atan2(2 * xy, xx - yy) - math.pi / 2;
  final c = math.cos(angle), s = math.sin(angle);
  Offset rotate(Offset p) => Offset(c * p.dx - s * p.dy, s * p.dx + c * p.dy);
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final point in positions) {
    final d = point - mean;
    final x = c * d.dx + s * d.dy;
    final y = -s * d.dx + c * d.dy;
    left = math.min(left, x);
    right = math.max(right, x);
    top = math.min(top, y);
    bottom = math.max(bottom, y);
  }
  final width = right - left, height = bottom - top;
  if (width < 5 ||
      height < 5 ||
      height / width > 4.4 ||
      area / (width * height) < .48) {
    return null;
  }

  final members = Uint8List(sw * sh);
  for (final pixel in pixels) {
    members[pixel] = 1;
  }
  double membership(Offset p) {
    final x = p.dx / sx - .5, y = p.dy / sy - .5;
    final ix = x.floor(), iy = y.floor(), fx = x - ix, fy = y - iy;
    double at(int x, int y) => x >= 0 && y >= 0 && x < sw && y < sh
        ? members[y * sw + x].toDouble()
        : 0;
    return at(ix, iy) * (1 - fx) * (1 - fy) +
        at(ix + 1, iy) * fx * (1 - fy) +
        at(ix, iy + 1) * (1 - fx) * fy +
        at(ix + 1, iy + 1) * fx * fy;
  }

  final cropSide = math.max(
    math.max(maxX - minX + sx, maxY - minY + sy) * 1.20,
    math.max(width, height) * 1.03,
  );
  final cropPixels = cropSide.ceil().clamp(_side, 768);
  final crop = img.Image(width: cropPixels, height: cropPixels);
  for (final pixel in crop) {
    final p =
        mean +
        rotate(
          Offset(
            ((pixel.x + .5) / cropPixels - .5) * cropSide,
            ((pixel.y + .5) / cropPixels - .5) * cropSide,
          ),
        );
    final color = photo.getPixelInterpolate(
      (p.dx - .5).clamp(0.0, photo.width - 1.0),
      (p.dy - .5).clamp(0.0, photo.height - 1.0),
      interpolation: img.Interpolation.linear,
    );
    pixel.setRgb(color.r, color.g, color.b);
  }
  final sample = img.copyResize(
    crop,
    width: _side,
    height: _side,
    interpolation: img.Interpolation.average,
  );
  final tensor = Float32List(_side * _side * 3);
  final cropMask = <int>[];
  for (final pixel in sample) {
    final i = pixel.y * _side + pixel.x;
    tensor[i] = pixel.r / 127.5 - 1;
    tensor[i + _side * _side] = pixel.g / 127.5 - 1;
    tensor[i + _side * _side * 2] = pixel.b / 127.5 - 1;
    if (membership(
          mean +
              rotate(
                Offset(
                  ((pixel.x + .5) / _side - .5) * cropSide,
                  ((pixel.y + .5) / _side - .5) * cropSide,
                ),
              ),
        ) >=
        .5) {
      cropMask.add(i);
    }
  }

  final padding = math.max(sx, sy) * 2;
  final center = mean + rotate(Offset((left + right) / 2, (top + bottom) / 2));
  final frameWidth = width + padding * 2, frameHeight = height + padding * 2;
  const mw = 128, mh = 192;
  final local = [
    for (var y = 0; y < mh; y++)
      for (var x = 0; x < mw; x++)
        membership(
          center +
              rotate(
                Offset(
                  ((x + .5) / mw - .5) * frameWidth,
                  ((y + .5) / mh - .5) * frameHeight,
                ),
              ),
        ),
  ];
  final coverage = refineProbabilityContour(local, mw, mh);
  return _Proposal(
    NailRegion(
      id: id,
      label: '甲面 $index',
      center: center,
      width: frameWidth,
      height: frameHeight,
      angle: angle,
      maskRgba: coverage,
      maskWidth: mw,
      maskHeight: mh,
    ),
    tensor,
    cropMask,
  );
}
