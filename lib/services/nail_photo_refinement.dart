import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../models/nail_models.dart';
import 'mask_refinement.dart';
import 'nail_segmentation.dart';
import 'segmentation_geometry.dart';

typedef PhotoCropPredictor = Future<List<double>> Function(Float32List tensor);

/// Geometry-only diagnostics; contains no photograph, path or pixel payload.
class PhotoRefinementReport {
  const PhotoRefinementReport({
    required this.nailId,
    required this.accepted,
    required this.reason,
    this.overlap = 0,
    this.areaRatio = 0,
    this.centerShift = 0,
    this.fieldWidth = 0,
    this.fieldHeight = 0,
    this.weakBoundary = false,
  });
  final int nailId;
  final bool accepted;
  final String reason;
  final double overlap, areaRatio, centerShift;
  final int fieldWidth, fieldHeight;
  final bool weakBoundary;

  Map<String, Object> toJson() => {
    'nailId': nailId,
    'accepted': accepted,
    'reason': reason,
    'overlap': overlap,
    'areaRatio': areaRatio,
    'centerShift': centerShift,
    'fieldWidth': fieldWidth,
    'fieldHeight': fieldHeight,
    'weakBoundary': weakBoundary,
  };
}

/// Uses existing mask and crop evidence to suggest which nails to review.
/// A runtime refinement failure alone is not evidence about a specific nail.
Map<int, NailEdgeReviewReason> photoNailEdgeReviews({
  required List<NailRegion> nails,
  required int imageWidth,
  required int imageHeight,
  required List<PhotoRefinementReport> reports,
}) {
  final byId = {for (final report in reports) report.nailId: report};
  final reviews = <int, NailEdgeReviewReason>{};
  for (final nail in nails) {
    if (!nail.enabled || nail.isManual) continue;
    final report = byId[nail.id];
    if (_maskNearPhotoEdge(nail, imageWidth, imageHeight)) {
      reviews[nail.id] = NailEdgeReviewReason.photoEdge;
    } else if (report != null) {
      if (_localFitDisagrees(report)) {
        reviews[nail.id] = NailEdgeReviewReason.localFitMismatch;
      } else if (report.weakBoundary) {
        reviews[nail.id] = NailEdgeReviewReason.softBoundary;
      }
    }
  }
  return Map.unmodifiable(reviews);
}

bool _localFitDisagrees(PhotoRefinementReport report) {
  if (report.accepted) {
    return report.overlap < .76 ||
        report.areaRatio < .80 ||
        report.areaRatio > 1.25;
  }
  return report.reason == 'geometry_guard' ||
      report.reason == 'no_overlapping_candidate' ||
      report.reason == 'empty_refined_contour';
}

const _unconfirmedByCrossViews = 'unconfirmed_by_cross_views';

/// Suppress a photo candidate only when there is explicit contrary evidence.
/// Independent-view rejection and a small, skin-colored outlier in an
/// otherwise strongly colored group are separate checks.
Future<List<NailRegion>> suppressUnsupportedPhotoNails({
  required Uint8List pngBytes,
  required List<NailRegion> nails,
  required Set<int> initialIds,
  required Set<int> singleViewIds,
  required List<PhotoRefinementReport> reports,
}) async {
  final rejected = {
    for (final report in reports)
      if (report.reason == _unconfirmedByCrossViews) report.nailId,
  };
  final retained = <NailRegion>[];
  for (final nail in nails) {
    if (rejected.contains(nail.id)) continue;
    if (!initialIds.contains(nail.id) &&
        retained.any((other) => _maskContainedBy(nail, other))) {
      continue;
    }
    retained.add(nail);
  }
  final disagreements = {
    for (final report in reports)
      if (_localFitDisagrees(report)) report.nailId,
  };
  final suspect = disagreements.intersection(singleViewIds);
  final anchors = initialIds.difference(singleViewIds).difference(rejected);
  final verifyColor =
      suspect.isNotEmpty && retained.length >= 4 && anchors.length >= 3;
  final padCandidates = {
    for (final nail in retained)
      if (!nail.isManual &&
          nail.enabled &&
          initialIds.contains(nail.id) &&
          disagreements.contains(nail.id) &&
          nail.label.endsWith('拇指'))
        nail.id,
  };
  if (!verifyColor && padCandidates.isEmpty) return retained;
  return compute(_reviewPhotoAppearance, (
    png: pngBytes,
    nails: retained,
    suspect: verifyColor ? suspect : <int>{},
    anchors: anchors,
    padCandidates: padCandidates,
  ));
}

