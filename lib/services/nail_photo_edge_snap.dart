import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'probability_contour.dart';

/// Corrects the existing nail edge using separation measured in this photo.
/// Weakly separated edges and all manual regions keep their existing masks.
Future<List<NailRegion>> snapPhotoNailEdges({
  required Uint8List pngBytes,
  required List<NailRegion> nails,
}) {
  if (nails.isEmpty) return Future.value(nails);
  return compute(_snapPhoto, (bytes: pngBytes, nails: nails));
}

List<NailRegion> _snapPhoto(({Uint8List bytes, List<NailRegion> nails}) input) {
  final image = img.decodePng(input.bytes);
  if (image == null) return input.nails;
  return [for (final nail in input.nails) _snapNail(image, nail, input.nails)];
}

class _NailPatch {
  _NailPatch(this.nail, this.step, this.width, this.height)
    : old = Uint8List(width * height),
      valid = Uint8List(width * height),
      red = Float32List(width * height),
      blue = Float32List(width * height),
      light = Float32List(width * height),
      cosine = math.cos(nail.angle),
      sine = math.sin(nail.angle);

  final NailRegion nail;
  final int width, height;
  final double step, cosine, sine;
  final Uint8List old, valid;
  // Opponent color coordinates separate pigment from both bright and shaded
  // skin without a fixed skin color or a particular nail polish hue.
  final Float32List red, blue, light;

  Offset point(int index) {
    final x = (index % width + .5 - width / 2) * step;
    final y = (index ~/ width + .5 - height / 2) * step;
    return nail.center + Offset(cosine * x - sine * y, sine * x + cosine * y);
  }

  Offset chroma(int index) => Offset(red[index], blue[index]);

  Offset normalizedChroma(int index) =>
      chroma(index) / math.max(1, 3 * light[index]);
}

