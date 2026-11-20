import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'nail_photo_candidates.dart' show PhotoViewPredictor;
import 'probability_contour.dart';
import 'segmentation_geometry.dart';

const _modelSide = 128;

/// Revisits small dark plates in a nearly monochrome photo. Already detected
/// dark nails set the scale. Two agreeing model views verify a new candidate
/// before its connected dark patch can inform the outline.
Future<List<NailRegion>> recoverDarkNails({
  required Uint8List pngBytes,
  required int imageWidth,
  required int imageHeight,
  required List<NailRegion> nails,
  required PhotoViewPredictor predictView,
  int firstUnusedId = 0,
  void Function(String)? onStage,
}) async {
  if (nails.length < 2 || nails.length >= 12) return nails;
  final proposals = await compute(_prepare, (
    bytes: pngBytes,
    width: imageWidth,
    height: imageHeight,
    nails: nails,
  ));
  if (proposals.isEmpty) return nails;
  final recovered = List<NailRegion>.of(nails);
  var nextId = nails.fold<int>(
    firstUnusedId,
    (id, nail) => math.max(id, nail.id + 1),
  );
  for (final proposal in proposals) {
    if (recovered.length >= 12) break;
    final firstTurn = proposal.slender ? 1 : 0;
    onStage?.call('复查深色甲面');
    final first = await predictView(proposal.tensor, firstTurn);
    final second = await predictView(proposal.tensor, firstTurn + 2);
    final local = await compute(_verifiedOutline, (
      proposal: proposal,
      first: first,
      second: second,
    ));
    if (local == null) continue;
    final center = proposal.sourcePoint(local.center.dx, local.center.dy);
    final minDistance = math.min(local.width, local.height) * .65;
    if (recovered.any(
      (nail) => (nail.center - center).distance < minDistance,
    )) {
      continue;
    }
    recovered.add(
      NailRegion(
        id: nextId++,
        label: '甲面 ${recovered.length + 1}',
        center: center,
        width: local.width,
        height: local.height,
        angle: local.angle + proposal.angle,
        maskRgba: local.maskRgba,
        maskWidth: local.maskWidth,
        maskHeight: local.maskHeight,
      ),
    );
  }
  return recovered;
}

class _Patch {
  const _Patch(
    this.center,
    this.angle,
    this.longSide,
    this.shortSide,
    this.rank,
    this.pixels,
  );
  final Offset center;
  final double angle, longSide, shortSide, rank;
  final List<int> pixels;

  bool get slender => longSide / shortSide > 2.8;
}

class _Proposal {
  _Proposal(this.patch, this.side, this.tensor, this.seedSamples, this.outline)
    : _c = math.cos(patch.angle),
      _s = math.sin(patch.angle);
  final _Patch patch;
  final int side;
  final Float32List tensor;
  final List<int> seedSamples;
  final _OutlinePatch outline;
  final double _c, _s;
  bool get slender => patch.slender;
  double get angle => patch.angle;

  Offset sourcePoint(double x, double y) {
    final dx = x - side / 2, dy = y - side / 2;
    return patch.center + Offset(_c * dx - _s * dy, _s * dx + _c * dy);
  }
}

