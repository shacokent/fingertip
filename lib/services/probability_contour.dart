import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import '../models/nail_models.dart';

/// Removes small sampling steps from an automatically detected nail.
///
/// Distances are measured in photo pixels so the result does not depend on
/// whether the detector emitted a coarse or a refined mask. The outline and
/// material frame remain separate. Alpha represents geometric coverage.
NailRegion finishDetectedNailContour(NailRegion nail) {
  final mw = nail.maskWidth, mh = nail.maskHeight;
  if (nail.isManual ||
      !nail.enabled ||
      mw <= 0 ||
      mh <= 0 ||
      mw > 1024 ||
      mh > 1024 ||
      nail.maskRgba.length != mw * mh * 4 ||
      !nail.width.isFinite ||
      !nail.height.isFinite ||
      nail.width <= 0 ||
      nail.height <= 0) {
    return nail;
  }

  final alpha = Float64List(mw * mh);
  for (var i = 0; i < alpha.length; i++) {
    alpha[i] = nail.maskRgba[i * 4 + 3] / 255;
  }
  final outlines = _probabilityOutlines(alpha, mw, mh, .5);
  if (outlines.isEmpty) return nail;

  final sx = nail.width / mw, sy = nail.height / mh;
  final side = math.min(nail.width, nail.height);
  final displacement = (side * .025).clamp(.35, 4.0);
  final polygons = <List<Offset>>[];
  for (final outline in outlines) {
    final physical = [for (final p in outline) Offset(p.dx * sx, p.dy * sy)];
    final originalArea = _area(physical).abs();
    if (originalArea < 1) continue;
    final faired = _fairOutline(
      physical,
      displacement,
      nail.width,
      nail.height,
    );
    final simplified = _simplifyClosed(faired, displacement * .18);
    final rounded = _roundSmallTurns(simplified, displacement * .64);
    final areaRatio = _area(rounded).abs() / originalArea;
    final accepted = areaRatio >= .94 && areaRatio <= 1.06
        ? _retainCoverage(rounded, areaRatio, nail.width, nail.height)
        : physical;
    polygons.add([for (final p in accepted) Offset(p.dx / sx, p.dy / sy)]);
  }
  if (polygons.isEmpty) return nail;

  final targetWidth = math.max(mw, 128);
  final targetHeight = math.max(mh, 192);
  final coverage = _rasterize(polygons, mw, mh, targetWidth, targetHeight, 4);
  if (!coverage.any((value) => value > 0)) return nail;
  return nail.copyWith(
    maskWidth: targetWidth,
    maskHeight: targetHeight,
    maskRgba: coverage,
  );
}

List<Offset> _retainCoverage(
  List<Offset> points,
  double areaRatio,
  double width,
  double height,
) {
  // Fairing moves convex arcs inward. Recover the lost area only, with
  // a subpixel correction so a filled nail does not retreat at each edge.
  if (areaRatio >= .995) return points;
  var left = width, right = 0.0, top = height, bottom = 0.0;
  for (final point in points) {
    left = math.min(left, point.dx);
    right = math.max(right, point.dx);
    top = math.min(top, point.dy);
    bottom = math.max(bottom, point.dy);
  }
  final center = Offset((left + right) / 2, (top + bottom) / 2);
  final radius = Offset(right - left, bottom - top).distance / 2;
  if (radius <= 0) return points;
  final scale = math.min(math.sqrt(1 / areaRatio), 1 + .8 / radius);
  return [
    for (final point in points)
      Offset(
        (center.dx + (point.dx - center.dx) * scale).clamp(0.0, width),
        (center.dy + (point.dy - center.dy) * scale).clamp(0.0, height),
      ),
  ];
}

