import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/nail_models.dart';
import '../services/camera_frame.dart';
import '../services/camera_preview_geometry.dart';
import '../services/nail_segmentation.dart';
import '../widgets/live_nail_overlay.dart';

/// Returns the captured local file path; cancelling returns null.
class CameraPage extends StatefulWidget {
  const CameraPage({super.key, this.previewEngine});

  final NailSegmentationEngine? previewEngine;

  /// Await the rear-camera teardown before another module opens a camera.
  static Future<void> waitForCameraRelease() =>
      _CameraPageState._cameraRelease ?? Future<void>.value();

  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  static const _wine = Color(0xFF7A3F4E);
  static const _blush = Color(0xFFFAF3F0);

  CameraController? _controller;
  List<CameraDescription>? _cameras;
  final Map<CameraController, Future<void>> _controllerReleases = {};
  static Future<void>? _cameraRelease;
  static Object? _orientationOwner;
  final Object _orientationToken = Object();
  bool _initializing = true;
  bool _capturing = false;
  bool _foreground = true;
  bool _closing = false;
  String? _error;
  int _cameraGeneration = 0;
  int _captureGeneration = 0;
  late final NailSegmentationEngine _previewEngine;
  late final Future<void> _portraitReady;
  final _previewClock = Stopwatch()..start();
  Timer? _staleTimer;
  Timer? _focusTimer;
  Offset? _focusLocation;
  String? _focusFeedback;
  int _focusGeneration = 0;
  _TapFocusRequest? _pendingFocus;
  Future<void>? _focusOperation;
  List<NailRegion>? _previewNails;
  Size? _previewImageSize;
  bool _frameBusy = false;
  bool _previewUnavailable = false;
  int _frameEpoch = 0;
  int _lastFrameStart = -10000;
  int _frameFailures = 0;

  static const _frameIntervalMs = 400;
  static const _resultLifetime = Duration(milliseconds: 1800);
  static const _meteringTimeout = Duration(seconds: 2);
  static const _cameraControl = MethodChannel('offline_nail/app_info');