List<_Proposal> _prepare(
  ({Uint8List bytes, int width, int height, List<NailRegion> nails}) input,
) {
  final photo = img.decodePng(input.bytes);
  if (photo == null ||
      photo.width != input.width ||
      photo.height != input.height) {
    return const [];
  }
  final longest = math.max(photo.width, photo.height);
  final sampled = longest <= 224
      ? photo
      : img.copyResize(
          photo,
          width: (photo.width * 224 / longest).round(),
          height: (photo.height * 224 / longest).round(),
          interpolation: img.Interpolation.average,
        );
  final width = sampled.width, height = sampled.height;
  if (math.min(width, height) < 50) return const [];
  final luma = Float32List(width * height);
  var neutral = 0;
  for (final pixel in sampled) {
    luma[pixel.y * width + pixel.x] = _light(pixel);
    final low = math.min(pixel.r, math.min(pixel.g, pixel.b));
    final high = math.max(pixel.r, math.max(pixel.g, pixel.b));
    if (high - low <= 7) neutral++;
  }
  if (neutral < luma.length * .88) return const [];
  final anchors = [
    for (final nail in input.nails)
      if (nail.enabled && !nail.isManual) ?_darkAnchor(photo, nail),
  ];
  if (anchors.length < 2) return const [];
  final areas = anchors.map((anchor) => anchor.$2).toList()..sort();
  final area = areas.length.isEven
      ? (areas[areas.length ~/ 2 - 1] + areas[areas.length ~/ 2]) / 2
      : areas[areas.length ~/ 2];
  final sx = photo.width / width, sy = photo.height / height;
  final background = _localLight(luma, width, height);
  final difference = [
    for (var i = 0; i < luma.length; i++) background[i] - luma[i],
  ];

  final patches = <_Patch>[];
  for (final threshold in [.10, .13]) {
    for (final component in connectedComponents(
      difference,
      width,
      height,
      threshold: threshold,
      minArea: 12,
    )) {
      final patchArea = component.length * sx * sy;
      if (patchArea < area * .10 || patchArea > area * .92) continue;
      final patch = _describePatch(component, luma, width, height, sx, sy);
      if (patch == null ||
          anchors.every(
            (anchor) =>
                (anchor.$1 - patch.center).distance > math.sqrt(area) * 7.3,
          ) ||
          input.nails.any(
            (nail) =>
                nail.contains(patch.center) ||
                (nail.center - patch.center).distance < patch.shortSide * .55,
          )) {
        continue;
      }
      patches.add(patch);
    }
  }
  patches.sort((a, b) => b.rank.compareTo(a.rank));
  final accepted = <_Patch>[];
  for (final patch in patches) {
    if (accepted.any(
      (other) =>
          (other.center - patch.center).distance <
          math.min(other.longSide, patch.longSide) * .45,
    )) {
      continue;
    }
    accepted.add(patch);
    if (accepted.length == 3) break;
  }
  return [for (final patch in accepted) _makeCrop(photo, patch, width, sx, sy)];
}

double _light(img.Pixel pixel) =>
    (.2126 * pixel.r + .7152 * pixel.g + .0722 * pixel.b) / 255;

(Offset, double)? _darkAnchor(img.Image photo, NailRegion nail) {
  final inside = <double>[], outside = <double>[];
  final c = math.cos(nail.angle), s = math.sin(nail.angle);
  for (var y = 0; y < nail.maskHeight; y += 4) {
    for (var x = 0; x < nail.maskWidth; x += 4) {
      final dx = ((x + .5) / nail.maskWidth - .5) * nail.width;
      final dy = ((y + .5) / nail.maskHeight - .5) * nail.height;
      final p = nail.center + Offset(c * dx - s * dy, s * dx + c * dy);
      if (p.dx < 0 || p.dy < 0 || p.dx >= photo.width || p.dy >= photo.height) {
        continue;
      }
      final alpha = nail.maskRgba[(y * nail.maskWidth + x) * 4 + 3];
      final value = _light(photo.getPixel(p.dx.floor(), p.dy.floor()));
      if (alpha >= 128) inside.add(value);
      if (alpha <= 16) outside.add(value);
    }
  }
  if (inside.length < 10 || outside.length < 10) return null;
  inside.sort();
  outside.sort();
  final dark = inside[inside.length ~/ 2];
  final bright = outside[outside.length * 3 ~/ 4];
  if (dark > .42 || bright - dark < .16) return null;
  return (
    nail.center,
    nail.width *
        nail.height *
        inside.length *
        16 /
        (nail.maskWidth * nail.maskHeight),
  );
}

Float32List _localLight(Float32List luma, int width, int height) {
  final sigma = math.min(width, height) * .044;
  final radius = (sigma * 2.5).ceil();
  final kernel = [
    for (var i = -radius; i <= radius; i++)
      math.exp(-i * i / (2 * sigma * sigma)),
  ];
  final total = kernel.reduce((a, b) => a + b);
  for (var i = 0; i < kernel.length; i++) {
    kernel[i] /= total;
  }
  final row = Float32List(luma.length), result = Float32List(luma.length);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var d = -radius; d <= radius; d++) {
        row[y * width + x] +=
            luma[y * width + (x + d).clamp(0, width - 1)] * kernel[d + radius];
      }
    }
  }
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var d = -radius; d <= radius; d++) {
        result[y * width + x] +=
            row[(y + d).clamp(0, height - 1) * width + x] * kernel[d + radius];
      }
    }
  }
  return result;
}

