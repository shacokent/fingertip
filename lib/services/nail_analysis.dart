import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import '../models/nail_models.dart';
import 'nail_candidate_recovery.dart';
import 'nail_dark_recovery.dart';
import 'nail_segmentation.dart';
import 'nail_photo_candidates.dart';
import 'nail_photo_edge_snap.dart';
import 'nail_photo_micro_recovery.dart';
import 'nail_photo_natural_edges.dart';
import 'nail_photo_refinement.dart';
import 'nail_polish_recovery.dart';
import 'probability_contour.dart';

class PreparedPhoto {
  const PreparedPhoto(this.bytes, this.width, this.height, this.tensor);
  final Uint8List bytes;
  final int width, height;
  final Float32List tensor;
}

PreparedPhoto preparePhoto(Uint8List raw) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) {
    throw const FormatException('无法读取这张图片，请选择 JPEG、PNG 或重新拍摄。');
  }
  var image = img.bakeOrientation(decoded);
  if (image.width > 1600 || image.height > 1600) {
    image = image.width >= image.height
        ? img.copyResize(
            image,
            width: 1600,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: 1600,
            interpolation: img.Interpolation.average,
          );
  }
  final input = img.copyResize(
    image,
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
  return PreparedPhoto(
    Uint8List.fromList(img.encodePng(image)),
    image.width,
    image.height,
    tensor,
  );
}

class NailAnalysisEngine {
  static const _handChannel = MethodChannel('offline_nail/hand_landmarker');
  final _segmentation = NailSegmentationEngine();
  Future<AnalysisResult>? _active;
  Future<void>? _shutdown;
  bool _closed = false;

  Future<AnalysisResult> analyze(
    Uint8List raw, {
    void Function(String)? onStage,
  }) {
    if (_closed) return Future.error(StateError('识别引擎已关闭。'));
    if (_active != null) return Future.error(StateError('已有照片正在识别。'));
    final task = _analyze(raw, onStage: onStage);
    _active = task;
    return task.whenComplete(() => _active = null);
  }