bool _maskContainedBy(NailRegion nail, NailRegion other) {
  if ((nail.center - other.center).distance >
      (math.max(nail.width, nail.height) +
              math.max(other.width, other.height)) /
          2) {
    return false;
  }
  final ca = math.cos(nail.angle), sa = math.sin(nail.angle);
  var shared = 0, area = 0;
  const samples = 18;
  for (var y = 0; y < samples; y++) {
    final v = (y + .5) / samples;
    final ly = (v - .5) * nail.height;
    for (var x = 0; x < samples; x++) {
      final u = (x + .5) / samples;
      final index =
          (v * nail.maskHeight).floor() * nail.maskWidth +
          (u * nail.maskWidth).floor();
      if (nail.maskRgba[index * 4 + 3] < 128) continue;
      area++;
      final lx = (u - .5) * nail.width;
      final point = nail.center + Offset(ca * lx - sa * ly, sa * lx + ca * ly);
      if (_nailAlpha(other, point) >= 128) shared++;
    }
  }
  return area > 0 && shared / area >= .58;
}

List<NailRegion> _reviewPhotoAppearance(
  ({
    Uint8List png,
    List<NailRegion> nails,
    Set<int> suspect,
    Set<int> anchors,
    Set<int> padCandidates,
  })
  request,
) {
  final photo = img.decodeImage(request.png);
  if (photo == null) return request.nails;
  final verified = [
    for (final nail in request.nails)
      if (!request.padCandidates.contains(nail.id) ||
          !_hasFingerprintRidges(photo, nail))
        nail,
  ];
  return request.suspect.isEmpty
      ? verified
      : _dropChromaticOutliers(
          photo,
          verified,
          request.suspect,
          request.anchors,
        );
}

List<NailRegion> _dropChromaticOutliers(
  img.Image photo,
  List<NailRegion> nails,
  Set<int> suspect,
  Set<int> anchors,
) {
  final strongAreas = <double>[];
  for (final nail in nails.where((nail) => anchors.contains(nail.id))) {
    final evidence = _nailColorEvidence(photo, nail);
    if (evidence != null && evidence.contrast >= .11) {
      strongAreas.add(evidence.area);
    }
  }
  if (strongAreas.length < 3) return nails;
  strongAreas.sort();
  final medianArea = strongAreas[strongAreas.length ~/ 2];
  return nails.where((nail) {
    if (!suspect.contains(nail.id) ||
        _maskNearPhotoEdge(nail, photo.width, photo.height)) {
      return true;
    }
    final evidence = _nailColorEvidence(photo, nail);
    return evidence == null ||
        evidence.area >= medianArea * .23 ||
        evidence.contrast >= .045;
  }).toList();
}

const _ridgePatch = 22;
final _ridgeLags = [
  for (var y = 0; y <= 5; y++)
    for (var x = -5; x <= 5; x++)
      if ((y > 0 || x > 0) && x * x + y * y >= 8 && x * x + y * y <= 25) (x, y),
];

