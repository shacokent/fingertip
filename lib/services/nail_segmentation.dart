import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../models/nail_models.dart';
import 'rotation_ensemble.dart';
import 'segmentation_geometry.dart';

typedef PhotoNailPrediction = ({
  List<NailRegion> nails,
  List<double> probabilities,
  Set<int> singleViewIds,
});

/// Shared photo/preview inference. Input is orientation-corrected RGB NCHW,
/// 128x128, normalized to [-1, 1]; regions use [width]/[height] image pixels.
/// Camera frames never need to be encoded or written to disk here.
class NailSegmentationEngine {
  OrtSession? _session;
  Future<OrtSession>? _loading;
  Future<Object?>? _active;
  Future<void>? _shutdown;
  bool _closed = false;

  /// Loads the bundled model without running inference. Safe to call while a
  /// frame is starting; both operations await the same loading task.
  Future<void> warmUp() async {
    if (_closed) throw StateError('识别引擎已关闭。');
    await _getSession();
  }

  Future<OrtSession> _getSession() {
    if (_session != null) return Future.value(_session!);
    return _loading ??= _loadSession();
  }

  Future<OrtSession> _loadSession() async {
    try {
      final session = await OnnxRuntime().createSessionFromAsset(
        'assets/models/nail_segmentation.onnx',
        options: OrtSessionOptions(intraOpNumThreads: 2, interOpNumThreads: 1),
      );
      _session = session;
      return session;
    } catch (_) {
      _loading = null;
      rethrow;
    }
  }

  /// Rejects concurrent frames rather than queueing stale camera images. The
  /// camera caller can drop frames while the current one is being processed.
  Future<List<NailRegion>> detect(
    Float32List tensor, {
    required int width,
    required int height,
    List<HandObservation> hands = const [],
  }) => _exclusive(
    tensor,
    () => _detect(tensor, width: width, height: height, hands: hands),
    validDimensions: width > 0 && height > 0,
  );

  /// Photo-only coarse localization retains the original probability field for
  /// bounded local refinement. The camera's lightweight [detect] stays intact.
  Future<PhotoNailPrediction> detectPhoto(
    Float32List tensor, {
    required int width,
    required int height,
    List<HandObservation> hands = const [],
  }) => _exclusive(tensor, () async {
    late List<List<double>> views;
    final probabilities = await _predict(
      tensor,
      onViews: (value) => views = value,
    );
    final nails = extractNails(
      probabilities,
      128,
      128,
      width,
      height,
      hands: hands,
    );
    final frame = Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
    return (
      nails: nails,
      probabilities: probabilities,
      singleViewIds: {
        for (final nail in nails)
          if (views.any((view) => nailViewSupport(nail, view, frame) < .24))
            nail.id,
      },
    );
  }, validDimensions: width > 0 && height > 0);

  /// A known-nail crop has a much larger nail/image area ratio than a whole
  /// photograph. Its predictions may only refine an existing candidate; they
  /// are never used to add new detections to the camera or photo.
  Future<List<double>> predictPhotoCrop(Float32List tensor) =>
      _exclusive(tensor, () => _predict(tensor, maxFraction: .65));

  /// One photo-only view, aligned back to its crop for independent evidence.
  Future<List<double>> predictPhotoView(Float32List tensor, int turns) =>
      _exclusive(tensor, () async {
        final session = await _getSession();
        return restoreMaskOrientation(
          await _infer(
            session,
            turns == 0 ? tensor : rotateNchw(tensor, turns),
          ),
          turns,
        );
      });

  Future<T> _exclusive<T>(
    Float32List tensor,
    Future<T> Function() operation, {
    bool validDimensions = true,
  }) {
    if (_closed) return Future.error(StateError('识别引擎已关闭。'));
    if (_active != null) return Future.error(StateError('已有画面正在识别。'));
    if (tensor.length != 3 * 128 * 128 || !validDimensions) {
      return Future.error(ArgumentError('指甲模型输入尺寸不符。'));
    }
    late final Future<T> task;
    task = operation().whenComplete(() {
      if (identical(_active, task)) _active = null;
    });
    _active = task;
    return task;
  }

  Future<List<NailRegion>> _detect(
    Float32List tensor, {
    required int width,
    required int height,
    required List<HandObservation> hands,
  }) async {
    final probabilities = await _predict(tensor);
    return extractNails(probabilities, 128, 128, width, height, hands: hands);
  }

  Future<List<double>> _predict(
    Float32List tensor, {
    double maxFraction = .08,
    void Function(List<List<double>>)? onViews,
  }) async {
    final session = await _getSession();
    final views = <List<double>>[];
    // Preview and photo localization keep their original filtering. A known
    // nail crop explicitly supplies its own area cap instead of inheriting 8%.
    for (final turns in const [0, 2]) {
      final input = turns == 0 ? tensor : rotateNchw(tensor, turns);
      final rawMask = await _infer(session, input);
      views.add(restoreMaskOrientation(rawMask, turns));
    }
    onViews?.call(views);
    final probabilities = mergeValidatedProbabilities(
      views,
      128,
      128,
      maxFraction: maxFraction,
    );
    return filterNailProbabilities(
      probabilities,
      128,
      128,
      maxFraction: maxFraction,
    );
  }

  Future<List<double>> _infer(OrtSession session, Float32List tensor) async {
    final input = await OrtValue.fromList(tensor, [1, 3, 128, 128]);
    Map<String, OrtValue>? outputs;
    try {
      outputs = await session.run({session.inputNames.single: input});
      final values = await outputs[session.outputNames.first]!
          .asFlattenedList();
      if (values.length != 128 * 128) throw StateError('指甲模型输出尺寸不符。');
      return values.map((value) => (value as num).toDouble()).toList();
    } finally {
      // Attempt every release even if one platform cleanup call fails.
      await Future.wait<void>([
        input.dispose(),
        if (outputs != null)
          for (final value in outputs.values) value.dispose(),
      ]);
    }
  }

  /// Marks the engine closed immediately, then releases the session after any
  /// in-flight frame or model warm-up has finished. Repeated calls are safe.
  Future<void> close() {
    _closed = true;
    return _shutdown ??= _closeWhenIdle();
  }

  Future<void> _closeWhenIdle() async {
    try {
      await _active;
    } catch (_) {
      // A failed frame must not prevent model cleanup.
    }
    try {
      await _loading;
    } catch (_) {
      // Failed model loading is also safe to close.
    }
    final session = _session;
    _session = null;
    _loading = null;
    await session?.close();
  }
}
