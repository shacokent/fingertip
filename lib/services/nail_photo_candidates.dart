import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'segmentation_geometry.dart';

typedef PhotoViewPredictor =
    Future<List<double>> Function(Float32List tensor, int turns);

/// Searches overlapping views for small photo regions that disappear in the
/// full-frame downsample. Candidates must have independent model support.
Future<List<NailRegion>> recoverNailsFromPhotoViews({
  required Uint8List pngBytes,
  required int imageWidth,
  required int imageHeight,
  required List<NailRegion> nails,
  required List<HandObservation> hands,
  required PhotoViewPredictor predictView,
  void Function(String)? onStage,
}) async {
  if (nails.length >= 12) return nails;
  final tiles = await compute(_prepareTiles, pngBytes);
  if (tiles.isEmpty) return nails;
  final views = <_TileView>[];
  final portrait = imageHeight > imageWidth;
  for (final tile in tiles) {
    onStage?.call('复查小甲面');
    for (final turns in [0, portrait ? 1 : 2]) {
      final field = await predictView(tile.tensor, turns);
      if (field.length == _pixels) views.add(_TileView(tile, turns, field));
    }
  }
  return compute(_recover, (
    views: views,
    nails: nails,
    hands: hands,
    width: imageWidth,
    height: imageHeight,
  ));
}

const _side = 128;
const _pixels = _side * _side;
const _tipIndices = [4, 8, 12, 16, 20];
const _tipJoints = [3, 7, 11, 15, 19];

class _PhotoTile {
  const _PhotoTile(
    this.index,
    this.x,
    this.y,
    this.width,
    this.height,
    this.tensor,
  );
  final int index, x, y, width, height;
  final Float32List tensor;
}

class _TileView {
  const _TileView(this.tile, this.turns, this.field);
  final _PhotoTile tile;
  final int turns;
  final List<double> field;
}

List<_PhotoTile> _prepareTiles(Uint8List pngBytes) {
  final photo = img.decodePng(pngBytes);
  if (photo == null || math.min(photo.width, photo.height) < 48) {
    return const [];
  }
  final portrait = photo.height > photo.width;
  final columns = portrait ? 2 : 3;
  final rows = portrait ? 3 : 2;
  final width = (photo.width * .60).round();
  final height = (photo.height * .60).round();
  final tiles = <_PhotoTile>[];
  for (var row = 0; row < rows; row++) {
    for (var column = 0; column < columns; column++) {
      final x = ((photo.width - width) * column / (columns - 1)).round();
      final y = ((photo.height - height) * row / (rows - 1)).round();
      final sample = img.copyResize(
        img.copyCrop(photo, x: x, y: y, width: width, height: height),
        width: _side,
        height: _side,
        interpolation: img.Interpolation.average,
      );
      final tensor = Float32List(_pixels * 3);
      for (final pixel in sample) {
        final index = pixel.y * _side + pixel.x;
        tensor[index] = pixel.r / 127.5 - 1;
        tensor[index + _pixels] = pixel.g / 127.5 - 1;
        tensor[index + _pixels * 2] = pixel.b / 127.5 - 1;
      }
      tiles.add(_PhotoTile(tiles.length, x, y, width, height, tensor));
    }
  }
  return tiles;
}

class _Candidate {
  const _Candidate(
    this.view,
    this.pixels,
    this.box,
    this.mean,
    this.peak,
    this.contrast,
    this.nearTip,
  );
  final _TileView view;
  final List<int> pixels;
  final Rect box;
  final double mean, peak, contrast;
  final bool nearTip;

  double get rank => mean + peak * .15 + math.min(contrast, .30) * .2;
}

List<NailRegion> _recover(
  ({
    List<_TileView> views,
    List<NailRegion> nails,
    List<HandObservation> hands,
    int width,
    int height,
  })
  input,
) {
  final fingertips = <(Offset, double)>[];
  for (final hand in input.hands.take(2)) {
    if (hand.points.length != 21) continue;
    for (var i = 0; i < _tipIndices.length; i++) {
      final tip = hand.points[_tipIndices[i]];
      final joint = hand.points[_tipJoints[i]];
      final p = Offset(tip.dx * input.width, tip.dy * input.height);
      final axis = Offset(
        (joint.dx - tip.dx) * input.width,
        (joint.dy - tip.dy) * input.height,
      );
      if (p.isFinite && axis.isFinite && axis.distance >= 4) {
        fingertips.add((p + axis * .28, axis.distance));
      }
    }
  }
  final proposals = <_Candidate>[
    for (final view in input.views)
      ..._candidates(view, input.width, input.height, fingertips),
  ]..sort((a, b) => b.rank.compareTo(a.rank));
  final groups = <List<_Candidate>>[];
  for (final item in proposals) {
    final same = groups
        .where((group) => _sameFootprint(item.box, group.first.box))
        .firstOrNull;
    if (same == null) {
      groups.add([item]);
    } else {
      same.add(item);
    }
  }
  final output = List<NailRegion>.of(input.nails);
  var nextId =
      output.fold<int>(-1, (value, nail) => math.max(value, nail.id)) + 1;
  final additions = <Rect>[];
  for (final group in groups) {
    if (output.length >= 12) break;
    final best = group.first;
    final independentTiles = group
        .map((item) => item.view.tile.index)
        .toSet()
        .length;
    final independentDirections = group
        .map((item) => item.view.turns)
        .toSet()
        .length;
    final strong = best.mean >= .66 && best.peak >= .88;
    final anchored = best.nearTip && best.mean >= .58 && best.peak >= .77;
    final distinct =
        best.contrast >= .24 && best.mean >= .60 && best.peak >= .77;
    final corroborated =
        (independentTiles >= 2 && (strong || anchored || distinct)) ||
        (independentDirections >= 2 &&
            (anchored ||
                distinct ||
                (strong && best.mean >= .71 && best.peak >= .93)));
    if (!corroborated ||
        input.nails.any((nail) => _duplicates(best.box, nail)) ||
        additions.any((rect) => _sameFootprint(best.box, rect))) {
      continue;
    }
    final tile = best.view.tile;
    final component = List<double>.filled(_pixels, 0);
    for (final pixel in best.pixels) {
      component[pixel] = best.view.field[pixel];
    }
    final local = extractNails(
      component,
      _side,
      _side,
      tile.width,
      tile.height,
      alreadyFiltered: true,
    ).firstOrNull;
    if (local == null) continue;
    output.add(
      NailRegion(
        id: nextId++,
        label: '甲面 ${output.length + 1}',
        center: local.center + Offset(tile.x.toDouble(), tile.y.toDouble()),
        width: local.width,
        height: local.height,
        angle: local.angle,
        maskRgba: local.maskRgba,
        maskWidth: local.maskWidth,
        maskHeight: local.maskHeight,
      ),
    );
    additions.add(best.box);
  }
  return output;
}

