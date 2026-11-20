import 'dart:async';
import 'dart:math' as math;

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/screens/camera_page.dart';
import 'package:offline_nail_demo/services/nail_segmentation.dart';

void main() {
  late CameraPlatform originalPlatform;
  late _Camera camera;
  late _PreviewEngine engine;

  setUp(() {
    originalPlatform = CameraPlatform.instance;
    camera = _Camera();
    CameraPlatform.instance = camera;
    engine = _PreviewEngine();
  });

  tearDown(() async {
    await camera.release();
    CameraPlatform.instance = originalPlatform;
  });

  testWidgets(
    'preview reports detected nails, empty frames, and expires old results',
    (tester) async {
      await _open(tester, engine, camera);
      expect(find.text('正在识别指甲…'), findsOneWidget);
      camera.frame(bright: true);
      await _until(tester, () => find.text('已识别到 2 个指甲').evaluate().isNotEmpty);
      expect(engine.lastTensor!.first, closeTo(1, .001));

      await _frameInterval(tester);
      camera.frame(bright: false);
      await _until(tester, () => find.text('尚未识别到指甲').evaluate().isNotEmpty);
      expect(engine.lastTensor!.first, closeTo(-1, .001));

      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.text('尚未识别到指甲'), findsNothing);
      expect(find.text('正在识别指甲…'), findsOneWidget);
      await _close(tester);
      expect(camera.events, contains('dispose'));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'busy frames are dropped and a result cannot repaint after leaving',
    (tester) async {
      await _open(tester, engine, camera);
      engine.gate = Completer<void>();
      camera.frame(bright: true);
      await _until(tester, () => engine.calls == 1);
      await _frameInterval(tester);
      camera.frame(bright: true);
      camera.frame(bright: false);
      await _tick(tester);
      expect(engine.calls, 1);
      expect(engine.maxConcurrent, 1);

      await _close(tester);
      expect(engine.closed, 1);
      engine.gate!.complete();
      await _tick(tester);
      expect(find.text('已识别到 2 个指甲'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(
        camera.events,
        containsAllInOrder(['stream.start', 'stream.stop', 'dispose']),
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'capture stops analysis, restarts after failure, and returns photo',
    (tester) async {
      String? returnedPath;
      await _open(
        tester,
        engine,
        camera,
        onReturn: (path) => returnedPath = path,
      );
      camera.failCapture = true;
      await tester.tap(find.byType(FilledButton));
      await _until(tester, () => camera.streamStarts == 2);
      expect(
        camera.events,
        containsAllInOrder([
          'stream.start',
          'stream.stop',
          'capture',
          'stream.start',
        ]),
      );
      expect(find.text('这次没有拍摄成功，请稳住手机后重试。'), findsWidgets);

      camera.frame(bright: true);
      await _until(tester, () => find.text('已识别到 2 个指甲').evaluate().isNotEmpty);
      camera.captureGate = Completer<XFile>();
      await tester.tap(find.byType(FilledButton));
      await _until(tester, () => camera.captureCalls == 2);
      expect(find.text('正在拍照…'), findsOneWidget);
      expect(camera.streamListening, isFalse);
      camera.captureGate!.complete(XFile('/test/nail-photo.jpg'));
      await _until(tester, () => returnedPath != null);
      await tester.pump(const Duration(milliseconds: 400));
      expect(returnedPath, '/test/nail-photo.jpg');
      expect(find.byType(CameraPage), findsNothing);
      expect(engine.closed, 1);
      expect(camera.events.where((event) => event == 'capture').length, 2);
      expect(tester.takeException(), isNull);
      await _disposeTree(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('pausing discards an in-flight result and reconnects on resume', (
    tester,
  ) async {
    await _open(tester, engine, camera);
    engine.gate = Completer<void>();
    camera.frame(bright: true);
    await _until(tester, () => engine.calls == 1);
    camera.disposeGate = Completer<void>();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await _tick(tester);
    expect(camera.streamListening, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _tick(tester);
    expect(
      camera.cameraSequence,
      1,
      reason: 'Reconnect must await native release',
    );
    camera.disposeGate!.complete();
    await _until(tester, () => camera.streamStarts == 2);
    engine.gate!.complete();
    await _tick(tester);
    expect(find.text('已识别到 2 个指甲'), findsNothing);
    expect(find.text('正在识别指甲…'), findsOneWidget);
    engine.gate = null;
    camera.frame(bright: true);
    await _until(tester, () => find.text('已识别到 2 个指甲').evaluate().isNotEmpty);
    await _close(tester);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'system back during capture cleanup does not pop the previous page',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('根页面')),
        ),
      );
      unawaited(
        navigator.currentState!.push<void>(
          PageRouteBuilder(
            pageBuilder: (_, animation, secondaryAnimation) =>
                const Scaffold(body: Text('相机入口')),
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
          ),
        ),
      );
      await tester.pump();
      unawaited(
        navigator.currentState!.push<String>(
          PageRouteBuilder(
            pageBuilder: (_, animation, secondaryAnimation) =>
                CameraPage(previewEngine: engine),
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
          ),
        ),
      );
      await _until(tester, () => camera.streamStarts == 1);
      engine.closeGate = Completer<void>();
      await tester.tap(find.byType(FilledButton));
      await _until(tester, () => engine.closed == 1);
      expect(find.text('正在拍照…'), findsOneWidget);

      // A system back action can pop the route while its asynchronous cleanup
      // is still waiting. Completion must not then pop the underlying page.
      navigator.currentState!.pop();
      await tester.pump();
      await _tick(tester);
      expect(find.text('相机入口'), findsOneWidget);
      engine.closeGate!.complete();
      await _tick(tester);
      expect(find.text('相机入口'), findsOneWidget);
      expect(find.text('根页面'), findsNothing);
      expect(find.byType(CameraPage), findsNothing);
      expect(engine.closed, 1);
      expect(tester.takeException(), isNull);
      await _disposeTree(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'tap focuses and meters the full preview crop and shows the tapped point',
    (tester) async {
      camera.previewSize = const Size(1280, 720);
      await _open(tester, engine, camera);
      final surface = find.byKey(const ValueKey('camera-focus-surface'));
      final box = tester.getRect(surface);
      final local = Offset(box.width * .2, box.height * .73);
      await tester.tapAt(box.topLeft + local);
      await _until(
        tester,
        () =>
            camera.exposurePoints.isNotEmpty &&
            find.text('对焦点已设置').evaluate().isNotEmpty,
      );
      final scale = math.max(box.width / 720, box.height / 1280);
      final expected = Offset(
        (local.dx + (720 * scale - box.width) / 2) / (720 * scale),
        (local.dy + (1280 * scale - box.height) / 2) / (1280 * scale),
      );
      final focus = camera.focusPoints.single;
      expect(focus.x, closeTo(expected.dx, 1e-6));
      expect(focus.y, closeTo(expected.dy, 1e-6));
      expect(camera.exposurePoints.single, focus);
      expect(
        camera.events,
        containsAllInOrder([
          'focus.auto',
          'focus.point',
          'exposure.auto',
          'exposure.point',
        ]),
      );
      expect(
        find.byKey(const ValueKey('camera-focus-indicator')),
        findsOneWidget,
      );
      expect(find.text('对焦点已设置'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(
        find.byKey(const ValueKey('camera-focus-indicator')),
        findsNothing,
      );
      await _close(tester);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets('iOS flat-pose query compensates a portrait preview tap', (
    tester,
  ) async {
    const channel = MethodChannel('offline_nail/app_info');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var queries = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getCameraDeviceOrientation');
      queries++;
      return 'flat';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    camera.previewSize = const Size(1280, 720);
    await _open(tester, engine, camera);
    final box = tester.getRect(
      find.byKey(const ValueKey('camera-focus-surface')),
    );
    final local = Offset(box.width * .2, box.height * .73);
    await tester.tapAt(box.topLeft + local);
    await _until(tester, () => camera.exposurePoints.isNotEmpty);
    final scale = math.max(box.width / 720, box.height / 1280);
    final u = (local.dx + (720 * scale - box.width) / 2) / (720 * scale);
    final v = (local.dy + (1280 * scale - box.height) / 2) / (1280 * scale);
    expect(camera.focusPoints.single.x, closeTo(v, 1e-6));
    expect(camera.focusPoints.single.y, closeTo(1 - u, 1e-6));
    expect(camera.exposurePoints.single, camera.focusPoints.single);
    expect(queries, 2, reason: 'Each native AF/AE point uses the current pose');
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('rapid taps keep only the latest queued focus point', (
    tester,
  ) async {
    await _open(tester, engine, camera);
    camera.focusGate = Completer<void>();
    final box = tester.getRect(
      find.byKey(const ValueKey('camera-focus-surface')),
    );
    await tester.tapAt(box.centerLeft + Offset(box.width * .2, 0));
    await _until(tester, () => camera.focusPoints.length == 1);
    await tester.tapAt(box.center);
    await tester.tapAt(box.centerRight - Offset(box.width * .1, 0));
    expect(camera.focusPoints.length, 1);
    camera.focusGate!.complete();
    await _until(
      tester,
      () =>
          camera.exposurePoints.isNotEmpty &&
          find.text('对焦点已设置').evaluate().isNotEmpty,
    );
    expect(camera.focusPoints.length, 2);
    expect(camera.focusPoints.last.x, greaterThan(camera.focusPoints.first.x));
    expect(camera.exposurePoints.single, camera.focusPoints.last);
    expect(find.text('对焦点已设置'), findsOneWidget);
    await _close(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets(
    'a fixed focus camera remains usable and explains the unsupported tap',
    (tester) async {
      camera.focusSupported = false;
      camera.exposureSupported = false;
      await _open(tester, engine, camera);
      await tester.tap(find.byKey(const ValueKey('camera-focus-surface')));
      await _until(
        tester,
        () => find.text('此镜头不支持点按对焦，请调整拍摄距离').evaluate().isNotEmpty,
      );
      expect(camera.focusPoints, isEmpty);
      expect(camera.exposurePoints, isEmpty);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await _close(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'capture cancels remaining metering and prevents new focus taps',
    (tester) async {
      String? returnedPath;
      await _open(tester, engine, camera, onReturn: (p) => returnedPath = p);
      camera.focusGate = Completer<void>();
      camera.captureGate = Completer<XFile>();
      final surface = find.byKey(const ValueKey('camera-focus-surface'));
      await tester.tap(surface);
      await _until(tester, () => camera.focusPoints.length == 1);
      await tester.tap(find.byType(FilledButton));
      await _until(tester, () => camera.captureCalls == 1);
      await tester.tap(surface);
      camera.focusGate!.complete();
      await _tick(tester);
      expect(camera.focusPoints.length, 1);
      expect(camera.exposurePoints, isEmpty);
      expect(
        find.byKey(const ValueKey('camera-focus-indicator')),
        findsNothing,
      );
      camera.captureGate!.complete(XFile('/test/focused-nail.jpg'));
      await _until(tester, () => returnedPath != null);
      expect(returnedPath, '/test/focused-nail.jpg');
      expect(tester.takeException(), isNull);
      await _disposeTree(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'old focus does not meter after a background release and reconnect',
    (tester) async {
      await _open(tester, engine, camera);
      camera.focusGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('camera-focus-surface')));
      await _until(tester, () => camera.focusPoints.length == 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _tick(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _until(tester, () => camera.streamStarts == 2);
      camera.focusGate!.complete();
      await _tick(tester);
      expect(camera.exposurePoints, isEmpty);
      expect(
        find.byKey(const ValueKey('camera-focus-indicator')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('camera-focus-surface')));
      await _until(tester, () => camera.exposurePoints.length == 1);
      expect(camera.focusPoints.length, 2);
      expect(camera.focusCameraIds, [1, 2]);
      expect(camera.exposureCameraIds, [2]);
      await _close(tester);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'an unresponsive old focus cannot block a new camera indefinitely',
    (tester) async {
      await _open(tester, engine, camera);
      final oldFocus = Completer<void>();
      camera.focusGate = oldFocus;
      await tester.tap(find.byKey(const ValueKey('camera-focus-surface')));
      await _until(tester, () => camera.focusPoints.length == 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _tick(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _until(tester, () => camera.streamStarts == 2);
      camera.focusGate = null;
      await tester.tap(find.byKey(const ValueKey('camera-focus-surface')));
      expect(camera.focusPoints.length, 1);
      await tester.pump(const Duration(seconds: 3));
      await _until(tester, () => camera.exposurePoints.length == 1);
      expect(camera.focusCameraIds, [1, 2]);
      expect(camera.exposureCameraIds, [2]);
      oldFocus.complete();
      await _close(tester);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}

Future<void> _open(
  WidgetTester tester,
  _PreviewEngine engine,
  _Camera camera, {
  ValueChanged<String?>? onReturn,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              final path = await Navigator.of(context).push<String>(
                PageRouteBuilder(
                  pageBuilder: (_, animation, secondaryAnimation) =>
                      CameraPage(previewEngine: engine),
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                ),
              );
              onReturn?.call(path);
            },
            child: const Text('打开相机'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开相机'));
  await _until(tester, () => camera.streamStarts == 1);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _close(WidgetTester tester) async {
  await tester.tap(find.byTooltip('返回'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await _tick(tester);
  await _disposeTree(tester);
}

Future<void> _disposeTree(WidgetTester tester) async {
  // Finish native release while this test's fake-async zone and camera platform
  // are still active; CameraPage intentionally serializes releases across pages.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await _tick(tester);
  await tester.pump();
}

Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100 && !condition(); attempt++) {
    await _tick(tester);
  }
  expect(
    condition(),
    isTrue,
    reason:
        'Camera operation did not complete: ${(CameraPlatform.instance as _Camera).events}',
  );
}

Future<void> _frameInterval(WidgetTester tester) async {
  // CameraPage throttles with a real Stopwatch. Advance wall time as well as
  // widget-test timers, without changing the production camera implementation.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 420)),
  );
  await tester.pump();
}

class _PreviewEngine extends NailSegmentationEngine {
  Completer<void>? gate;
  Completer<void>? closeGate;
  Future<void>? closing;
  int calls = 0;
  int concurrent = 0;
  int maxConcurrent = 0;
  int closed = 0;
  Float32List? lastTensor;

  @override
  Future<void> warmUp() async {}

  @override
  Future<List<NailRegion>> detect(
    Float32List tensor, {
    required int width,
    required int height,
    List<HandObservation> hands = const [],
  }) async {
    calls++;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    lastTensor = tensor;
    try {
      await gate?.future;
      return tensor.first > 0
          ? [
              NailRegion.manual(
                0,
                Offset(width * .48, height * .42),
                width.toDouble(),
              ),
              NailRegion.manual(
                1,
                Offset(width * .52, height * .62),
                width.toDouble(),
              ),
            ]
          : [];
    } finally {
      concurrent--;
    }
  }

  @override
  Future<void> close() => closing ??= _close();

  Future<void> _close() async {
    closed++;
    await closeGate?.future;
  }
}

class _Camera extends CameraPlatform {
  _Camera() {
    frames = StreamController<CameraImageData>.broadcast(
      sync: true,
      onListen: () {
        streamListening = true;
        streamStarts++;
        events.add('stream.start');
      },
      onCancel: () {
        streamListening = false;
        events.add('stream.stop');
      },
    );
  }

  late final StreamController<CameraImageData> frames;
  final errors = StreamController<CameraErrorEvent>.broadcast();
  final events = <String>[];
  int cameraSequence = 0;
  int streamStarts = 0;
  bool streamListening = false;
  bool failCapture = false;
  int captureCalls = 0;
  Completer<XFile>? captureGate;
  Completer<void>? disposeGate;
  Completer<void>? focusGate;
  bool focusSupported = true;
  bool exposureSupported = true;
  Size previewSize = const Size(4, 4);
  final focusPoints = <math.Point<double>>[];
  final exposurePoints = <math.Point<double>>[];
  final focusCameraIds = <int>[];
  final exposureCameraIds = <int>[];

  @override
  Future<List<CameraDescription>> availableCameras() async => [
    const CameraDescription(
      name: 'test-back',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
  ];

  @override
  Future<int> createCamera(
    CameraDescription description,
    ResolutionPreset? preset, {
    bool enableAudio = false,
  }) async => ++cameraSequence;

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          previewSize.width,
          previewSize.height,
          ExposureMode.auto,
          exposureSupported,
          FocusMode.auto,
          focusSupported,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Future<void> lockCaptureOrientation(
    int cameraId,
    DeviceOrientation orientation,
  ) async {}

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async {}

  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {
    events.add('focus.${mode.name}');
  }

  @override
  Future<void> setFocusPoint(int cameraId, math.Point<double>? point) async {
    events.add('focus.point');
    focusPoints.add(point!);
    focusCameraIds.add(cameraId);
    await focusGate?.future;
  }

  @override
  Future<void> setExposureMode(int cameraId, ExposureMode mode) async {
    events.add('exposure.${mode.name}');
  }

  @override
  Future<void> setExposurePoint(int cameraId, math.Point<double>? point) async {
    events.add('exposure.point');
    exposurePoints.add(point!);
    exposureCameraIds.add(cameraId);
  }

  @override
  bool supportsImageStreaming() => true;

  @override
  Stream<CameraImageData> onStreamedFrameAvailable(
    int cameraId, {
    CameraImageStreamOptions? options,
  }) => frames.stream;

  @override
  Widget buildPreview(int cameraId) => const ColoredBox(color: Colors.black);

  @override
  Future<void> dispose(int cameraId) async {
    events.add('dispose');
    await disposeGate?.future;
  }

  @override
  Future<XFile> takePicture(int cameraId) async {
    expect(
      streamListening,
      isFalse,
      reason: 'Still capture must not overlap frame streaming',
    );
    events.add('capture');
    captureCalls++;
    if (failCapture) {
      failCapture = false;
      throw PlatformException(
        code: 'capture_failed',
        message: 'test capture failure',
      );
    }
    return captureGate?.future ?? XFile('/test/nail-photo.jpg');
  }

  void frame({required bool bright}) {
    final bytes = Uint8List(4 * 4 * 4);
    for (var offset = 0; offset < bytes.length; offset += 4) {
      bytes[offset + 2] = bright ? 255 : 0;
      bytes[offset + 3] = 255;
    }
    frames.add(
      CameraImageData(
        format: const CameraImageFormat(
          ImageFormatGroup.bgra8888,
          raw: 1111970369,
        ),
        planes: [
          CameraImagePlane(bytes: bytes, bytesPerRow: 16, bytesPerPixel: 4),
        ],
        width: 4,
        height: 4,
      ),
    );
  }

  Future<void> release() async {
    errors.add(CameraErrorEvent(0, 'test cleanup'));
    await Future<void>.delayed(Duration.zero);
    await frames.close();
    await errors.close();
  }
}