/// Repeated close ridges inside a suspected thumb region are positive
/// evidence of a fingertip pad. A single crease, edge, or smooth area is
/// insufficient. Measure native photo pixels before altering the contour.
bool _hasFingerprintRidges(img.Image photo, NailRegion nail) {
  if (photo.width < _ridgePatch + 2 || photo.height < _ridgePatch + 2) {
    return false;
  }
  final radius = (math.max(nail.width, nail.height) * .63).ceil().clamp(
    12,
    100,
  );
  final left = (nail.center.dx.floor() - radius).clamp(1, photo.width - 1);
  final top = (nail.center.dy.floor() - radius).clamp(1, photo.height - 1);
  final right = (nail.center.dx.floor() + radius).clamp(1, photo.width - 1);
  final bottom = (nail.center.dy.floor() + radius).clamp(1, photo.height - 1);
  final width = right - left, height = bottom - top;
  if (width < _ridgePatch || height < _ridgePatch) return false;
  final gray = Float64List((width + 2) * (height + 2));
  final stride = width + 2;
  for (var y = 0; y < height + 2; y++) {
    for (var x = 0; x < stride; x++) {
      final pixel = photo.getPixel(left + x - 1, top + y - 1);
      gray[y * stride + x] =
          pixel.r * .2126 + pixel.g * .7152 + pixel.b * .0722;
    }
  }
  final texture = Float64List(width * height);
  final interior = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = y * width + x;
      if (_nailAlpha(nail, Offset(left + x + .5, top + y + .5)) < 195) continue;
      interior[i] = 1;
      final center = (y + 1) * stride + x + 1;
      var smooth = 0.0;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          smooth += gray[center + dy * stride + dx];
        }
      }
      texture[i] = gray[center] - smooth / 9;
    }
  }
  final sites = <Offset>[];
  final patch = Float64List(_ridgePatch * _ridgePatch);
  for (var y = 0; y <= height - _ridgePatch; y += 5) {
    for (var x = 0; x <= width - _ridgePatch; x += 5) {
      final site = Offset(x.toDouble(), y.toDouble());
      if (sites.any((other) => (other - site).distanceSquared < 100)) continue;
      var covered = 0;
      var sum = 0.0;
      for (var j = 0; j < _ridgePatch; j++) {
        for (var i = 0; i < _ridgePatch; i++) {
          final index = (y + j) * width + x + i;
          covered += interior[index];
          final value = texture[index];
          patch[j * _ridgePatch + i] = value;
          sum += value;
        }
      }
      if (covered < patch.length * .93) continue;
      final mean = sum / patch.length;
      var energy = 0.0;
      for (var i = 0; i < patch.length; i++) {
        patch[i] -= mean;
        energy += patch[i] * patch[i];
      }
      if (energy < patch.length * 1.6 * 1.6) continue;
      if (_ridgeLags.any(
        (lag) =>
            _ridgeCorrelation(
                  patch,
                  (lag.$1 / 2).round(),
                  (lag.$2 / 2).round(),
                ) <
                -.30 &&
            _ridgeCorrelation(patch, lag.$1, lag.$2) > .38,
      )) {
        sites.add(site);
        if (sites.length >= 4) return true;
      }
    }
  }
  return false;
}

double _ridgeCorrelation(Float64List patch, int dx, int dy) {
  var sum = 0.0, aEnergy = 0.0, bEnergy = 0.0;
  for (var y = math.max(0, -dy); y < _ridgePatch - math.max(0, dy); y++) {
    for (var x = math.max(0, -dx); x < _ridgePatch - math.max(0, dx); x++) {
      final a = patch[y * _ridgePatch + x];
      final b = patch[(y + dy) * _ridgePatch + x + dx];
      sum += a * b;
      aEnergy += a * a;
      bEnergy += b * b;
    }
  }
  return aEnergy * bEnergy > 0 ? sum / math.sqrt(aEnergy * bEnergy) : 0;
}