_Patch? _describePatch(
  List<int> pixels,
  Float32List luma,
  int width,
  int height,
  double sx,
  double sy,
) {
  Offset point(int i) => Offset((i % width + .5) * sx, (i ~/ width + .5) * sy);
  var mean = Offset.zero;
  var light = 0.0;
  for (final i in pixels) {
    mean += point(i);
    light += luma[i];
  }
  mean /= pixels.length.toDouble();
  light /= pixels.length;
  if (light < .13 || light > .66) return null;

  var xx = 0.0, yy = 0.0, xy = 0.0;
  for (final i in pixels) {
    final d = point(i) - mean;
    xx += d.dx * d.dx;
    yy += d.dy * d.dy;
    xy += d.dx * d.dy;
  }
  final angle = .5 * math.atan2(2 * xy, xx - yy) - math.pi / 2;
  final c = math.cos(angle), s = math.sin(angle);
  var left = double.infinity, top = double.infinity;
  var right = double.negativeInfinity, bottom = double.negativeInfinity;
  for (final i in pixels) {
    final d = point(i) - mean;
    final x = c * d.dx + s * d.dy, y = -s * d.dx + c * d.dy;
    left = math.min(left, x);
    right = math.max(right, x);
    top = math.min(top, y);
    bottom = math.max(bottom, y);
  }
  final shortSide = right - left, longSide = bottom - top;
  if (shortSide < 3 ||
      longSide < 3 ||
      longSide / shortSide > 5.2 ||
      pixels.length * sx * sy / (shortSide * longSide) < .48) {
    return null;
  }

  // A crease along a dark object has dark pixels beyond it. Require a
  // bright surrounding rim before spending model calls on a shadow.
  final rim = <double>[];
  for (var step = 0; step < 16; step++) {
    final theta = step * math.pi / 8;
    final x = math.cos(theta) * shortSide * .68;
    final y = math.sin(theta) * longSide * .68;
    final px = ((mean.dx + c * x - s * y) / sx).floor();
    final py = ((mean.dy + s * x + c * y) / sy).floor();
    if (px < 0 || py < 0 || px >= width || py >= height) return null;
    rim.add(luma[py * width + px]);
  }
  rim.sort();
  if (rim[0] < .34 || rim[4] < math.max(.55, light + .12) || rim[5] < .64) {
    return null;
  }
  return _Patch(mean, angle, longSide, shortSide, rim[4] + rim[0] * .7, pixels);
}

_Proposal _makeCrop(
  img.Image photo,
  _Patch patch,
  int gridWidth,
  double sx,
  double sy,
) {
  final side = (patch.longSide * (patch.slender ? .94 : 1.29)).round().clamp(
    64,
    280,
  );
  final tensor = Float32List(_modelSide * _modelSide * 3);
  final samples = <int>[];
  final outlineSide = math.max(side * 1.25, patch.longSide * 1.56).ceil();
  final outline = _OutlinePatch(outlineSide, math.max(sx, sy));
  final proposal = _Proposal(patch, side, tensor, samples, outline);
  final step = side / _modelSide;
  final scale = side.clamp(_modelSide, 280);
  final crop = img.Image(width: scale, height: scale);
  for (final pixel in crop) {
    final p = proposal.sourcePoint(
      (pixel.x + .5) * side / scale,
      (pixel.y + .5) * side / scale,
    );
    final color = photo.getPixelInterpolate(
      (p.dx - .5).clamp(0.0, photo.width - 1.0),
      (p.dy - .5).clamp(0.0, photo.height - 1.0),
      interpolation: img.Interpolation.linear,
    );
    pixel.setRgb(color.r, color.g, color.b);
  }
  final image = img.copyResize(
    crop,
    width: _modelSide,
    height: _modelSide,
    interpolation: img.Interpolation.average,
  );
  const plane = _modelSide * _modelSide;
  for (final pixel in image) {
    final i = pixel.y * _modelSide + pixel.x;
    tensor[i] = pixel.r / 127.5 - 1;
    tensor[i + plane] = pixel.g / 127.5 - 1;
    tensor[i + 2 * plane] = pixel.b / 127.5 - 1;
  }
  final c = math.cos(patch.angle), s = math.sin(patch.angle);
  for (final i in patch.pixels) {
    final x = (i % gridWidth + .5) * sx - patch.center.dx;
    final y = (i ~/ gridWidth + .5) * sy - patch.center.dy;
    final local = Offset(x * c + y * s + side / 2, -x * s + y * c + side / 2);
    outline.seeds.add(local);
    final rx = (local.dx / step).floor(), ry = (local.dy / step).floor();
    if (rx >= 0 && rx < _modelSide && ry >= 0 && ry < _modelSide) {
      samples.add(ry * _modelSide + rx);
    }
  }
  final outlineImage = img.Image(width: outline.size, height: outline.size);
  final start = (side - outline.side) / 2;
  for (final pixel in outlineImage) {
    final point = proposal.sourcePoint(
      start + (pixel.x + .5) * outline.step,
      start + (pixel.y + .5) * outline.step,
    );
    final color = photo.getPixelInterpolate(
      (point.dx - .5).clamp(0.0, photo.width - 1.0),
      (point.dy - .5).clamp(0.0, photo.height - 1.0),
      interpolation: img.Interpolation.linear,
    );
    pixel.setRgb(color.r, color.g, color.b);
  }
  for (final pixel in img.gaussianBlur(outlineImage, radius: 2)) {
    outline.light[pixel.y * outline.size + pixel.x] = _light(pixel);
  }
  return proposal;
}