  @override
  void initState() {
    super.initState();
    _previewEngine = widget.previewEngine ?? NailSegmentationEngine();
    // Keep raw camera frames and the displayed camera viewport in one stable
    // orientation, including Android devices whose system rotation is locked.
    _orientationOwner = _orientationToken;
    _portraitReady = SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    unawaited(_warmUpPreview());
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_foreground) unawaited(_initializeCamera());
  }

  bool _isCurrent(int generation) {
    return mounted &&
        !_closing &&
        _foreground &&
        generation == _cameraGeneration;
  }

  Future<void> _disposeController(CameraController? controller) {
    if (controller == null) return _cameraRelease ?? Future.value();
    final existing = _controllerReleases[controller];
    if (existing != null) return existing;
    // Camera backends can own one native capture session globally. Always finish
    // a previous release before creating or releasing a newer controller.
    late final Future<void> release;
    release = (_cameraRelease ?? Future<void>.value())
        .then((_) => _releaseController(controller))
        .whenComplete(() {
          if (identical(_cameraRelease, release)) _cameraRelease = null;
        });
    _controllerReleases[controller] = release;
    _cameraRelease = release;
    return release;
  }

  Future<void> _releaseController(CameraController controller) async {
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // Releasing the native camera below remains necessary after stream errors.
    }
    try {
      await controller.dispose();
    } catch (_) {
      // An interrupted permission request or initialization may already have
      // released the native camera. A later initialization can retry safely.
    }
  }

  Future<void> _initializeCamera() async {
    if (!mounted || _closing || !_foreground) return;
    final generation = ++_cameraGeneration;
    final oldController = _controller;
    _controller = null;
    setState(() {
      _initializing = true;
      _error = null;
      _resetPreview();
      _resetFocus();
    });
    await _disposeController(oldController);
    if (!_isCurrent(generation)) return;

    CameraController? candidate;
    try {
      await _portraitReady;
      if (!_isCurrent(generation)) return;
      final cameras = _cameras ??= await availableCameras();
      if (!_isCurrent(generation)) return;
      if (cameras.isEmpty) {
        setState(() {
          _initializing = false;
          _error = '没有找到可用相机。请使用带相机的手机，或返回导入照片。';
        });
        return;
      }
      final backCameras = cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      final description = backCameras.isNotEmpty
          ? backCameras.first
          : cameras.first;
      candidate = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      _controller = candidate;
      await candidate.initialize();
      if (!_isCurrent(generation) || !identical(candidate, _controller)) {
        await _disposeController(candidate);
        return;
      }
      try {
        await candidate.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {
        // Preview still follows the portrait UI on backends without this API.
      }
      try {
        await candidate.setFlashMode(FlashMode.off);
      } catch (_) {
        // Not all devices expose a flash; photography remains available.
      }
      if (!_isCurrent(generation) || !identical(candidate, _controller)) {
        await _disposeController(candidate);
        return;
      }
      setState(() => _initializing = false);
      await _startPreviewStream(candidate, generation);
    } on CameraException catch (error) {
      if (!_isCurrent(generation)) {
        await _disposeController(candidate);
        return;
      }
      _controller = null;
      await _disposeController(candidate);
      if (!_isCurrent(generation)) return;
      setState(() {
        _initializing = false;
        _error = _describeError(error);
      });
    } catch (_) {
      if (!_isCurrent(generation)) {
        await _disposeController(candidate);
        return;
      }
      _controller = null;
      await _disposeController(candidate);
      if (!_isCurrent(generation)) return;
      setState(() {
        _initializing = false;
        _error = '相机暂时无法启动，请稍后重试，或返回导入照片。';
      });
    }
  }

  Future<void> _warmUpPreview() async {
    try {
      await _previewEngine.warmUp();
    } catch (_) {
      // A frame retries loading. Preview inference must never block photography.
    }
  }

  void _resetPreview() {
    _frameEpoch++;
    _staleTimer?.cancel();
    _previewNails = null;
    _previewImageSize = null;
    _previewUnavailable = false;
    _frameFailures = 0;
    _lastFrameStart = -10000;
  }

  void _resetFocus() {
    _focusGeneration++;
    _focusTimer?.cancel();
    _pendingFocus = null;
    _focusLocation = null;
    _focusFeedback = null;
  }

  bool _focusIsCurrent(_TapFocusRequest request) =>
      _isCurrent(request.cameraGeneration) &&
      request.generation == _focusGeneration &&
      identical(request.controller, _controller) &&
      request.controller.value.isInitialized &&
      !request.controller.value.isTakingPicture &&
      !_initializing &&
      !_capturing;

  void _focusAt(Offset position, Size viewport, CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (!_isCurrent(_cameraGeneration) ||
        _initializing ||
        _capturing ||
        !identical(controller, _controller) ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture ||
        previewSize == null) {
      return;
    }
    final orientation =
        controller.value.lockedCaptureOrientation ??
        controller.value.deviceOrientation;
    final portrait =
        orientation == DeviceOrientation.portraitUp ||
        orientation == DeviceOrientation.portraitDown;
    final geometry = PreviewGeometry.cover(
      imageSize: portrait ? previewSize.flipped : previewSize,
      viewportSize: viewport,
    );
    final request = _TapFocusRequest(
      controller: controller,
      cameraGeneration: _cameraGeneration,
      generation: ++_focusGeneration,
      point: geometry.normalizedPoint(position),
      previewOrientation: orientation,
    );
    _focusTimer?.cancel();
    setState(() {
      _focusLocation = Offset(
        (position.dx / viewport.width).clamp(0.0, 1.0),
        (position.dy / viewport.height).clamp(0.0, 1.0),
      );
      _focusFeedback = '正在设置对焦点…';
      _pendingFocus = request;
    });
    // CameraX metering actions are asynchronous. Serializing them prevents an
    // older tap from overwriting a later AF/AE point; rapid taps keep only the
    // latest pending point rather than queueing every intermediate tap.
    _focusOperation ??= _runFocusRequests().whenComplete(() {
      _focusOperation = null;
    });
  }

  Future<void> _runFocusRequests() async {
    while (_pendingFocus != null) {
      final request = _pendingFocus!;
      _pendingFocus = null;
      if (_focusIsCurrent(request)) await _applyFocus(request);
    }
  }

  Future<void> _applyFocus(_TapFocusRequest request) async {
    final controller = request.controller;
    Future<Offset?> meteringPoint() async {
      String? nativeOrientation;
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        try {
          nativeOrientation = await _cameraControl
              .invokeMethod<String>('getCameraDeviceOrientation')
              .timeout(_meteringTimeout);
        } catch (_) {
          // Older hosts/test backends can use the normal four-direction value.
        }
      }
      if (!_focusIsCurrent(request)) return null;
      return cameraMeteringPoint(
        previewPoint: request.point,
        platform: defaultTargetPlatform,
        previewOrientation: request.previewOrientation,
        deviceOrientation: controller.value.deviceOrientation,
        lensDirection: controller.description.lensDirection,
        nativeDeviceOrientation: nativeOrientation,
      );
    }

    final canFocus = controller.value.focusPointSupported;
    var focusSet = false;
    if (canFocus) {
      try {
        await controller.setFocusMode(FocusMode.auto).timeout(_meteringTimeout);
      } catch (_) {
        // Some backends expose a focus point but no selectable focus mode.
      }
      if (!_focusIsCurrent(request)) return;
      try {
        final point = await meteringPoint();
        if (point == null || !_focusIsCurrent(request)) return;
        await controller.setFocusPoint(point).timeout(_meteringTimeout);
        focusSet = true;
      } catch (_) {
        // Exposure may still be supported; a focus error must not block it.
      }
    }
    if (!_focusIsCurrent(request)) return;
    if (controller.value.exposurePointSupported) {
      try {
        await controller
            .setExposureMode(ExposureMode.auto)
            .timeout(_meteringTimeout);
      } catch (_) {
        // A point can still be accepted on a backend with fixed auto exposure.
      }
      if (!_focusIsCurrent(request)) return;
      try {
        final point = await meteringPoint();
        if (point == null || !_focusIsCurrent(request)) return;
        await controller.setExposurePoint(point).timeout(_meteringTimeout);
      } catch (_) {
        // A failed exposure point does not undo a valid focus point.
      }
    }
    if (!_focusIsCurrent(request)) return;
    setState(() {
      // Setting a point is not proof that an extremely close subject is sharp.
      // The API does not expose focus convergence on both platforms.
      _focusFeedback = focusSet
          ? '对焦点已设置'
          : canFocus
          ? '未能设置对焦点，请重试或稍拉开距离'
          : '此镜头不支持点按对焦，请调整拍摄距离';
    });
    _focusTimer = Timer(const Duration(milliseconds: 1800), () {
      if (!_focusIsCurrent(request)) return;
      setState(() {
        _focusLocation = null;
        _focusFeedback = null;
      });
    });
  }

  Future<void> _startPreviewStream(
    CameraController controller,
    int generation,
  ) async {
    if (!_isCurrent(generation) || !identical(controller, _controller)) return;
    try {
      if (!controller.supportsImageStreaming()) {
        throw StateError('Preview streaming is unavailable');
      }
      await controller.startImageStream(
        (image) => _onPreviewFrame(image, controller, generation),
      );
    } catch (_) {
      if (_isCurrent(generation) && identical(controller, _controller)) {
        setState(() {
          _resetPreview();
          _previewUnavailable = true;
        });
      }
    }
  }

  void _onPreviewFrame(
    CameraImage image,
    CameraController controller,
    int generation,
  ) {
    final now = _previewClock.elapsedMilliseconds;
    if (!_isCurrent(generation) ||
        !identical(controller, _controller) ||
        _capturing ||
        _frameBusy ||
        now - _lastFrameStart < _frameIntervalMs) {
      return;
    }
    _frameBusy = true;
    _lastFrameStart = now;
    final epoch = _frameEpoch;
    unawaited(_recognizePreview(image, controller, generation, epoch, now));
  }

  Future<void> _recognizePreview(
    CameraImage image,
    CameraController controller,
    int generation,
    int epoch,
    int startedAt,
  ) async {
    bool current() =>
        _isCurrent(generation) &&
        identical(controller, _controller) &&
        epoch == _frameEpoch &&
        !_capturing;
    try {
      final format = switch (image.format.group) {
        ImageFormatGroup.bgra8888 => CameraFrameFormat.bgra8888,
        ImageFormatGroup.yuv420 => CameraFrameFormat.yuv420,
        _ => throw const FormatException('Unsupported camera frame'),
      };
      final frame = CameraFrameData(
        width: image.width,
        height: image.height,
        format: format,
        clockwiseQuarterTurns: cameraStreamQuarterTurns(
          platform: defaultTargetPlatform,
          sensorOrientation: controller.description.sensorOrientation,
          deviceOrientation: DeviceOrientation.portraitUp,
          lensDirection: controller.description.lensDirection,
        ),
        mirror: cameraStreamNeedsMirror(
          platform: defaultTargetPlatform,
          lensDirection: controller.description.lensDirection,
        ),
        planes: [
          for (final plane in image.planes)
            CameraFramePlane(
              bytes: plane.bytes,
              rowStride: plane.bytesPerRow,
              pixelStride:
                  plane.bytesPerPixel ??
                  (format == CameraFrameFormat.bgra8888 ? 4 : 1),
            ),
        ],
      );
      final prepared = await compute(prepareCameraFrame, frame);
      if (!current()) return;
      final nails = await _previewEngine.detect(
        prepared.tensor,
        width: prepared.width,
        height: prepared.height,
      );
      if (!current()) return;
      final age = _previewClock.elapsedMilliseconds - startedAt;
      if (age >= _resultLifetime.inMilliseconds) {
        _recordPreviewFailure();
        return;
      }
      _staleTimer?.cancel();
      setState(() {
        _previewNails = nails;
        _previewImageSize = Size(
          prepared.width.toDouble(),
          prepared.height.toDouble(),
        );
        _previewUnavailable = false;
        _frameFailures = 0;
      });
      // Expire relative to capture time, not completion, so old detections do
      // not stay painted when inference stalls or the frame stream stops.
      _staleTimer = Timer(_resultLifetime - Duration(milliseconds: age), () {
        if (!current()) return;
        setState(() {
          _previewNails = null;
          _previewImageSize = null;
        });
      });
    } catch (_) {
      if (current()) _recordPreviewFailure();
    } finally {
      _frameBusy = false;
    }
  }

  void _recordPreviewFailure() {
    _frameFailures++;
    if (_frameFailures < 3) return;
    _staleTimer?.cancel();
    setState(() {
      _previewNails = null;
      _previewImageSize = null;
      _previewUnavailable = true;
    });
  }

  String _describeError(CameraException error) {
    switch (error.code) {
      case 'CameraAccessDenied':
      case 'CameraAccessDeniedWithoutPrompt':
        return '相机权限尚未开启。请在系统设置中允许使用相机，返回后会自动重新连接。';
      case 'CameraAccessRestricted':
        return '此设备限制了相机访问。请检查系统限制，或返回导入已有照片。';
      default:
        return '相机暂时不可用。请确认没有其他应用占用相机，再重新尝试。';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing || !mounted) return;
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      unawaited(_initializeCamera());
      return;
    }
    _foreground = false;
    _cameraGeneration++;
    _captureGeneration++;
    final oldController = _controller;
    _controller = null;
    setState(() {
      _initializing = false;
      _capturing = false;
      _resetPreview();
      _resetFocus();
    });
    unawaited(_disposeController(oldController));
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (_closing ||
        _capturing ||
        !_foreground ||
        controller == null ||
        !controller.value.isInitialized ||
        controller.value.isTakingPicture) {
      return;
    }
    final cameraGeneration = _cameraGeneration;
    final captureGeneration = ++_captureGeneration;
    setState(() {
      _capturing = true;
      _resetPreview();
      _resetFocus();
    });
    try {
      // Unbind image analysis before still capture on both camera backends.
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      if (!_isCurrent(cameraGeneration) ||
          !identical(controller, _controller)) {
        return;
      }
      final photo = await controller.takePicture();
      if (!mounted ||
          !_isCurrent(cameraGeneration) ||
          captureGeneration != _captureGeneration ||
          !identical(controller, _controller)) {
        return;
      }
      _closing = true;
      _releaseCamera();
      await _closePreviewEngine();
      if (mounted &&
          cameraGeneration == _cameraGeneration &&
          captureGeneration == _captureGeneration &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop<String>(photo.path);
      }
    } on CameraException {
      if (mounted && _isCurrent(cameraGeneration)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这次没有拍摄成功，请稳住手机后重试。')));
      }
    } catch (_) {
      if (mounted && _isCurrent(cameraGeneration)) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法保存照片，请重新拍摄。')));
      }
    } finally {
      if (mounted && !_closing && captureGeneration == _captureGeneration) {
        setState(() => _capturing = false);
        if (_isCurrent(cameraGeneration) &&
            identical(controller, _controller)) {
          await _startPreviewStream(controller, cameraGeneration);
        }
      }
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    _cameraGeneration++;
    _captureGeneration++;
    _staleTimer?.cancel();
    _resetFocus();
    _releaseCamera();
    unawaited(_closePreviewEngine());
    Navigator.of(context).pop<String>();
  }

  void _releaseCamera({bool rebuild = true}) {
    final controller = _controller;
    // Remove CameraPreview before a disposed controller notifies its builders
    // during the route's exit animation. Teardown still has a shared barrier.
    if (rebuild && mounted) {
      setState(() => _controller = null);
    } else {
      _controller = null;
    }
    unawaited(_disposeController(controller));
  }

  @override
  void dispose() {
    _closing = true;
    _cameraGeneration++;
    _captureGeneration++;
    _staleTimer?.cancel();
    _resetFocus();
    WidgetsBinding.instance.removeObserver(this);
    _previewClock.stop();
    _releaseCamera(rebuild: false);
    unawaited(_closePreviewEngine());
    // The rest of the app keeps the system's normal orientation behavior.
    if (identical(_orientationOwner, _orientationToken)) {
      _orientationOwner = null;
      unawaited(SystemChrome.setPreferredOrientations([]));
    }
    super.dispose();
  }

  Future<void> _closePreviewEngine() async {
    try {
      await _previewEngine.close();
    } catch (_) {
      // Closing a page must also work after a native inference failure.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready =
        !_closing &&
        !_initializing &&
        _foreground &&
        controller != null &&
        controller.value.isInitialized;

    return PopScope<String>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          _closing = true;
          _cameraGeneration++;
          _captureGeneration++;
          _staleTimer?.cancel();
          _resetFocus();
          _releaseCamera();
          unawaited(_closePreviewEngine());
        }
      },
      child: Scaffold(
        backgroundColor: _blush,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 20, 2),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _close,
                      tooltip: '返回',
                      icon: const Icon(Icons.arrow_back_rounded, color: _wine),
                    ),
                    const Expanded(
                      child: Text(
                        '拍照试戴',
                        style: TextStyle(
                          color: Color(0xFF34242B),
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 4, 24, 15),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '自然拍摄，预览会标记识别到的甲面',
                    style: TextStyle(color: Color(0xFF806B71), fontSize: 13),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: LayoutBuilder(
                      builder: (context, constraints) => GestureDetector(
                        key: const ValueKey('camera-focus-surface'),
                        behavior: HitTestBehavior.opaque,
                        onTapDown: ready && !_capturing
                            ? (details) => _focusAt(
                                details.localPosition,
                                constraints.biggest,
                                controller,
                              )
                            : null,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const ColoredBox(color: Color(0xFF332E31)),
                            if (ready) _buildPreview(controller),
                            if (ready || _capturing)
                              LiveNailOverlay(
                                nails: _capturing ? null : _previewNails,
                                imageSize: _previewImageSize,
                                unavailable: _previewUnavailable,
                                capturing: _capturing,
                              ),
                            if (ready && !_capturing && _focusLocation != null)
                              ..._buildFocusIndicator(constraints.biggest),
                            if (!ready && !_capturing) _buildUnavailable(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 7),
                child: Semantics(
                  button: true,
                  label: _capturing ? '正在拍照' : '拍照并识别指甲',
                  child: SizedBox.square(
                    dimension: 76,
                    child: FilledButton(
                      onPressed: ready && !_capturing ? _takePhoto : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: _wine,
                        disabledBackgroundColor: const Color(0xFFD6C5C8),
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      child: _capturing
                          ? const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.65),
                                  width: 1.5,
                                ),
                              ),
                              child: const Icon(
                                Icons.camera_alt_outlined,
                                size: 26,
                                color: Colors.white,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 14),
                child: Text(
                  '点按甲面对焦 · 太近时稍微拉开距离',
                  style: TextStyle(color: Color(0xFF947D84), fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFocusIndicator(Size viewport) {
    const side = 58.0;
    final position = _focusLocation!;
    final left = (position.dx * viewport.width - side / 2).clamp(
      0.0,
      (viewport.width - side).clamp(0.0, double.infinity),
    );
    final top = (position.dy * viewport.height - side / 2).clamp(
      0.0,
      (viewport.height - side).clamp(0.0, double.infinity),
    );
    return [
      Positioned(
        left: left,
        top: top,
        child: IgnorePointer(
          child: Container(
            key: const ValueKey('camera-focus-indicator'),
            width: side,
            height: side,
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFFFDB88), width: 1.8),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(
              Icons.add_rounded,
              color: Color(0xFFFFDB88),
              size: 18,
            ),
          ),
        ),
      ),
      if (_focusFeedback != null)
        Positioned(
          bottom: 68,
          left: 16,
          right: 16,
          child: IgnorePointer(
            child: Center(
              child: Semantics(
                liveRegion: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xAA232529),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    child: Text(
                      _focusFeedback!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFFFDB88),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
    ];
  }

  Widget _buildPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) return const SizedBox.shrink();
    final orientation =
        controller.value.lockedCaptureOrientation ??
        controller.value.deviceOrientation;
    final portrait =
        orientation == DeviceOrientation.portraitUp ||
        orientation == DeviceOrientation.portraitDown;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: portrait ? previewSize.height : previewSize.width,
          height: portrait ? previewSize.width : previewSize.height,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  Widget _buildUnavailable() {
    if (_initializing) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFFF2DDD8),
              ),
            ),
            SizedBox(height: 16),
            Text(
              '正在打开相机…',
              style: TextStyle(color: Color(0xFFF2DDD8), fontSize: 13),
            ),
          ],
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                color: Color(0xFFE5C8CC),
                size: 36,
              ),
              const SizedBox(height: 16),
              Text(
                _error ?? '相机已暂停，返回应用后会重新连接。',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFFF4E6E2),
                  fontSize: 13,
                  height: 1.7,
                ),
              ),
              const SizedBox(height: 20),
              if (_foreground)
                FilledButton.tonal(
                  onPressed: () => unawaited(_initializeCamera()),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFF2DDD8),
                    foregroundColor: _wine,
                  ),
                  child: const Text('重新尝试'),
                ),
              TextButton(
                onPressed: _close,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFE5C8CC),
                ),
                child: const Text('返回选择照片'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TapFocusRequest {
  const _TapFocusRequest({
    required this.controller,
    required this.cameraGeneration,
    required this.generation,
    required this.point,
    required this.previewOrientation,
  });

  final CameraController controller;
  final int cameraGeneration;
  final int generation;
  final Offset point;
  final DeviceOrientation previewOrientation;
}