({double area, double contrast})? _nailColorEvidence(
  img.Image photo,
  NailRegion nail,
) {
  // Median chromaticity inside and just outside the projected local mask
  // reduces sensitivity to highlights and avoids any fixed skin-color range.
  final inside = List.generate(3, (_) => <double>[]);
  final outside = List.generate(3, (_) => <double>[]);
  final ca = math.cos(nail.angle), sa = math.sin(nail.angle);
  const side = 22;
  var area = 0;
  for (var y = 0; y < side; y++) {
    final v = (y + .5) / side;
    final ly = (v - .5) * nail.height;
    for (var x = 0; x < side; x++) {
      final u = (x + .5) / side;
      final i =
          (v * nail.maskHeight).floor() * nail.maskWidth +
          (u * nail.maskWidth).floor();
      final alpha = nail.maskRgba[i * 4 + 3];
      if (alpha >= 128) area++;
      if (alpha > 5 && alpha < 220) continue;
      final lx = (u - .5) * nail.width;
      final px = (nail.center.dx + ca * lx - sa * ly).floor();
      final py = (nail.center.dy + sa * lx + ca * ly).floor();
      if (px < 0 || py < 0 || px >= photo.width || py >= photo.height) continue;
      final color = photo.getPixel(px, py);
      final samples = alpha >= 220 ? inside : outside;
      samples[0].add(color.rNormalized.toDouble());
      samples[1].add(color.gNormalized.toDouble());
      samples[2].add(color.bNormalized.toDouble());
    }
  }
  if (inside[0].length < 12 || outside[0].length < 12) return null;
  List<double> chromaticity(List<List<double>> samples) {
    final medians = [
      for (final channel in samples) (channel..sort())[channel.length ~/ 2],
    ];
    final sum = medians.reduce((a, b) => a + b) + .07;
    return [for (final value in medians) value / sum];
  }

  final a = chromaticity(inside), b = chromaticity(outside);
  var distance = 0.0;
  for (var i = 0; i < 3; i++) {
    final delta = a[i] - b[i];
    distance += delta * delta;
  }
  return (
    area: area * nail.width * nail.height / (side * side),
    contrast: math.sqrt(distance),
  );
}

bool _maskNearPhotoEdge(NailRegion nail, int width, int height) {
  final ca = math.cos(nail.angle), sa = math.sin(nail.angle);
  final extentX = (ca.abs() * nail.width + sa.abs() * nail.height) / 2;
  final extentY = (sa.abs() * nail.width + ca.abs() * nail.height) / 2;
  // Near means within one pixel of the full-image model input.
  final marginX = width / 128, marginY = height / 128;
  bool nearEdge(double x, double y) =>
      x <= marginX ||
      x >= width - marginX ||
      y <= marginY ||
      y >= height - marginY;
  if (!nearEdge(nail.center.dx - extentX, nail.center.dy - extentY) &&
      !nearEdge(nail.center.dx + extentX, nail.center.dy + extentY)) {
    return false;
  }
  final mw = nail.maskWidth, mh = nail.maskHeight;
  if (mw <= 0 || mh <= 0 || nail.maskRgba.length != mw * mh * 4) return false;
  var edgeSamples = 0;
  for (var y = 0; y < mh; y++) {
    final ly = ((y + .5) / mh - .5) * nail.height;
    for (var x = 0; x < mw; x++) {
      if (nail.maskRgba[(y * mw + x) * 4 + 3] < 128) continue;
      final lx = ((x + .5) / mw - .5) * nail.width;
      final px = nail.center.dx + ca * lx - sa * ly;
      final py = nail.center.dy + sa * lx + ca * ly;
      // Require several painted samples. Padding or one stray pixel is not
      // enough to suggest that the photo may have cut off the nail.
      if (nearEdge(px, py) && ++edgeSamples >= 3) return true;
    }
  }
  return false;
}