NailRegion _snapNail(img.Image image, NailRegion nail, List<NailRegion> nails) {
  if (!nail.enabled ||
      nail.isManual ||
      !nail.center.isFinite ||
      !nail.width.isFinite ||
      !nail.height.isFinite ||
      !nail.angle.isFinite ||
      math.min(nail.width, nail.height) < 8 ||
      math.max(nail.width, nail.height) > math.max(image.width, image.height) ||
      nail.maskWidth < 4 ||
      nail.maskHeight < 4 ||
      nail.maskRgba.length != nail.maskWidth * nail.maskHeight * 4) {
    return nail;
  }
  final shorter = math.min(nail.width, nail.height);
  final padding = (shorter * .22).clamp(5.0, 28.0);
  final step = math.max(
    .65,
    (math.max(nail.width, nail.height) + 2 * padding) / 220,
  );
  final patch = _NailPatch(
    nail,
    step,
    ((nail.width + 2 * padding) / step).ceil(),
    ((nail.height + 2 * padding) / step).ceil(),
  );
  var left = patch.width, right = -1, top = patch.height, bottom = -1;
  var oldArea = 0;
  for (var i = 0; i < patch.old.length; i++) {
    final x = i % patch.width, y = i ~/ patch.width;
    final mx = (x + .5 - patch.width / 2) * step / nail.width + .5;
    final my = (y + .5 - patch.height / 2) * step / nail.height + .5;
    if (_sampleAlpha(nail, mx, my) >= 128) {
      patch.old[i] = 1;
      oldArea++;
      left = math.min(left, x);
      right = math.max(right, x);
      top = math.min(top, y);
      bottom = math.max(bottom, y);
    }
    final point = patch.point(i);
    if (point.dx < 1 ||
        point.dy < 1 ||
        point.dx >= image.width - 1 ||
        point.dy >= image.height - 1) {
      continue;
    }
    final pixel = image.getPixelInterpolate(
      point.dx - .5,
      point.dy - .5,
      interpolation: img.Interpolation.linear,
    );
    patch.valid[i] = 1;
    patch.red[i] = (pixel.r - pixel.g).toDouble();
    patch.blue[i] = (pixel.b - pixel.g).toDouble();
    patch.light[i] = (pixel.r + pixel.g + pixel.b) / 3;
  }
  final span = math.min(right - left + 1, bottom - top + 1);
  if (oldArea < 24 || span < 8) return nail;
  final toOld = _distances(patch.old, patch.width, 1);
  final toOutside = _distances(patch.old, patch.width, 0);
  final core = <int>[], surround = <int>[];
  for (var i = 0; i < patch.old.length; i++) {
    if (patch.valid[i] == 0) continue;
    if (toOutside[i] > math.max(1, span * .10)) core.add(i);
    if (toOld[i] > math.max(1, span * .09) && toOld[i] <= span * .25) {
      surround.add(i);
    }
  }
  if (core.length < 16 || surround.length < 16) return nail;
  final decision = _colorDecision(patch, core, surround);
  if (decision == null) {
    final rim = _restoreBrightDarkRim(
      patch,
      core,
      surround,
      nails,
      span,
      oldArea,
    );
    return rim == null ? nail : _trace(patch, rim);
  }
  final radius = math.min(27 / step, span * .24);
  final neighbors = [
    for (final other in nails)
      if (other.id != nail.id &&
          other.enabled &&
          other.maskWidth > 0 &&
          other.maskHeight > 0 &&
          other.maskRgba.length == other.maskWidth * other.maskHeight * 4 &&
          (other.center - nail.center).distance <
              (math.max(other.width, other.height) +
                      math.max(nail.width, nail.height)) *
                  .7)
        other,
  ];
  final outside = Uint8List(patch.old.length);
  final trimPossible = Uint8List(patch.old.length);
  for (var i = 0; i < outside.length; i++) {
    if (patch.old[i] == 0) {
      outside[i] = trimPossible[i] = 1;
    } else if (patch.valid[i] != 0 &&
        toOutside[i] <= radius * .72 &&
        decision.trim(i)) {
      trimPossible[i] = 1;
    }
  }
  final trim = _connected(trimPossible, outside, patch.width);
  final retained = Uint8List(patch.old.length);
  final allowed = Uint8List(patch.old.length);
  for (var i = 0; i < retained.length; i++) {
    if (patch.old[i] != 0 && trim[i] == 0) {
      retained[i] = allowed[i] = 1;
    } else if (patch.old[i] == 0 &&
        patch.valid[i] != 0 &&
        toOld[i] <= radius &&
        decision.grow(i) &&
        !neighbors.any((other) => _containsAlpha(other, patch.point(i)))) {
      allowed[i] = 1;
    }
  }
  final finalMask = _connected(allowed, retained, patch.width);
  if (decision.isColor) {
    // Only enclosed, small reflection gaps are filled. Connected background
    // and regions occluded by neighboring fingers are left open.
    _fillSmallHoles(finalMask, patch.width, oldArea);
  }
  final closing = (span * .022).clamp(1.0, 3.0);
  final expanded = Uint8List.fromList(
    _distances(
      finalMask,
      patch.width,
      1,
    ).map((distance) => distance <= closing ? 1 : 0).toList(),
  );
  final closedDistance = _distances(expanded, patch.width, 0);
  for (var i = 0; i < finalMask.length; i++) {
    if (finalMask[i] == 0 &&
        closedDistance[i] > closing &&
        patch.valid[i] != 0 &&
        toOld[i] <= radius &&
        (patch.old[i] == 0 || trim[i] == 0) &&
        !neighbors.any((other) => _containsAlpha(other, patch.point(i)))) {
      finalMask[i] = 1;
    }
  }
  var added = 0, removed = 0;
  for (var i = 0; i < finalMask.length; i++) {
    if (patch.old[i] == finalMask[i]) continue;
    if (finalMask[i] != 0) {
      added++;
    } else {
      removed++;
    }
  }
  final continuePigment = decision.continuePigment;
  final extendColor =
      continuePigment != null &&
      added >= oldArea * .12 &&
      removed < oldArea * .04;
  if (decision.bridgePattern || extendColor) {
    final bridged = decision.bridgePattern
        ? _patternChords(finalMask, patch.width)
        : null;
    final toMask = _distances(finalMask, patch.width, 1);
    final toGrowth = extendColor
        ? _distances(
            Uint8List.fromList([
              for (var i = 0; i < finalMask.length; i++)
                finalMask[i] != 0 && patch.old[i] == 0 ? 1 : 0,
            ]),
            patch.width,
            1,
          )
        : null;
    final extension = Uint8List.fromList(finalMask);
    for (var i = 0; i < extension.length; i++) {
      if (finalMask[i] != 0 ||
          patch.valid[i] == 0 ||
          (patch.old[i] != 0 && trim[i] != 0) ||
          toOld[i] > math.min(43 / step, span * .34) ||
          toMask[i] > span * .13) {
        continue;
      }
      final followsPigment =
          toGrowth != null &&
          toMask[i] <= span * .11 &&
          toGrowth[i] <= span * .15 &&
          continuePigment!(i);
      if ((bridged?[i] == 1 || followsPigment) &&
          !neighbors.any((other) => _containsAlpha(other, patch.point(i)))) {
        extension[i] = 1;
      }
    }
    final connected = _connected(extension, finalMask, patch.width);
    var extra = 0;
    for (var i = 0; i < connected.length; i++) {
      if (connected[i] != 0 && finalMask[i] == 0) extra++;
    }
    if (extra <= oldArea * .09 && added + extra <= oldArea * .34) {
      finalMask.setAll(0, connected);
      added += extra;
    }
  }
  if (added + removed < math.max(3, oldArea * .012) ||
      added > oldArea * (decision.isColor ? .34 : .39) ||
      removed > oldArea * .34) {
    return nail;
  }
  return _trace(patch, finalMask);
}