List<Offset> _fairOutline(
  List<Offset> points,
  double maxMove,
  double width,
  double height,
) {
  var perimeter = 0.0;
  for (var i = 0; i < points.length; i++) {
    perimeter += (points[(i + 1) % points.length] - points[i]).distance;
  }
  final span = math.min(maxMove * 4, perimeter * .075);
  if (span <= 0) return points;

  Offset neighborAt(int index, int direction, double distance) {
    var i = index;
    for (var steps = 0; steps < points.length; steps++) {
      final j = (i + direction) % points.length;
      final delta = points[j] - points[i];
      final length = delta.distance;
      if (length > 1e-9 && length >= distance) {
        return points[i] + delta * (distance / length);
      }
      distance -= length;
      i = j;
    }
    return points[index];
  }

  return List<Offset>.generate(points.length, (i) {
    final p = points[i];
    // Keep contours which reach the edge of their available mask extent.
    if (p.dx <= 1e-8 ||
        p.dy <= 1e-8 ||
        p.dx >= width - 1e-8 ||
        p.dy >= height - 1e-8) {
      return p;
    }
    final before = neighborAt(i, -1, span) - p;
    final after = neighborAt(i, 1, span) - p;
    final incoming = before.distance, outgoing = after.distance;
    if (incoming < 1e-8 || outgoing < 1e-8) return p;
    final cosTurn =
        -(before.dx * after.dx + before.dy * after.dy) / (incoming * outgoing);
    // An abrupt turn supported by two straight sides is a nail corner.
    // A raster kink loses that straight-line support at this longer scale.
    if (cosTurn < .58 && incoming >= span * .96 && outgoing >= span * .96) {
      return p;
    }
    final shift = (before + after) * .24;
    final distance = shift.distance;
    return distance > maxMove ? p + shift * (maxMove / distance) : p + shift;
  });
}

/// Reconstructs an accepted probability component as a geometric outline.
///
/// Values are model probabilities in [0, 1], sampled at input pixel centers.
/// Callers must isolate the intended nail before calling this function. The
/// output covers the same rectangular extent as the input, at the requested
/// resolution; changing resolution cannot recover missing model information.
///
/// Marching squares retains subpixel probability crossings. Bounded polygon
/// simplification and small quadratic joins remove sampling stair steps while
/// retaining long, sharp corners. Rasterization adds only pixel coverage AA:
/// there is no blurred opacity field, convex hull, template or default growth.
Uint8List refineProbabilityContour(
  List<double> probabilities,
  int width,
  int height, {
  int? outputWidth,
  int? outputHeight,
  double threshold = .5,
  double simplifyTolerance = .35,
  double maxSmoothing = .35,
  double minContourArea = 1,
  int samplesPerPixel = 4,
}) {
  final targetWidth = outputWidth ?? width;
  final targetHeight = outputHeight ?? height;
  if (width <= 0 ||
      height <= 0 ||
      probabilities.length != width * height ||
      targetWidth <= 0 ||
      targetHeight <= 0 ||
      targetWidth > 1024 ||
      targetHeight > 1024 ||
      probabilities.any((p) => !p.isFinite || p < 0 || p > 1) ||
      !threshold.isFinite ||
      threshold <= 0 ||
      threshold >= 1 ||
      !simplifyTolerance.isFinite ||
      simplifyTolerance < 0 ||
      simplifyTolerance > 1 ||
      !maxSmoothing.isFinite ||
      maxSmoothing < 0 ||
      maxSmoothing > 1 ||
      !minContourArea.isFinite ||
      minContourArea < 0 ||
      samplesPerPixel < 1 ||
      samplesPerPixel > 8) {
    throw ArgumentError(
      'Probability contour dimensions or parameters invalid.',
    );
  }
  final outlines = _probabilityOutlines(
    probabilities,
    width,
    height,
    threshold,
  );
  final polygons = <List<Offset>>[];
  for (final outline in outlines) {
    if (outline.length < 3 || _area(outline).abs() < minContourArea) continue;
    final simplified = _simplifyClosed(outline, simplifyTolerance);
    final rounded = _roundSmallTurns(simplified, maxSmoothing);
    if (rounded.length >= 3) polygons.add(rounded);
  }
  return _rasterize(
    polygons,
    width,
    height,
    targetWidth,
    targetHeight,
    samplesPerPixel,
  );
}