/// Refines only already located photo nails. Preview inference is unchanged.
/// Local predictions cannot add a nail, move its axes, replace a reliable
/// interior with a template, or silently erase coverage after failed inference.
Future<List<NailRegion>> refinePhotoNails({
  required Uint8List pngBytes,
  required int imageWidth,
  required int imageHeight,
  required List<NailRegion> nails,
  required List<double> coarseProbabilities,
  required NailSegmentationEngine engine,
  void Function(String)? onStage,
  PhotoCropPredictor? predictor,
  void Function(PhotoRefinementReport)? onRefinement,
  Set<int> verifyCandidateIds = const {},
  double contourThreshold = .30,
}) async {
  if (imageWidth <= 0 ||
      imageHeight <= 0 ||
      coarseProbabilities.length != 128 * 128 ||
      coarseProbabilities.any((p) => !p.isFinite || p < 0 || p > 1) ||
      !contourThreshold.isFinite ||
      contourThreshold <= 0 ||
      contourThreshold >= 1) {
    throw ArgumentError(
      'Photo refinement dimensions or probabilities invalid.',
    );
  }
  if (nails.isEmpty) return List<NailRegion>.of(nails);
  final crops = await compute(
    _prepareCrops,
    _PhotoRequest(pngBytes, imageWidth, imageHeight, nails),
  );
  final output = List<NailRegion>.of(nails);
  final predict = predictor ?? engine.predictPhotoCrop;
  for (var index = 0; index < crops.length; index++) {
    final crop = crops[index];
    if (crop == null) {
      onRefinement?.call(
        PhotoRefinementReport(
          nailId: nails[index].id,
          accepted: false,
          reason: 'invalid_or_disabled',
        ),
      );
      continue;
    }
    onStage?.call('精修甲缘 ${index + 1}/${nails.length}');
    try {
      final probabilities = await predict(crop.tensor);
      final result = await compute(
        _refineCrop,
        _CropResult(
          crop,
          probabilities,
          coarseProbabilities,
          imageWidth,
          imageHeight,
          contourThreshold,
        ),
      );
      if (nails.length > 1 &&
          verifyCandidateIds.contains(crop.nail.id) &&
          _localFitDisagrees(result.report)) {
        final side = crop.side.toDouble();
        final frame = Rect.fromLTWH(
          crop.left.toDouble(),
          crop.top.toDouble(),
          side,
          side,
        );
        final left = await engine.predictPhotoView(crop.tensor, 1);
        final right = await engine.predictPhotoView(crop.tensor, 3);
        if (nailViewSupport(crop.nail, left, frame) < .30 &&
            nailViewSupport(crop.nail, right, frame) < .30 &&
            !_maskNearPhotoEdge(crop.nail, imageWidth, imageHeight)) {
          onRefinement?.call(
            PhotoRefinementReport(
              nailId: crop.nail.id,
              accepted: false,
              reason: _unconfirmedByCrossViews,
            ),
          );
          continue;
        }
      }
      if (result.report.accepted) output[index] = result.nail;
      onRefinement?.call(result.report);
    } catch (_) {
      // Failure is per nail: keep the exact original mask and continue others.
      onRefinement?.call(
        PhotoRefinementReport(
          nailId: crop.nail.id,
          accepted: false,
          reason: 'prediction_failed',
        ),
      );
    }
  }
  return output;
}

class _PhotoRequest {
  const _PhotoRequest(this.png, this.width, this.height, this.nails);
  final Uint8List png;
  final int width, height;
  final List<NailRegion> nails;
}

class _PreparedCrop {
  const _PreparedCrop(this.nail, this.left, this.top, this.side, this.tensor);
  final NailRegion nail;
  final int left, top, side;
  final Float32List tensor;
}