typedef _EdgeDecision = ({
  bool isColor,
  bool bridgePattern,
  bool Function(int) grow,
  bool Function(int) trim,
  bool Function(int)? continuePigment,
});

_EdgeDecision? _colorDecision(
  _NailPatch patch,
  List<int> core,
  List<int> surround,
) {
  final inner = _medianChroma(core, patch.chroma);
  final outer = _medianChroma(surround, patch.chroma);
  final separation = inner - outer;
  if (separation.distance < 40) {
    final chroma = [
      for (final i in [...core, ...surround]) patch.chroma(i).distance,
    ]..sort();
    if (_percentile(chroma, .9) > 4) return null;
    final inLight = [for (final i in core) patch.light[i]]..sort();
    final outLight = [for (final i in surround) patch.light[i]]..sort();
    final inner75 = _percentile(inLight, .75),
        outerMedian = _percentile(outLight, .5);
    if (inner75 > 65 ||
        outerMedian - inner75 < 32 ||
        outerMedian - _percentile(inLight, .9) < 20) {
      return null;
    }
    final innerMedian = _percentile(inLight, .5);
    final cutoff = math.min(innerMedian + 30, (innerMedian + outerMedian) / 2);
    return (
      isColor: false,
      bridgePattern: false,
      grow: (i) => patch.light[i] <= cutoff,
      trim: (_) => false,
      continuePigment: null,
    );
  }
  // Neutral polish next to warm skin can show strong separation without any
  // distinctive pigment to distinguish it from an adjacent white nail.
  if (inner.distance < 20) return null;
  final axis = separation / separation.distance;
  double score(int i) => _dot(patch.chroma(i), axis);
  final inColor = core.map(score).toList()..sort();
  final outColor = surround.map(score).toList()..sort();
  final inMedian = _percentile(inColor, .5),
      outMedian = _percentile(outColor, .5);
  final mid = (inMedian + outMedian) / 2;
  final background10 = _percentile(outColor, .1);
  final foreground25 = _percentile(inColor, .25),
      background75 = _percentile(outColor, .75);
  final growth = math.max(_percentile(outColor, .82) + 7, mid);
  if (growth >= inMedian - 8) return null;
  final pattern = _percentile(inColor, .10) < background10 - 14;
  final motif = pattern
      ? _secondaryPigment(patch, core, surround, score, background10)
      : null;
  final allowTrim = !pattern && foreground25 >= background75 + 9;
  final trimming = math.min(mid, math.min(foreground25 - 9, background75 + 12));
  final continuation = math.max(
    _percentile(outColor, .82) + 4,
    outMedian + (inMedian - outMedian) * .30,
  );
  return (
    isColor: true,
    bridgePattern: motif != null && separation.distance >= 64,
    grow: (i) => score(i) >= growth || (motif?.call(i) ?? false),
    trim: (i) => allowTrim && score(i) <= trimming,
    continuePigment: !pattern && separation.distance >= 65
        ? (i) => score(i) >= continuation
        : null,
  );
}