Iterable<_Candidate> _candidates(
  _TileView view,
  int imageWidth,
  int imageHeight,
  List<(Offset, double)> fingertips,
) sync* {
  final tile = view.tile;
  final sx = tile.width / _side, sy = tile.height / _side;
  final minimumImageSide = math.min(imageWidth, imageHeight);
  for (final pixels in connectedComponents(
    view.field,
    _side,
    _side,
    threshold: .38,
    minArea: 5,
  )) {
    var left = _side, top = _side, right = 0, bottom = 0;
    var total = 0.0, peak = 0.0;
    for (final index in pixels) {
      final x = index % _side, y = index ~/ _side;
      left = math.min(left, x);
      top = math.min(top, y);
      right = math.max(right, x + 1);
      bottom = math.max(bottom, y + 1);
      total += view.field[index];
      peak = math.max(peak, view.field[index]);
    }
    final mean = total / pixels.length;
    if (mean < .56 ||
        peak < .72 ||
        (left < 4 && tile.x > 0) ||
        (top < 4 && tile.y > 0) ||
        (right > _side - 4 && tile.x + tile.width < imageWidth) ||
        (bottom > _side - 4 && tile.y + tile.height < imageHeight)) {
      continue;
    }
    final box = Rect.fromLTRB(
      tile.x + left * sx,
      tile.y + top * sy,
      tile.x + right * sx,
      tile.y + bottom * sy,
    );
    if (box.shortestSide < math.max(4, minimumImageSide * .008) ||
        box.longestSide > minimumImageSide * .165 ||
        box.longestSide / box.shortestSide > 3.1 ||
        pixels.length / ((right - left) * (bottom - top)) < .36) {
      continue;
    }
    final nearTip = fingertips.any(
      (tip) => (tip.$1 - box.center).distance <= tip.$2 * .58,
    );
    final contrast = _contrast(tile.tensor, pixels, left, top, right, bottom);
    yield _Candidate(view, pixels, box, mean, peak, contrast, nearTip);
  }
}

double _contrast(
  Float32List rgb,
  List<int> pixels,
  int left,
  int top,
  int right,
  int bottom,
) {
  (double, double) averageChroma(Iterable<int> indices) {
    var r = 0.0, b = 0.0, count = 0;
    for (final i in indices) {
      r += rgb[i] - rgb[i + _pixels];
      b += rgb[i + _pixels * 2] - rgb[i + _pixels];
      count++;
    }
    return (r / count, b / count);
  }

  final center = averageChroma(pixels);
  final sides = <List<int>>[
    if (left >= 2) [for (var y = top; y < bottom; y++) y * _side + left - 2],
    if (right + 1 < _side)
      [for (var y = top; y < bottom; y++) y * _side + right + 1],
    if (top >= 2) [for (var x = left; x < right; x++) (top - 2) * _side + x],
    if (bottom + 1 < _side)
      [for (var x = left; x < right; x++) (bottom + 1) * _side + x],
  ];
  if (sides.length < 2) return 0;
  final differences = <double>[];
  for (final side in sides) {
    final outside = averageChroma(side);
    differences.add(
      math.max((center.$1 - outside.$1).abs(), (center.$2 - outside.$2).abs()),
    );
  }
  differences.sort();
  // Color separation on multiple sides corroborates pigment. Brightness
  // alone would also accept shadow edges and skin creases.
  return differences[(differences.length - 1) ~/ 2];
}

bool _sameFootprint(Rect a, Rect b) {
  final overlap = a.intersect(b);
  if (overlap.isEmpty) return false;
  final area = overlap.width * overlap.height;
  final union = a.width * a.height + b.width * b.height - area;
  return area / union >= .26 &&
      (a.center - b.center).distance <=
          math.max(a.shortestSide, b.shortestSide) * .60;
}

bool _duplicates(Rect box, NailRegion nail) {
  if (!nail.enabled) return false;
  final local = nail.toLocal(box.center);
  if (local.dx.abs() <= nail.width * .34 &&
      local.dy.abs() <= nail.height * .34) {
    return true;
  }
  final c = math.cos(nail.angle).abs(), s = math.sin(nail.angle).abs();
  return _sameFootprint(
    box,
    Rect.fromCenter(
      center: nail.center,
      width: nail.width * c + nail.height * s,
      height: nail.width * s + nail.height * c,
    ),
  );
}