NailRegion? _verifiedOutline(
  ({_Proposal proposal, List<double> first, List<double> second}) input,
) {
  final seed = _corroboratedMask(input.proposal, input.first, input.second);
  if (seed == null) return null;
  return _snapDarkOutline(input.proposal, seed);
}

NailRegion? _corroboratedMask(
  _Proposal proposal,
  List<double> first,
  List<double> second,
) {
  const plane = _modelSide * _modelSide;
  if (first.length != plane ||
      second.length != plane ||
      proposal.seedSamples.isEmpty) {
    return null;
  }
  for (final field in [first, second]) {
    var peak = 0.0, supported = 0;
    for (final pixel in proposal.seedSamples) {
      if (!field[pixel].isFinite) return null;
      peak = math.max(peak, field[pixel]);
      if (field[pixel] >= .38) supported++;
    }
    if (peak < .80 || supported < proposal.seedSamples.length * .16) {
      return null;
    }
  }
  final shared = List<double>.generate(
    plane,
    (i) => math.min(first[i], second[i]),
  );
  List<int>? core;
  var coreScore = 0;
  for (final component in connectedComponents(
    shared,
    _modelSide,
    _modelSide,
    threshold: .38,
    minArea: 85,
  )) {
    if (component.length > plane * .24) continue;
    final members = component.toSet();
    final score = proposal.seedSamples.where(members.contains).length;
    if (score > coreScore) {
      core = component;
      coreScore = score;
    }
  }
  if (core == null || coreScore < proposal.seedSamples.length * .08) {
    return null;
  }

  // A two-pixel transition may retain confident edges in one view. Starting
  // with the agreed component prevents an unrelated patch joining the result.
  final field = List<double>.filled(plane, 0);
  for (final i in core) {
    final x = i % _modelSide, y = i ~/ _modelSide;
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final px = x + dx, py = y + dy;
        if (px < 0 || px >= _modelSide || py < 0 || py >= _modelSide) continue;
        final pixel = py * _modelSide + px;
        final low = shared[pixel];
        final high = math.max(first[pixel], second[pixel]);
        if (low >= .20 && high >= .46) field[pixel] = low * .55 + high * .45;
      }
    }
  }
  final regions = extractNails(
    field,
    _modelSide,
    _modelSide,
    proposal.side,
    proposal.side,
    alreadyFiltered: true,
  )..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
  final region = regions.firstOrNull;
  if (region == null ||
      region.width * region.height < proposal.side * proposal.side * .015) {
    return null;
  }
  return region;
}

class _OutlinePatch {
  _OutlinePatch(this.side, this.seedStep)
    : size = side.clamp(48, 256),
      light = Float32List(side.clamp(48, 256) * side.clamp(48, 256));

  final int side, size;
  final double seedStep;
  final Float32List light;
  final seeds = <Offset>[];

  double get step => side / size;

  double? sample(Offset point, double start) {
    final x = (point.dx - start) / step - .5;
    final y = (point.dy - start) / step - .5;
    final px = x.floor(), py = y.floor();
    if (px < 0 || py < 0 || px + 1 >= size || py + 1 >= size) return null;
    final fx = x - px, fy = y - py, i = py * size + px;
    final top = light[i] * (1 - fx) + light[i + 1] * fx;
    final bottom = light[i + size] * (1 - fx) + light[i + size + 1] * fx;
    return top * (1 - fy) + bottom * fy;
  }
}

const _outlineRays = 64;
const _fullTurn = 2 * math.pi;