List<_PreparedCrop?> _prepareCrops(_PhotoRequest request) {
  final photo = img.decodeImage(request.png);
  if (photo == null ||
      photo.width != request.width ||
      photo.height != request.height) {
    throw const FormatException(
      'Photo dimensions changed before edge refinement.',
    );
  }
  final output = <_PreparedCrop?>[];
  for (final nail in request.nails) {
    if (!nail.enabled ||
        !nail.width.isFinite ||
        !nail.height.isFinite ||
        !nail.angle.isFinite ||
        !nail.center.dx.isFinite ||
        !nail.center.dy.isFinite ||
        nail.width <= 0 ||
        nail.height <= 0 ||
        nail.maskWidth <= 0 ||
        nail.maskHeight <= 0 ||
        nail.maskRgba.length != nail.maskWidth * nail.maskHeight * 4) {
      output.add(null);
      continue;
    }
    final side = math.max(16, (3 * math.max(nail.width, nail.height)).ceil());
    // A near full-image false component must not allocate a huge padded image.
    if (side > 2 * math.max(request.width, request.height)) {
      output.add(null);
      continue;
    }
    final left = (nail.center.dx - side / 2).floor();
    final top = (nail.center.dy - side / 2).floor();
    final square = img.Image(width: side, height: side, numChannels: 3);
    for (var y = 0; y < side; y++) {
      final sy = (top + y).clamp(0, photo.height - 1);
      for (var x = 0; x < side; x++) {
        final p = photo.getPixel((left + x).clamp(0, photo.width - 1), sy);
        square.setPixelRgb(x, y, p.r, p.g, p.b);
      }
    }
    final input = img.copyResize(
      square,
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
    output.add(_PreparedCrop(nail, left, top, side, tensor));
  }
  return output;
}

class _CropResult {
  const _CropResult(
    this.crop,
    this.probabilities,
    this.coarse,
    this.width,
    this.height,
    this.contourThreshold,
  );
  final _PreparedCrop crop;
  final List<double> probabilities, coarse;
  final int width, height;
  final double contourThreshold;
}

class _RefinedCrop {
  const _RefinedCrop(this.nail, this.report);
  final NailRegion nail;
  final PhotoRefinementReport report;
}

_RefinedCrop _refineCrop(_CropResult request) {
  const size = 128, threshold = .38;
  final crop = request.crop, nail = request.crop.nail;
  final p = request.probabilities;
  _RefinedCrop unchanged(
    String reason, [
    double overlap = 0,
    double ratio = 0,
    double shift = 0,
  ]) => _RefinedCrop(
    nail,
    PhotoRefinementReport(
      nailId: nail.id,
      accepted: false,
      reason: reason,
      overlap: overlap,
      areaRatio: ratio,
      centerShift: shift,
    ),
  );
  if (p.length != size * size || p.any((v) => !v.isFinite || v < 0 || v > 1)) {
    return unchanged('invalid_prediction');
  }
  final old = Uint8List(size * size);
  var oldArea = 0, oldX = 0.0, oldY = 0.0;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final point = Offset(
        crop.left + (x + .5) * crop.side / size,
        crop.top + (y + .5) * crop.side / size,
      );
      if (_nailAlpha(nail, point) < 128) continue;
      old[y * size + x] = 1;
      oldArea++;
      oldX += x + .5;
      oldY += y + .5;
    }
  }
  if (oldArea < 3) return unchanged('empty_original');
  oldX /= oldArea;
  oldY /= oldArea;
  List<int>? selected;
  var bestOverlap = 0.0;
  for (final component in connectedComponents(
    p,
    size,
    size,
    threshold: threshold,
  )) {
    if (component.length > size * size * .65) continue;
    var overlap = 0, confidence = 0.0;
    for (final i in component) {
      overlap += old[i];
      confidence += p[i];
    }
    if (confidence / component.length < .57) continue;
    final iou = overlap / (oldArea + component.length - overlap);
    if (iou > bestOverlap) {
      selected = component;
      bestOverlap = iou;
    }
  }
  if (selected == null) return unchanged('no_overlapping_candidate');
  final areaRatio = selected.length / oldArea;
  var nx = 0.0, ny = 0.0;
  for (final i in selected) {
    nx += i % size + .5;
    ny += i ~/ size + .5;
  }
  nx /= selected.length;
  ny /= selected.length;
  final centerShift =
      Offset(nx - oldX, ny - oldY).distance / math.sqrt(oldArea);
  if (bestOverlap < .65 ||
      areaRatio < .7 ||
      areaRatio > 1.35 ||
      centerShift > .2) {
    return unchanged('geometry_guard', bestOverlap, areaRatio, centerShift);
  }

  // Isolate the original coarse component, so a neighboring finger never
  // contributes probability to the local nail's blend.
  List<int>? coarseComponent;
  var coarseOverlap = 0.0;
  for (final component in connectedComponents(
    request.coarse,
    size,
    size,
    threshold: threshold,
  )) {
    var overlap = 0.0;
    for (final i in component) {
      overlap +=
          _nailAlpha(
            nail,
            Offset(
              (i % size + .5) / size * request.width,
              (i ~/ size + .5) / size * request.height,
            ),
          ) /
          255;
    }
    if (overlap > coarseOverlap) {
      coarseOverlap = overlap;
      coarseComponent = component;
    }
  }
  if (coarseComponent == null) {
    return unchanged(
      'coarse_seed_missing',
      bestOverlap,
      areaRatio,
      centerShift,
    );
  }
  final coarse = Float64List(size * size);
  for (final i in coarseComponent) {
    coarse[i] = request.coarse[i];
  }
  final member = Uint8List(size * size);
  for (final i in selected) {
    member[i] = 1;
  }
  final distanceToMember = _distance(member, size, size, 1);
  final fine = Float64List(size * size);
  for (var i = 0; i < fine.length; i++) {
    if (member[i] == 1 || (p[i] < threshold && distanceToMember[i] <= 2)) {
      fine[i] = p[i];
    }
  }
  final radius = math.max(1, (math.sqrt(oldArea) * .05).round());
  final toInside = _distance(old, size, size, 1);
  final toOutside = _distance(old, size, size, 0);
  final core = Float64List(size * size), allowed = Float64List(size * size);
  for (var i = 0; i < old.length; i++) {
    core[i] = old[i] == 1 && toOutside[i] > radius ? 1 : 0;
    allowed[i] = old[i] == 1 || toInside[i] <= radius ? 1 : 0;
  }

  const mw = 128, mh = 192;
  final margin = (radius + 2) * crop.side / size;
  final expandedWidth = nail.width + margin * 2;
  final expandedHeight = nail.height + margin * 2;
  final ca = math.cos(nail.angle), sa = math.sin(nail.angle);
  double probabilityAt(double lx, double ly) {
    final px = nail.center.dx + ca * lx - sa * ly;
    final py = nail.center.dy + sa * lx + ca * ly;
    if (px < 0 || py < 0 || px >= request.width || py >= request.height) {
      return 0;
    }
    final cx = (px - crop.left) / crop.side * size - .5;
    final cy = (py - crop.top) / crop.side * size - .5;
    if (_sample(allowed, size, size, cx, cy) < .5) return 0;
    final fp = _sample(fine, size, size, cx, cy);
    final cp = _sample(
      coarse,
      size,
      size,
      px / request.width * size - .5,
      py / request.height * size - .5,
    );
    // Only a narrow boundary band uses the conservative local/coarse blend.
    final probability = fp * .65 + cp * .35;
    return _sample(core, size, size, cx, cy) >= .5
        ? math.max(.85, probability)
        : probability;
  }

  // Keep the previous material frame unless actual new coverage exceeds it.
  // A permanently enlarged empty frame would change built-in pattern UVs.
  var extentX = 0.0, extentY = 0.0;
  for (var y = 0; y < mh; y++) {
    for (var x = 0; x < mw; x++) {
      final lx = ((x + .5) / mw - .5) * expandedWidth;
      final ly = ((y + .5) / mh - .5) * expandedHeight;
      if (probabilityAt(lx, ly) < request.contourThreshold) continue;
      extentX = math.max(extentX, lx.abs());
      extentY = math.max(extentY, ly.abs());
    }
  }
  final width = math.max(nail.width, 2 * (extentX + expandedWidth / mw));
  final height = math.max(nail.height, 2 * (extentY + expandedHeight / mh));
  // Contour tolerances are in source-model pixel units, not in the final
  // upsampled mask. Otherwise .3 pixels would be only a fraction of a photo
  // pixel and would retain the low-resolution staircase almost unchanged.
  final sourcePixel = crop.side / size;
  final fieldWidth = math.max(16, (width / sourcePixel).ceil());
  final fieldHeight = math.max(16, (height / sourcePixel).ceil());
  final field = Float64List(fieldWidth * fieldHeight);
  for (var y = 0; y < fieldHeight; y++) {
    for (var x = 0; x < fieldWidth; x++) {
      field[y * fieldWidth + x] = probabilityAt(
        ((x + .5) / fieldWidth - .5) * width,
        ((y + .5) / fieldHeight - .5) * height,
      );
    }
  }
  final rgba = refineProbabilityContour(
    field,
    fieldWidth,
    fieldHeight,
    outputWidth: mw,
    outputHeight: mh,
    threshold: request.contourThreshold,
    simplifyTolerance: .3,
    maxSmoothing: .3,
    minContourArea: 2,
  );
  if (!rgba.any((v) => v > 0)) {
    return unchanged(
      'empty_refined_contour',
      bestOverlap,
      areaRatio,
      centerShift,
    );
  }
  return _RefinedCrop(
    nail.copyWith(
      width: width,
      height: height,
      maskWidth: mw,
      maskHeight: mh,
      maskRgba: rgba,
    ),
    PhotoRefinementReport(
      nailId: nail.id,
      accepted: true,
      reason: 'local_boundary_refined',
      fieldWidth: fieldWidth,
      fieldHeight: fieldHeight,
      overlap: bestOverlap,
      areaRatio: areaRatio,
      centerShift: centerShift,
      weakBoundary: _hasWeakBoundary(p, member, selected, size),
    ),
  );
}