/// Finds short chords between already supported edges across pattern gaps.
/// The caller limits the fill depth, area, and distance to the original mask.
Uint8List _patternChords(Uint8List mask, int width) {
  final height = mask.length ~/ width;
  final points = <(int, int)>[];
  for (var y = 0; y < height; y++) {
    var left = width, right = -1;
    for (var x = 0; x < width; x++) {
      if (mask[y * width + x] == 0) continue;
      left = math.min(left, x);
      right = x;
    }
    if (right >= 0) points.add((left, y));
    if (right > left) points.add((right, y));
  }
  points.sort((a, b) => a.$1 == b.$1 ? a.$2 - b.$2 : a.$1 - b.$1);
  List<(int, int)> half(Iterable<(int, int)> ordered) {
    final result = <(int, int)>[];
    for (final p in ordered) {
      while (result.length >= 2) {
        final a = result[result.length - 2], b = result.last;
        final turn =
            (b.$1 - a.$1) * (p.$2 - a.$2) - (b.$2 - a.$2) * (p.$1 - a.$1);
        if (turn > 0) break;
        result.removeLast();
      }
      result.add(p);
    }
    return result;
  }

  final lower = half(points), upper = half(points.reversed);
  final chords = Uint8List(mask.length);
  if (lower.length < 2 || upper.length < 2) return chords;
  final hull = [
    ...lower.take(lower.length - 1),
    ...upper.take(upper.length - 1),
  ];
  final left = List<double>.filled(height, width.toDouble());
  final right = List<double>.filled(height, -1);
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    if (a.$2 == b.$2) continue;
    for (var y = math.min(a.$2, b.$2); y <= math.max(a.$2, b.$2); y++) {
      final x = a.$1 + (y - a.$2) * (b.$1 - a.$1) / (b.$2 - a.$2);
      left[y] = math.min(left[y], x);
      right[y] = math.max(right[y], x);
    }
  }
  for (var y = 0; y < height; y++) {
    for (var x = left[y].ceil(); x <= right[y].floor(); x++) {
      chords[y * width + x] = 1;
    }
  }
  return chords;
}

bool Function(int)? _secondaryPigment(
  _NailPatch patch,
  List<int> core,
  List<int> surround,
  double Function(int) score,
  double background10,
) {
  final secondary = core.where((i) => score(i) < background10 - 14).toList();
  if (secondary.length < 12) return null;
  final value = _medianChroma(secondary, patch.normalizedChroma);
  final strength = value.distance;
  if (strength < .20) return null;
  final direction = value / strength;
  final outside = [
    for (final i in surround) _dot(patch.normalizedChroma(i), direction),
  ]..sort();
  final cutoff = math.max(_percentile(outside, .88) + .055, strength * .50);
  if (cutoff >= strength) return null;
  return (i) {
    final color = patch.normalizedChroma(i);
    return _dot(color, direction) >= cutoff &&
        (color.dx * direction.dy - color.dy * direction.dx).abs() <
            strength * .29;
  };
}

Offset _medianChroma(List<int> indices, Offset Function(int) sample) {
  final a = <double>[], b = <double>[];
  for (final i in indices) {
    final point = sample(i);
    a.add(point.dx);
    b.add(point.dy);
  }
  return Offset(_percentile(a..sort(), .5), _percentile(b..sort(), .5));
}

double _percentile(List<double> sorted, double fraction) =>
    sorted[((sorted.length - 1) * fraction).round()];

double _dot(Offset a, Offset b) => a.dx * b.dx + a.dy * b.dy;

bool _containsAlpha(NailRegion nail, Offset point) {
  final local = nail.toLocal(point);
  return _sampleAlpha(
        nail,
        local.dx / nail.width + .5,
        local.dy / nail.height + .5,
      ) >=
      128;
}

double _sampleAlpha(NailRegion nail, double u, double v) {
  final x = u * nail.maskWidth - .5, y = v * nail.maskHeight - .5;
  return _bilinear(x, y, (ix, iy) {
    if (ix < 0 || iy < 0 || ix >= nail.maskWidth || iy >= nail.maskHeight) {
      return 0;
    }
    return nail.maskRgba[(iy * nail.maskWidth + ix) * 4 + 3].toDouble();
  });
}

double _bilinear(double x, double y, double Function(int, int) value) {
  final ix = x.floor(), iy = y.floor(), fx = x - ix, fy = y - iy;
  return (value(ix, iy) * (1 - fx) + value(ix + 1, iy) * fx) * (1 - fy) +
      (value(ix, iy + 1) * (1 - fx) + value(ix + 1, iy + 1) * fx) * fy;
}