List<List<Offset>> _probabilityOutlines(
  List<double> values,
  int width,
  int height,
  double threshold,
) {
  final positions = <String, Offset>{};
  final neighbors = <String, List<String>>{};
  double value(int x, int y) =>
      x < 0 || y < 0 || x >= width || y >= height ? 0 : values[y * width + x];
  void connect(String a, String b) {
    (neighbors[a] ??= []).add(b);
    (neighbors[b] ??= []).add(a);
  }

  // The zero-valued collar closes contours at the actual image boundary.
  for (var y = -1; y < height; y++) {
    for (var x = -1; x < width; x++) {
      final tl = value(x, y), tr = value(x + 1, y);
      final br = value(x + 1, y + 1), bl = value(x, y + 1);
      final code =
          (tl >= threshold ? 1 : 0) |
          (tr >= threshold ? 2 : 0) |
          (br >= threshold ? 4 : 0) |
          (bl >= threshold ? 8 : 0);
      if (code == 0 || code == 15) continue;
      String edge(int edge) {
        final horizontal = edge == 0 || edge == 2;
        final ex = x + (edge == 1 ? 1 : 0);
        final ey = y + (edge == 2 ? 1 : 0);
        final key = '${horizontal ? 'h' : 'v'}:$ex:$ey';
        positions.putIfAbsent(key, () {
          final a = value(ex, ey);
          final b = value(ex + (horizontal ? 1 : 0), ey + (horizontal ? 0 : 1));
          final t = ((threshold - a) / (b - a)).clamp(0.0, 1.0);
          return Offset(
            (ex + .5 + (horizontal ? t : 0)).clamp(0.0, width.toDouble()),
            (ey + .5 + (horizontal ? 0 : t)).clamp(0.0, height.toDouble()),
          );
        });
        return key;
      }

      void segment(int a, int b) => connect(edge(a), edge(b));
      switch (code) {
        case 1:
        case 14:
          segment(3, 0);
        case 2:
        case 13:
          segment(0, 1);
        case 3:
        case 12:
          segment(3, 1);
        case 4:
        case 11:
          segment(1, 2);
        case 6:
        case 9:
          segment(0, 2);
        case 7:
        case 8:
          segment(2, 3);
        case 5:
        case 10:
          // Resolve the saddle using the cell's interpolated center rather
          // than arbitrarily connecting diagonal components.
          final insideCenter = (tl + tr + br + bl) * .25 >= threshold;
          final connectTopRight = code == 5 ? insideCenter : !insideCenter;
          if (connectTopRight) {
            segment(0, 1);
            segment(2, 3);
          } else {
            segment(0, 3);
            segment(1, 2);
          }
      }
    }
  }
  final visited = <String>{};
  final outlines = <List<Offset>>[];
  for (final start in neighbors.keys) {
    if (visited.contains(start)) continue;
    final outline = <Offset>[];
    String? previous;
    var current = start;
    var closed = false;
    for (var steps = 0; steps <= positions.length; steps++) {
      visited.add(current);
      final point = positions[current]!;
      if (outline.isEmpty || (point - outline.last).distanceSquared > 1e-12) {
        outline.add(point);
      }
      final connected = neighbors[current]!;
      if (connected.length != 2) break;
      final next = connected[0] == previous ? connected[1] : connected[0];
      if (next == start) {
        closed = true;
        break;
      }
      if (visited.contains(next)) break;
      previous = current;
      current = next;
    }
    if (outline.length > 1 &&
        (outline.first - outline.last).distanceSquared < 1e-12) {
      outline.removeLast();
    }
    if (closed && outline.length >= 3) outlines.add(outline);
  }
  return outlines;
}

double _area(List<Offset> polygon) {
  var sum = 0.0;
  for (var i = 0; i < polygon.length; i++) {
    final a = polygon[i], b = polygon[(i + 1) % polygon.length];
    sum += a.dx * b.dy - a.dy * b.dx;
  }
  return sum / 2;
}

List<Offset> _simplifyClosed(List<Offset> points, double tolerance) {
  if (tolerance == 0 || points.length < 5) return points;
  var opposite = 1, farthest = 0.0;
  for (var i = 1; i < points.length; i++) {
    final distance = (points[i] - points.first).distanceSquared;
    if (distance > farthest) {
      opposite = i;
      farthest = distance;
    }
  }
  final a = _simplifyOpen(points.sublist(0, opposite + 1), tolerance);
  final b = _simplifyOpen([
    ...points.sublist(opposite),
    points.first,
  ], tolerance);
  final result = [...a.take(a.length - 1), ...b.take(b.length - 1)];
  return result.length >= 3 ? result : points;
}