bool _hasWeakBoundary(
  List<double> probabilities,
  Uint8List member,
  List<int> pixels,
  int size,
) {
  final distanceToOutside = _distance(member, size, size, 0);
  var innerEdgeSamples = 0, weakSamples = 0;
  for (final index in pixels) {
    // A single ambiguous outer pixel is normal. Sample the second pixel
    // inward in the crop model's coordinates to detect a broader transition.
    if (distanceToOutside[index] != 2) continue;
    innerEdgeSamples++;
    if (probabilities[index] < .65) weakSamples++;
  }
  return innerEdgeSamples >= 8 && weakSamples * 3 >= innerEdgeSamples;
}

double _nailAlpha(NailRegion nail, Offset point) {
  final local = nail.toLocal(point);
  return _sampleAlpha(
    nail.maskRgba,
    nail.maskWidth,
    nail.maskHeight,
    (local.dx / nail.width + .5) * nail.maskWidth - .5,
    (local.dy / nail.height + .5) * nail.maskHeight - .5,
  );
}

double _sampleAlpha(Uint8List rgba, int w, int h, double x, double y) {
  final ix = x.floor(), iy = y.floor(), fx = x - x.floor(), fy = y - y.floor();
  var sum = 0.0;
  for (var dy = 0; dy < 2; dy++) {
    for (var dx = 0; dx < 2; dx++) {
      final px = ix + dx, py = iy + dy;
      if (px < 0 || py < 0 || px >= w || py >= h) continue;
      sum +=
          rgba[(py * w + px) * 4 + 3] *
          (dx == 0 ? 1 - fx : fx) *
          (dy == 0 ? 1 - fy : fy);
    }
  }
  return sum;
}