Float32List _distances(Uint8List values, int width, int target) {
  final height = values.length ~/ width;
  final result = Float32List.fromList([
    for (final value in values) value == target ? 0 : 10000,
  ]);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      var distance = result[i];
      if (x > 0) distance = math.min(distance, result[i - 1] + 1);
      if (y > 0) {
        distance = math.min(distance, result[i - width] + 1);
        if (x > 0) {
          distance = math.min(distance, result[i - width - 1] + 1.4142);
        }
        if (x + 1 < width) {
          distance = math.min(distance, result[i - width + 1] + 1.4142);
        }
      }
      result[i] = distance;
    }
  }
  for (var y = height - 1; y >= 0; y--) {
    for (var x = width - 1; x >= 0; x--) {
      final i = y * width + x;
      var distance = result[i];
      if (x + 1 < width) distance = math.min(distance, result[i + 1] + 1);
      if (y + 1 < height) {
        distance = math.min(distance, result[i + width] + 1);
        if (x > 0) {
          distance = math.min(distance, result[i + width - 1] + 1.4142);
        }
        if (x + 1 < width) {
          distance = math.min(distance, result[i + width + 1] + 1.4142);
        }
      }
      result[i] = distance;
    }
  }
  return result;
}

Uint8List _connected(Uint8List allowed, Uint8List seeds, int width) {
  final visited = Uint8List.fromList(seeds);
  final queue = Int32List(allowed.length);
  var tail = 0;
  for (var i = 0; i < visited.length; i++) {
    if (visited[i] != 0) queue[tail++] = i;
  }
  void visit(int i) {
    if (allowed[i] == 0 || visited[i] != 0) return;
    visited[i] = 1;
    queue[tail++] = i;
  }

  for (var head = 0; head < tail; head++) {
    final i = queue[head];
    if (i % width != 0) visit(i - 1);
    if (i % width != width - 1) visit(i + 1);
    if (i >= width) visit(i - width);
    if (i + width < visited.length) visit(i + width);
  }
  return visited;
}

void _fillSmallHoles(Uint8List mask, int width, int area) {
  final clear = Uint8List(mask.length), seeds = Uint8List(mask.length);
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] != 0) continue;
    clear[i] = 1;
    if (i < width ||
        i + width >= mask.length ||
        i % width == 0 ||
        i % width == width - 1) {
      seeds[i] = 1;
    }
  }
  final exterior = _connected(clear, seeds, width);
  final holes = <int>[
    for (var i = 0; i < mask.length; i++)
      if (clear[i] == 1 && exterior[i] == 0) i,
  ];
  if (holes.length <= area * .075) {
    for (final i in holes) {
      mask[i] = 1;
    }
  }
}

NailRegion _trace(_NailPatch patch, Uint8List mask) {
  final nail = patch.nail;
  var width = nail.width, height = nail.height;
  for (var i = 0; i < mask.length; i++) {
    if (mask[i] == 0) continue;
    width = math.max(
      width,
      ((i % patch.width + .5 - patch.width / 2).abs() + 1) * patch.step * 2,
    );
    height = math.max(
      height,
      ((i ~/ patch.width + .5 - patch.height / 2).abs() + 1) * patch.step * 2,
    );
  }
  final ww = math.max(8, (width / patch.step).ceil());
  final hh = math.max(8, (height / patch.step).ceil());
  final field = Float64List(ww * hh);
  for (var y = 0; y < hh; y++) {
    final sy =
        ((y + .5) / hh - .5) * height / patch.step + patch.height / 2 - .5;
    for (var x = 0; x < ww; x++) {
      final sx =
          ((x + .5) / ww - .5) * width / patch.step + patch.width / 2 - .5;
      field[y * ww + x] = _bilinear(sx, sy, (ix, iy) {
        if (ix < 0 || iy < 0 || ix >= patch.width || iy >= patch.height) {
          return 0;
        }
        return mask[iy * patch.width + ix].toDouble();
      });
    }
  }
  final rgba = refineProbabilityContour(
    field,
    ww,
    hh,
    outputWidth: nail.maskWidth,
    outputHeight: nail.maskHeight,
    simplifyTolerance: .60,
    maxSmoothing: .72,
  );
  if (!rgba.any((value) => value > 0)) return nail;
  return finishDetectedNailContour(
    nail.copyWith(width: width, height: height, maskRgba: rgba),
  );
}