  Future<AnalysisResult> _analyze(
    Uint8List raw, {
    void Function(String)? onStage,
  }) async {
    final clock = Stopwatch()..start();
    onStage?.call('整理照片与方向');
    final photo = await compute(preparePhoto, raw);
    final directory = await getTemporaryDirectory();
    final path =
        '${directory.path}/nail_${DateTime.now().microsecondsSinceEpoch}.png';
    await File(path).writeAsBytes(photo.bytes, flush: true);
    var hands = <HandObservation>[];
    onStage?.call('定位手部与指尖');
    try {
      final result = await _handChannel.invokeMapMethod<String, dynamic>(
        'detectImage',
        {'path': path},
      );
      for (final value in (result?['hands'] as List? ?? [])) {
        final h = Map<Object?, Object?>.from(value as Map);
        final landmarks = (h['landmarks'] as List).cast<Map>();
        hands.add(
          HandObservation(
            [
              for (final p in landmarks)
                Offset((p['x'] as num).toDouble(), (p['y'] as num).toDouble()),
            ],
            h['handedness'] as String? ?? '',
            pointConfidences: landmarks.every((p) => p['confidence'] is num)
                ? [
                    for (final p in landmarks)
                      (p['confidence'] as num).toDouble(),
                  ]
                : null,
          ),
        );
      }
    } on PlatformException {
      // Finger names are optional. Missing hand landmarks must never reject
      // a nail or ask the user to hold a prescribed pose.
    } on MissingPluginException {
      // Segmentation remains available without the optional hand locator.
    }
    onStage?.call('正在识别甲面');
    final prediction = await _segmentation.detectPhoto(
      photo.tensor,
      width: photo.width,
      height: photo.height,
      hands: hands,
    );
    var nails = prediction.nails;
    final refinements = <PhotoRefinementReport>[];
    if (nails.isNotEmpty) {
      onStage?.call('精细识别每片甲缘');
      try {
        nails = await refinePhotoNails(
          pngBytes: photo.bytes,
          imageWidth: photo.width,
          imageHeight: photo.height,
          nails: nails,
          coarseProbabilities: prediction.probabilities,
          engine: _segmentation,
          onStage: onStage,
          onRefinement: refinements.add,
          verifyCandidateIds: prediction.singleViewIds,
        );
      } catch (_) {
        // A refinement failure must not discard the accepted localization.
      }
    }
    final initialIds = {for (final nail in prediction.nails) nail.id};
    final firstUnusedId = initialIds.fold<int>(
      0,
      (next, id) => next > id ? next : id + 1,
    );
    try {
      nails = await recoverNailsFromPhotoViews(
        pngBytes: photo.bytes,
        imageWidth: photo.width,
        imageHeight: photo.height,
        nails: nails,
        hands: hands,
        predictView: _segmentation.predictPhotoView,
        onStage: onStage,
      );
    } catch (_) {
      // A failed optional view cannot erase already localized nail masks.
    }
    try {
      nails = await recoverPhotoNails(
        pngBytes: photo.bytes,
        imageWidth: photo.width,
        imageHeight: photo.height,
        nails: nails,
        hands: hands,
        predictCrop: _segmentation.predictPhotoCrop,
        onStage: onStage,
      );
    } catch (_) {
      // Finger landmarks are only a source of crop proposals.
    }
    onStage?.call('整理甲面区域');
    nails = await suppressUnsupportedPhotoNails(
      pngBytes: photo.bytes,
      nails: nails,
      initialIds: initialIds,
      singleViewIds: prediction.singleViewIds,
      reports: refinements,
    );
    try {
      nails = await recoverConsistentPolishNails(
        pngBytes: photo.bytes,
        imageWidth: photo.width,
        imageHeight: photo.height,
        nails: nails,
        trustedIds: initialIds.difference(prediction.singleViewIds),
        predictView: _segmentation.predictPhotoView,
        firstUnusedId: firstUnusedId,
        onStage: onStage,
      );
    } catch (_) {
      // Color-based proposals must never replace model-supported results.
    }
    try {
      nails = await recoverMicroPhotoNails(
        pngBytes: photo.bytes,
        imageWidth: photo.width,
        imageHeight: photo.height,
        nails: nails,
        hands: hands,
        predictView: _segmentation.predictPhotoView,
        firstUnusedId: firstUnusedId,
        onStage: onStage,
      );
    } catch (_) {
      // Keep accepted masks if a close-up crop cannot be checked.
    }
    try {
      nails = await recoverDarkNails(
        pngBytes: photo.bytes,
        imageWidth: photo.width,
        imageHeight: photo.height,
        nails: nails,
        predictView: _segmentation.predictPhotoView,
        firstUnusedId: firstUnusedId,
        onStage: onStage,
      );
    } catch (_) {
      // A missing supplemental dark view leaves the other results available.
    }
    onStage?.call('整理甲面区域');
    nails = await compute(_finishPhotoMasks, nails);
    try {
      nails = await snapPhotoNailEdges(pngBytes: photo.bytes, nails: nails);
    } catch (_) {
      // Preserve the smoothed model masks if photo-based edge matching fails.
    }
    try {
      nails = await snapNaturalPhotoNailEdges(
        pngBytes: photo.bytes,
        nails: nails,
        predictView: _segmentation.predictPhotoView,
        firstUnusedId: firstUnusedId,
        onStage: onStage,
      );
    } catch (_) {
      // Preserve the existing contour if the adjacent plates cannot be checked.
    }
    final reviews = photoNailEdgeReviews(
      nails: nails,
      imageWidth: photo.width,
      imageHeight: photo.height,
      reports: refinements,
    );
    clock.stop();
    return AnalysisResult(
      imagePath: path,
      pngBytes: photo.bytes,
      width: photo.width,
      height: photo.height,
      nails: nails,
      elapsed: clock.elapsed,
      handAvailable: hands.isNotEmpty,
      edgeReviewById: Map.unmodifiable({
        ...reviews,
        for (final nail in nails)
          if (!initialIds.contains(nail.id) && !reviews.containsKey(nail.id))
            nail.id: NailEdgeReviewReason.localRecovery,
      }),
    );
  }

  Future<void> close() {
    _closed = true;
    return _shutdown ??= _closeWhenIdle();
  }

  Future<void> _closeWhenIdle() async {
    try {
      await _active;
    } catch (_) {
      /* Release after failed inference too. */
    }
    await _segmentation.close();
  }
}

List<NailRegion> _finishPhotoMasks(List<NailRegion> nails) =>
    nails.map(finishDetectedNailContour).toList()
      ..sort((a, b) => a.center.dx.compareTo(b.center.dx));