double _sample(List<double> values, int w, int h, double x, double y) {
  final ix = x.floor(), iy = y.floor(), fx = x - x.floor(), fy = y - y.floor();
  var sum = 0.0;
  for (var dy = 0; dy < 2; dy++) {
    for (var dx = 0; dx < 2; dx++) {
      final px = ix + dx, py = iy + dy;
      if (px < 0 || py < 0 || px >= w || py >= h) continue;
      sum +=
          values[py * w + px] *
          (dx == 0 ? 1 - fx : fx) *
          (dy == 0 ? 1 - fy : fy);
    }
  }
  return sum;
}

Int32List _distance(Uint8List mask, int w, int h, int target) {
  final d = Int32List(mask.length);
  for (var i = 0; i < d.length; i++) {
    d[i] = mask[i] == target ? 0 : w + h;
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = y * w + x;
      if (x > 0) d[i] = math.min(d[i], d[i - 1] + 1);
      if (y > 0) {
        d[i] = math.min(d[i], d[i - w] + 1);
        if (x > 0) d[i] = math.min(d[i], d[i - w - 1] + 1);
        if (x + 1 < w) d[i] = math.min(d[i], d[i - w + 1] + 1);
      }
    }
  }
  for (var y = h - 1; y >= 0; y--) {
    for (var x = w - 1; x >= 0; x--) {
      final i = y * w + x;
      if (x + 1 < w) d[i] = math.min(d[i], d[i + 1] + 1);
      if (y + 1 < h) {
        d[i] = math.min(d[i], d[i + w] + 1);
        if (x > 0) d[i] = math.min(d[i], d[i + w - 1] + 1);
        if (x + 1 < w) d[i] = math.min(d[i], d[i + w + 1] + 1);
      }
    }
  }
  return d;
}