NailRegion _snapDarkOutline(_Proposal proposal, NailRegion nail) {
  final patch = proposal.outline;
  final center = nail.center;
  final shorter = math.min(nail.width, nail.height);
  final unit = math.max(1.0, shorter / 60);
  final searchLimit = math.min(
    patch.side.toDouble(),
    proposal.patch.longSide + nail.width,
  );
  final directions = List.generate(_outlineRays, (i) {
    final angle = i * _fullTurn / _outlineRays;
    return Offset(math.cos(angle), math.sin(angle));
  });
  final core = [
    for (final direction in directions)
      _modelRadius(nail, direction, searchLimit, unit),
  ];
  if (core.any((radius) => radius < unit * 2)) return nail;

  // The crop proposal is a single locally dark component surrounded by
  // brighter pixels. The model has already confirmed that it includes a
  // nail. Its outer samples bring back dark regions between glints.
  final hull = _seedHull([
    ...patch.seeds,
    for (var i = 0; i < _outlineRays; i++) center + directions[i] * core[i],
  ]);
  if (hull.length < 3) return nail;
  final prior = [
    for (final direction in directions)
      _hullRadius(hull, center, direction) + patch.seedStep * .65,
  ];
  final anchor = (proposal.side - patch.side) / 2;
  final band = math.max(4.0, shorter * .12);
  final grow = shorter * .26;
  final rays = <_RadialCosts>[];
  for (var ray = 0; ray < _outlineRays; ray++) {
    final direction = directions[ray];
    final from = math.max(
      (core[ray] / unit).ceil(),
      ((prior[ray] - 3 * unit) / unit).floor(),
    );
    final stable = (prior[ray] / unit).round();
    final to = math.max(stable, ((prior[ray] + grow) / unit).round());
    if (to < from) return nail;
    final scores = [
      for (var step = from; step <= to; step++)
        _edgeScore(patch, center, direction, step * unit, anchor, band) -
            math.max(0, step - stable) * .004,
    ];
    scores[stable - from] = math.max(scores[stable - from], .012);
    rays.add((start: from, costs: scores));
  }

  final solved = _smoothRadialEdges(rays);
  final outline = List.generate(_outlineRays, (i) {
    var sum = 0.0;
    for (var d = -2; d <= 2; d++) {
      sum += solved[(i + d) % _outlineRays] * unit;
    }
    return math.max(core[i], sum / 5);
  });
  final coreArea = core.fold<double>(0, (sum, r) => sum + r * r);
  final area = outline.fold<double>(0, (sum, r) => sum + r * r);
  if (area < coreArea * 1.14 || area > coreArea * 7) return nail;

  return _renderDarkOutline(nail, directions, outline);
}

double _modelRadius(
  NailRegion nail,
  Offset direction,
  double limit,
  double unit,
) {
  var farthest = 0.0;
  final c = math.cos(nail.angle), s = math.sin(nail.angle);
  final dx = c * direction.dx + s * direction.dy;
  final dy = -s * direction.dx + c * direction.dy;
  for (var r = 0.0; r <= limit; r += unit) {
    final u = .5 + dx * r / nail.width;
    final v = .5 + dy * r / nail.height;
    if (u < 0 || u >= 1 || v < 0 || v >= 1) break;
    final i =
        (v * nail.maskHeight).floor() * nail.maskWidth +
        (u * nail.maskWidth).floor();
    if (nail.maskRgba[i * 4 + 3] >= 128) farthest = r;
  }
  return farthest;
}

double _cross(Offset a, Offset b) => a.dx * b.dy - a.dy * b.dx;

List<Offset> _seedHull(List<Offset> points) {
  points.sort((a, b) {
    final x = a.dx.compareTo(b.dx);
    return x == 0 ? a.dy.compareTo(b.dy) : x;
  });
  List<Offset> arc(Iterable<Offset> order) {
    final result = <Offset>[];
    for (final point in order) {
      while (result.length >= 2 &&
          _cross(
                result.last - result[result.length - 2],
                point - result.last,
              ) <=
              0) {
        result.removeLast();
      }
      result.add(point);
    }
    return result..removeLast();
  }

  return [...arc(points), ...arc(points.reversed)];
}

double _hullRadius(List<Offset> hull, Offset center, Offset direction) {
  var nearest = double.infinity;
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], edge = hull[(i + 1) % hull.length] - a;
    final speed = _cross(edge, direction);
    if (speed < -1e-8) {
      nearest = math.min(nearest, _cross(edge, center - a) / -speed);
    }
  }
  return nearest;
}