/// A narrow reflection can hide the edge of dark gloss in a monochrome
/// photo. Follow a coherent bright ridge up to its falloff, with a bounded
/// search from the original mask.
Uint8List? _restoreBrightDarkRim(
  _NailPatch patch,
  List<int> core,
  List<int> surround,
  List<NailRegion> nails,
  int span,
  int area,
) {
  if (span * patch.step < 30 ||
      core.where((i) => patch.light[i] < 95).length < core.length * .60 ||
      core.where((i) => patch.light[i] > 135).length < core.length * .08 ||
      [
            ...core,
            ...surround,
          ].where((i) => patch.chroma(i).distance <= 4).length <
          (core.length + surround.length) * .95) {
    return null;
  }
  const directions = 240;
  const nativeStep = .75;
  final step = nativeStep / patch.step;
  final limit = (math.min(19, span * patch.step * .11) / nativeStep).round();
  final xc = (patch.width - 1) / 2, yc = (patch.height - 1) / 2;
  final edge = Int32List(directions);
  final growth = Int32List(directions);
  final profile = Float32List((math.sqrt(xc * xc + yc * yc) / step).ceil() + 1);
  for (var a = 0; a < directions; a++) {
    final angle = a * math.pi * 2 / directions;
    final dx = math.cos(angle) * step, dy = math.sin(angle) * step;
    var length = 0;
    for (; length < profile.length; length++) {
      final x = xc + length * dx, y = yc + length * dy;
      if (x < 0 || x >= patch.width - 1 || y < 0 || y >= patch.height - 1) {
        break;
      }
      final i = y.round() * patch.width + x.round();
      if (patch.valid[i] == 0) break;
      if (patch.old[i] != 0) edge[a] = length;
      profile[length] = _bilinear(
        x,
        y,
        (ix, iy) => patch.light[iy * patch.width + ix],
      );
    }
    final start = edge[a];
    if (start < 7 || start + 8 >= length) continue;
    var peak = 0.0, gradient = 15.0;
    for (var j = start - 7; j <= start; j++) {
      peak = math.max(peak, profile[j]);
    }
    for (var j = start + 1; j <= start + limit && j + 8 < length; j++) {
      peak = math.max(peak, profile[j]);
      if (peak < 126) continue;
      final drop = profile[j - 2] - profile[j + 2];
      if (drop < gradient) continue;
      var outside = 0.0;
      for (var k = 3; k <= 8; k++) {
        outside += profile[j + k] / 6;
      }
      if (outside < 75 && peak - outside >= 58) {
        gradient = drop;
        growth[a] = j - start;
      }
    }
  }
  final rim = Float32List(directions);
  for (var a = 0; a < directions; a++) {
    var count = 0, sum = 0;
    for (var j = -3; j <= 3; j++) {
      final value = growth[(a + j) % directions];
      if (value > 1) count++;
      sum += value;
    }
    if (growth[a] > 1 && count >= 5) {
      rim[a] = math.min(growth[a] + .0, sum / 7);
    }
  }
  final allowed = Uint8List.fromList(patch.old);
  for (var i = 0; i < allowed.length; i++) {
    if (allowed[i] != 0 || patch.valid[i] == 0) continue;
    final dx = i % patch.width - xc, dy = i ~/ patch.width - yc;
    final direction =
        (math.atan2(dy, dx) * directions / (2 * math.pi)) % directions;
    final before = direction.floor(), after = (before + 1) % directions;
    final t = direction - before;
    if (rim[before] == 0 || rim[after] == 0) continue;
    final reach =
        (edge[before] + rim[before]) * (1 - t) + (edge[after] + rim[after]) * t;
    if (dx * dx + dy * dy > reach * reach * step * step) continue;
    final point = patch.point(i);
    if (nails.any(
      (nail) =>
          nail.id != patch.nail.id &&
          nail.enabled &&
          nail.maskRgba.length == nail.maskWidth * nail.maskHeight * 4 &&
          _containsAlpha(nail, point),
    )) {
      continue;
    }
    allowed[i] = 1;
  }
  final mask = _connected(allowed, patch.old, patch.width);
  final added = mask.where((value) => value != 0).length - area;
  return added >= math.max(3, area * .012) && added <= area * .18 ? mask : null;
}