List<Offset> _simplifyOpen(List<Offset> points, double tolerance) {
  final keep = <int>{0, points.length - 1};
  final work = <(int, int)>[(0, points.length - 1)];
  final limit = tolerance * tolerance;
  while (work.isNotEmpty) {
    final (first, last) = work.removeLast();
    final origin = points[first], direction = points[last] - origin;
    final lengthSquared = direction.distanceSquared;
    var farthest = -1, distance = limit;
    for (var i = first + 1; i < last; i++) {
      final offset = points[i] - origin;
      final t = lengthSquared == 0
          ? 0.0
          : ((offset.dx * direction.dx + offset.dy * direction.dy) /
                    lengthSquared)
                .clamp(0.0, 1.0);
      final deviation = (offset - direction * t).distanceSquared;
      if (deviation > distance) {
        farthest = i;
        distance = deviation;
      }
    }
    if (farthest >= 0) {
      keep.add(farthest);
      work.add((first, farthest));
      work.add((farthest, last));
    }
  }
  return (keep.toList()..sort()).map((index) => points[index]).toList();
}

List<Offset> _roundSmallTurns(List<Offset> points, double maxSmoothing) {
  if (maxSmoothing == 0) return points;
  final result = <Offset>[];
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    final before = points[(i + points.length - 1) % points.length] - p;
    final after = points[(i + 1) % points.length] - p;
    final beforeLength = before.distance, afterLength = after.distance;
    if (beforeLength < 1e-9 || afterLength < 1e-9) continue;
    final cosTurn =
        (-(before.dx * after.dx + before.dy * after.dy) /
                (beforeLength * afterLength))
            .clamp(-1.0, 1.0);
    // A coherent long corner is a shape feature, not a one-pixel staircase.
    if (cosTurn < .57 && beforeLength >= 1.5 && afterLength >= 1.5) {
      result.add(p);
      continue;
    }
    final trim = math.min(
      maxSmoothing,
      math.min(beforeLength, afterLength) * .23,
    );
    final incoming = p + before * (trim / beforeLength);
    final outgoing = p + after * (trim / afterLength);
    final steps = (trim * 2 / .12).ceil().clamp(2, 16);
    for (var step = 0; step <= steps; step++) {
      final t = step / steps, remaining = 1 - t;
      result.add(
        incoming * (remaining * remaining) +
            p * (2 * remaining * t) +
            outgoing * (t * t),
      );
    }
  }
  return result;
}

Uint8List _rasterize(
  List<List<Offset>> polygons,
  int width,
  int height,
  int targetWidth,
  int targetHeight,
  int samples,
) {
  final coverage = Uint16List(targetWidth * targetHeight);
  final subWidth = targetWidth * samples, subHeight = targetHeight * samples;
  for (var sy = 0; sy < subHeight; sy++) {
    final y = (sy + .5) / subHeight * height;
    final intersections = <double>[];
    for (final polygon in polygons) {
      for (var i = 0; i < polygon.length; i++) {
        final a = polygon[i], b = polygon[(i + 1) % polygon.length];
        if ((a.dy > y) == (b.dy > y)) continue;
        intersections.add(a.dx + (y - a.dy) / (b.dy - a.dy) * (b.dx - a.dx));
      }
    }
    intersections.sort();
    final targetRow = sy ~/ samples * targetWidth;
    for (var i = 0; i + 1 < intersections.length; i += 2) {
      final first = (intersections[i] / width * subWidth - .5).ceil().clamp(
        0,
        subWidth,
      );
      final end = (intersections[i + 1] / width * subWidth - .5).ceil().clamp(
        0,
        subWidth,
      );
      for (var sx = first; sx < end; sx++) {
        coverage[targetRow + sx ~/ samples]++;
      }
    }
  }
  final output = Uint8List(coverage.length * 4);
  final total = samples * samples;
  for (var i = 0; i < coverage.length; i++) {
    final alpha = (coverage[i] / total * 255).round().clamp(0, 255);
    final p = i * 4;
    output[p] = output[p + 1] = output[p + 2] = output[p + 3] = alpha;
  }
  return output;
}