double _edgeScore(
  _OutlinePatch patch,
  Offset center,
  Offset direction,
  double radius,
  double start,
  double band,
) {
  final inner = patch.sample(center + direction * (radius - band), start);
  final outer = patch.sample(center + direction * (radius + band), start);
  if (inner == null || outer == null) return 0;
  final change = outer - inner;
  if (change <= .08) return 0;
  return change * 1.6 * ((outer - .50) / .18).clamp(0.0, 1.0);
}

typedef _RadialCosts = ({int start, List<double> costs});

List<int> _smoothRadialEdges(List<_RadialCosts> rays) {
  // Follow adjacent evidence around the contour with a cost for abrupt
  // jumps. Restrict each ray to a short interval around the verified prior.
  const jump = .008;
  var first = 0, firstIndex = 0;
  var strongest = double.negativeInfinity;
  for (var ray = 0; ray < rays.length; ray++) {
    for (var i = 0; i < rays[ray].costs.length; i++) {
      if (rays[ray].costs[i] <= strongest) continue;
      strongest = rays[ray].costs[i];
      first = ray;
      firstIndex = i;
    }
  }
  final firstRadius = rays[first].start + firstIndex;
  var previous = rays[first];
  var running = List<double>.filled(
    previous.costs.length,
    double.negativeInfinity,
  );
  running[firstIndex] = strongest;
  final backs = <List<int>>[];
  for (var step = 1; step < rays.length; step++) {
    final ray = rays[(first + step) % rays.length];
    final back = List<int>.filled(ray.costs.length, 0);
    final scores = List<double>.filled(ray.costs.length, 0);
    for (var i = 0; i < ray.costs.length; i++) {
      final radius = ray.start + i;
      var best = double.negativeInfinity;
      for (var j = 0; j < running.length; j++) {
        final score = running[j] - (previous.start + j - radius).abs() * jump;
        if (score <= best) continue;
        best = score;
        back[i] = j;
      }
      scores[i] = best + ray.costs[i];
    }
    backs.add(back);
    previous = ray;
    running = scores;
  }
  var last = 0;
  var best = double.negativeInfinity;
  for (var i = 0; i < running.length; i++) {
    final score = running[i] - (previous.start + i - firstRadius).abs() * jump;
    if (score <= best) continue;
    best = score;
    last = i;
  }
  final result = List<int>.filled(rays.length, 0);
  result[first] = firstRadius;
  for (var step = rays.length - 1; step > 0; step--) {
    final index = (first + step) % rays.length;
    result[index] = rays[index].start + last;
    last = backs[step - 1][last];
  }
  return result;
}

NailRegion _renderDarkOutline(
  NailRegion nail,
  List<Offset> directions,
  List<double> radii,
) {
  const margin = 2.0;
  final points = [
    for (var i = 0; i < radii.length; i++)
      nail.center + directions[i] * radii[i],
  ];
  final left = points.map((p) => p.dx).reduce(math.min) - margin;
  final right = points.map((p) => p.dx).reduce(math.max) + margin;
  final top = points.map((p) => p.dy).reduce(math.min) - margin;
  final bottom = points.map((p) => p.dy).reduce(math.max) + margin;
  final width = right - left, height = bottom - top;
  const columns = 80, rows = 120;
  final field = Float32List(columns * rows);
  final pixel = math.max(width / columns, height / rows);
  for (var y = 0; y < rows; y++) {
    final dy = top + (y + .5) * height / rows - nail.center.dy;
    for (var x = 0; x < columns; x++) {
      final dx = left + (x + .5) * width / columns - nail.center.dx;
      final direction =
          (math.atan2(dy, dx) % _fullTurn) * radii.length / _fullTurn;
      final i = direction.floor() % radii.length, t = direction % 1;
      final edge = radii[i] * (1 - t) + radii[(i + 1) % radii.length] * t;
      final distance = math.sqrt(dx * dx + dy * dy);
      field[y * columns + x] = (.5 + .5 * (edge - distance) / pixel).clamp(
        0.0,
        1.0,
      );
    }
  }
  const maskWidth = 128, maskHeight = 192;
  final mask = refineProbabilityContour(
    field,
    columns,
    rows,
    outputWidth: maskWidth,
    outputHeight: maskHeight,
  );
  if (mask.isEmpty || !mask.any((channel) => channel >= 128)) return nail;
  return nail.copyWith(
    center: Offset((left + right) / 2, (top + bottom) / 2),
    width: width,
    height: height,
    angle: 0,
    maskRgba: mask,
    maskWidth: maskWidth,
    maskHeight: maskHeight,
  );
}
