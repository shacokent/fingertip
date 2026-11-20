import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'nail_photo_candidates.dart' show PhotoViewPredictor;
import 'probability_contour.dart';
import 'segmentation_geometry.dart';

const _side = 128;
const _pixels = _side * _side;
const _threshold = .38;

/// Rechecks distinctly lobed masks in which two touching nails may have been
/// joined in the whole-photo view. Both plates must agree in two local views.
Future<List<NailRegion>> snapNaturalPhotoNailEdges({
  required Uint8List pngBytes,
  required List<NailRegion> nails,
  required PhotoViewPredictor predictView,
  int firstUnusedId = 0,
  void Function(String)? onStage,
}) async {
  if (nails.length >= 12 || !nails.any(_couldBeMerged)) return nails;
  final patches = await compute(_prepare, (bytes: pngBytes, nails: nails));
  if (patches.isEmpty) return nails;
  final result = List<NailRegion>.of(nails);
  var nextId = result.fold<int>(
    firstUnusedId,
    (next, nail) => math.max(next, nail.id + 1),
  );
  for (final patch in patches) {
    onStage?.call('复查相邻甲面');
    final first = await predictView(patch.tensor, 0);
    final second = await predictView(patch.tensor, 2);
    if (first.length != _pixels || second.length != _pixels) continue;
    final replacements = await compute(_split, (
      patch: patch,
      first: first,
      second: second,
      nails: result,
      newId: nextId,
    ));
    if (replacements.length != 2) continue;
    final index = result.indexWhere((nail) => nail.id == patch.nail.id);
    result.replaceRange(index, index + 1, replacements);
    nextId++;
    if (result.length >= 12) break;
  }
  return result;
}

bool _couldBeMerged(NailRegion nail) {
  final short = math.min(nail.width, nail.height);
  final long = math.max(nail.width, nail.height);
  return nail.enabled &&
      !nail.isManual &&
      nail.center.isFinite &&
      nail.angle.isFinite &&
      short >= 12 &&
      long.isFinite &&
      long / short >= 1.65 &&
      nail.maskWidth >= 4 &&
      nail.maskHeight >= 4 &&
      nail.maskRgba.length == nail.maskWidth * nail.maskHeight * 4;
}

class _Patch {
  const _Patch(
    this.nail,
    this.origin,
    this.side,
    this.mask,
    this.area,
    this.cores,
    this.tensor,
  );

  final NailRegion nail;
  final Offset origin;
  final int side, area;
  final Uint8List mask;
  final List<List<int>> cores;
  final Float32List tensor;

  Offset point(int index) => origin + _point(index) * (side / _side);
}

Offset _point(int index) => Offset(index % _side + .5, index ~/ _side + .5);

Offset _center(List<int> pixels) =>
    pixels.fold(Offset.zero, (sum, index) => sum + _point(index)) /
    pixels.length.toDouble();

List<_Patch> _prepare(({Uint8List bytes, List<NailRegion> nails}) input) {
  final photo = img.decodePng(input.bytes);
  if (photo == null) return [];
  final patches = <_Patch>[];
  for (final nail in input.nails.where(_couldBeMerged)) {
    final side = (math.max(nail.width, nail.height) * 1.38).round();
    final left = (nail.center.dx - side / 2).round();
    final top = (nail.center.dy - side / 2).round();
    if (side < 24 ||
        left < 0 ||
        top < 0 ||
        left + side > photo.width ||
        top + side > photo.height) {
      continue;
    }
    final origin = Offset(left.toDouble(), top.toDouble());
    final step = side / _side;
    final mask = Uint8List(_pixels);
    var area = 0;
    for (var i = 0; i < _pixels; i++) {
      if (_contains(nail, origin + _point(i) * step)) {
        mask[i] = 1;
        area++;
      }
    }
    if (area < 180) continue;
    final short = math.min(nail.width, nail.height) / step;
    final distances = _insetDistances(mask);
    final eroded = Float64List(_pixels);
    for (var i = 0; i < _pixels; i++) {
      if (distances[i] > short * .19) eroded[i] = 1;
    }
    final cores = connectedComponents(
      eroded,
      _side,
      _side,
      minArea: math.max(12, (area * .047).ceil()),
    );
    if (cores.length != 2 ||
        (_center(cores[0]) - _center(cores[1])).distance < short * .56) {
      continue;
    }
    final sample = img.copyResize(
      img.copyCrop(photo, x: left, y: top, width: side, height: side),
      width: _side,
      height: _side,
      interpolation: img.Interpolation.average,
    );
    final tensor = Float32List(_pixels * 3);
    for (final pixel in sample) {
      final i = pixel.y * _side + pixel.x;
      tensor[i] = pixel.r / 127.5 - 1;
      tensor[i + _pixels] = pixel.g / 127.5 - 1;
      tensor[i + _pixels * 2] = pixel.b / 127.5 - 1;
    }
    patches.add(_Patch(nail, origin, side, mask, area, cores, tensor));
    if (patches.length == 2) break;
  }
  return patches;
}

bool _contains(NailRegion nail, Offset point) {
  if ((nail.center - point).distanceSquared >
      (nail.width * nail.width + nail.height * nail.height) / 4) {
    return false;
  }
  final p = nail.toLocal(point);
  final x = ((p.dx / nail.width + .5) * nail.maskWidth).floor();
  final y = ((p.dy / nail.height + .5) * nail.maskHeight).floor();
  return x >= 0 &&
      x < nail.maskWidth &&
      y >= 0 &&
      y < nail.maskHeight &&
      nail.maskRgba[(y * nail.maskWidth + x) * 4 + 3] >= 128;
}

Float32List _insetDistances(Uint8List mask) {
  final distance = Float32List.fromList([
    for (final pixel in mask) pixel == 0 ? 0 : _side.toDouble(),
  ]);
  for (final direction in [1, -1]) {
    for (var j = 0; j < _pixels; j++) {
      final i = direction == 1 ? j : _pixels - 1 - j;
      if (mask[i] == 0) continue;
      final x = i % _side, y = i ~/ _side;
      if (x - direction >= 0 && x - direction < _side) {
        distance[i] = math.min(distance[i], distance[i - direction] + 1);
      }
      if (y - direction < 0 || y - direction >= _side) continue;
      final prev = i - direction * _side;
      distance[i] = math.min(distance[i], distance[prev] + 1);
      if (x > 0) {
        distance[i] = math.min(distance[i], distance[prev - 1] + 1.414);
      }
      if (x < _side - 1) {
        distance[i] = math.min(distance[i], distance[prev + 1] + 1.414);
      }
    }
  }
  return distance;
}

List<NailRegion> _split(
  ({
    _Patch patch,
    List<double> first,
    List<double> second,
    List<NailRegion> nails,
    int newId,
  })
  input,
) {
  final patch = input.patch;
  final first = _matchingPlates(patch, input.first);
  final second = _matchingPlates(patch, input.second);
  if (first == null || second == null) return [];
  final joined = <({NailRegion nail, int oldCoverage})>[];
  final combined = Float64List(_pixels);
  final neighbors = input.nails.where(
    (nail) => nail.enabled && nail.id != patch.nail.id,
  );
  for (var lobe = 0; lobe < 2; lobe++) {
    final support = second[lobe].toSet();
    final agreed = [
      for (final i in first[lobe])
        if (support.contains(i)) i,
    ];
    final union = first[lobe].length + second[lobe].length - agreed.length;
    if (agreed.length < union * .58 || agreed.length < patch.area * .26) {
      return [];
    }
    // A weak strip in one view can cut across a real plate. Average the
    // probabilities only inside this lobe's two verified components.
    final fused = [
      for (final i in {...first[lobe], ...second[lobe]})
        if (input.first[i] + input.second[i] >= 2 * _threshold) i,
    ];
    var overlap = 0;
    final step = math.max(1, fused.length ~/ 150);
    for (var k = 0; k < fused.length; k += step) {
      if (neighbors.any((nail) => _contains(nail, patch.point(fused[k])))) {
        overlap++;
      }
    }
    if (overlap * step > fused.length * .09) return [];
    final field = Float64List(_pixels);
    for (final i in fused) {
      if (combined[i] != 0) return [];
      combined[i] = field[i] = 1;
    }
    final candidates = extractNails(
      field,
      _side,
      _side,
      patch.side,
      patch.side,
      alreadyFiltered: true,
    );
    if (candidates.isEmpty) return [];
    final plate = candidates.first;
    joined.add((
      nail: plate,
      oldCoverage: agreed.where((i) => patch.mask[i] == 1).length,
    ));
  }
  if (connectedComponents(
        combined,
        _side,
        _side,
        minArea: (patch.area * .10).round(),
      ).length !=
      2) {
    return [];
  }
  joined.sort((a, b) => b.oldCoverage.compareTo(a.oldCoverage));
  return [
    for (var i = 0; i < joined.length; i++)
      finishDetectedNailContour(
        NailRegion(
          id: i == 0 ? patch.nail.id : input.newId,
          label: i == 0 ? patch.nail.label : '甲面 ${input.newId + 1}',
          center: joined[i].nail.center + patch.origin,
          width: joined[i].nail.width,
          height: joined[i].nail.height,
          angle: joined[i].nail.angle,
          maskWidth: joined[i].nail.maskWidth,
          maskHeight: joined[i].nail.maskHeight,
          maskRgba: joined[i].nail.maskRgba,
        ),
      ),
  ];
}

List<List<int>>? _matchingPlates(_Patch patch, List<double> field) {
  final parts = connectedComponents(field, _side, _side, threshold: _threshold);
  final matched = <List<int>>[];
  for (var lobe = 0; lobe < 2; lobe++) {
    List<int>? best;
    var bestScore = 0.0;
    for (final part in parts) {
      if (part.length < patch.area * .27 || part.length > patch.area * .79) {
        continue;
      }
      var mean = 0.0, peak = 0.0;
      for (final i in part) {
        mean += field[i];
        peak = math.max(peak, field[i]);
      }
      mean /= part.length;
      if (mean < .66 || peak < .88) continue;
      final pixels = part.toSet();
      double covers(List<int> core) =>
          core.where(pixels.contains).length / core.length;
      final coverage = covers(patch.cores[lobe]);
      if (coverage < .65 || covers(patch.cores[1 - lobe]) > .12) continue;
      final score = coverage + mean * .25;
      if (score > bestScore) {
        bestScore = score;
        best = part;
      }
    }
    if (best == null) return null;
    matched.add(best);
  }
  return matched;
}
