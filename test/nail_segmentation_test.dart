import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/services/nail_segmentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runtimeChannel = MethodChannel('flutter_onnxruntime');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory directory;
  late _Runtime runtime;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('nail_engine_test_');
    // The fake platform session does not load model bytes. A cached file avoids
    // copying the real model merely to exercise the native resource lifecycle.
    await File('${directory.path}/nail_segmentation.onnx').writeAsBytes([1]);
    runtime = _Runtime();
    messenger.setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getTemporaryDirectory') return directory.path;
      throw MissingPluginException();
    });
    messenger.setMockMethodCallHandler(runtimeChannel, runtime.handle);
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(runtimeChannel, null);
    messenger.setMockMethodCallHandler(pathChannel, null);
    await directory.delete(recursive: true);
  });

  test(
    'one pending frame, shared warm-up, and close waits for native work',
    () async {
      runtime.loadingGate = Completer<void>();
      final engine = NailSegmentationEngine();
      final warmUp = engine.warmUp();
      await runtime.requested.future;
      final detection = engine.detect(_tensor(), width: 640, height: 480);
      await expectLater(
        engine.detect(_tensor(), width: 640, height: 480),
        throwsStateError,
      );
      var closed = false;
      final closing = engine.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(runtime.closedSessions, 0);
      runtime.loadingGate!.complete();
      await warmUp;
      expect(await detection, isEmpty);
      await closing;
      await engine.close();
      expect(runtime.createdSessions, 1);
      expect(runtime.inferences, 2);
      expect(runtime.handles, isEmpty);
      expect(runtime.closedSessions, 1);
      await expectLater(engine.warmUp(), throwsStateError);
      await expectLater(
        engine.detect(_tensor(), width: 640, height: 480),
        throwsStateError,
      );
    },
  );

  test('a failed warm-up can load again on the next frame', () async {
    runtime.failLoading = true;
    final engine = NailSegmentationEngine();
    await expectLater(engine.warmUp(), throwsA(isA<PlatformException>()));
    expect(await engine.detect(_tensor(), width: 640, height: 480), isEmpty);
    await engine.close();
    expect(runtime.createdSessions, 2);
    expect(runtime.closedSessions, 1);
    expect(runtime.handles, isEmpty);
  });

  test(
    'a failed frame releases its tensor and permits the next frame',
    () async {
      runtime.failInference = true;
      final engine = NailSegmentationEngine();
      await expectLater(
        engine.detect(_tensor(), width: 640, height: 480),
        throwsA(isA<PlatformException>()),
      );
      expect(runtime.handles, isEmpty);
      expect(await engine.detect(_tensor(), width: 640, height: 480), isEmpty);
      await engine.close();
      expect(runtime.createdSessions, 1);
      expect(runtime.inferences, 3);
      expect(runtime.handles, isEmpty);
      expect(runtime.closedSessions, 1);
    },
  );

  test(
    'photo localization preserves the camera baseline and raw probabilities',
    () async {
      runtime.probabilities = Float32List(128 * 128);
      for (var y = 48; y < 80; y++) {
        for (var x = 56; x < 72; x++) {
          runtime.probabilities![y * 128 + x] = .95;
        }
      }
      final engine = NailSegmentationEngine();
      final baseline = await engine.detect(_tensor(), width: 640, height: 640);
      final photo = await engine.detectPhoto(
        _tensor(),
        width: 640,
        height: 640,
      );
      expect(photo.nails, hasLength(baseline.length));
      expect(photo.nails, hasLength(1));
      expect(photo.nails.single.center, baseline.single.center);
      expect(photo.nails.single.angle, baseline.single.angle);
      expect(
        photo.nails.single.maskRgba,
        orderedEquals(baseline.single.maskRgba),
      );
      expect(photo.probabilities[64 * 128 + 64], closeTo(.95, .0001));
      expect(photo.probabilities.first, 0);
      await engine.close();
      expect(runtime.handles, isEmpty);
    },
  );

  test(
    'known-nail crop admits larger plate without relaxing whole-photo filtering',
    () async {
      runtime.probabilities = Float32List(128 * 128);
      for (var y = 32; y < 96; y++) {
        for (var x = 32; x < 96; x++) {
          runtime.probabilities![y * 128 + x] = .95;
        }
      }
      final engine = NailSegmentationEngine();
      expect(await engine.detect(_tensor(), width: 640, height: 640), isEmpty);
      final crop = await engine.predictPhotoCrop(_tensor());
      expect(crop.where((p) => p > .9), hasLength(64 * 64));
      expect(await engine.detect(_tensor(), width: 640, height: 640), isEmpty);
      await engine.close();
      expect(runtime.createdSessions, 1);
      expect(runtime.handles, isEmpty);
      await expectLater(engine.predictPhotoCrop(_tensor()), throwsStateError);
      await expectLater(
        engine.detectPhoto(_tensor(), width: 640, height: 640),
        throwsStateError,
      );
    },
  );

  test(
    'crop and full-frame inference share the same pending-work guard',
    () async {
      runtime.loadingGate = Completer<void>();
      final engine = NailSegmentationEngine();
      final crop = engine.predictPhotoCrop(_tensor());
      await runtime.requested.future;
      await expectLater(
        engine.detectPhoto(_tensor(), width: 640, height: 640),
        throwsStateError,
      );
      var closed = false;
      final closing = engine.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      runtime.loadingGate!.complete();
      expect(await crop, everyElement(0));
      await closing;
      expect(runtime.closedSessions, 1);
      expect(runtime.handles, isEmpty);
    },
  );
}

Float32List _tensor() => Float32List(3 * 128 * 128);

class _Runtime {
  final requested = Completer<void>();
  Completer<void>? loadingGate;
  bool failLoading = false;
  bool failInference = false;
  Float32List? probabilities;
  int createdSessions = 0;
  int closedSessions = 0;
  int inferences = 0;
  int sequence = 0;
  final handles = <String>{};

  Future<Object?> handle(MethodCall call) async {
    final arguments = Map<Object?, Object?>.from(call.arguments as Map);
    switch (call.method) {
      case 'createSession':
        createdSessions++;
        if (!requested.isCompleted) requested.complete();
        if (failLoading) {
          failLoading = false;
          throw PlatformException(code: 'ENV_NOT_INITIALIZED');
        }
        await loadingGate?.future;
        return {
          'sessionId': 'session',
          'inputNames': ['image'],
          'outputNames': ['probabilities'],
        };
      case 'createOrtValue':
        final id = 'input_${sequence++}';
        handles.add(id);
        return {
          'valueId': id,
          'dataType': 'float32',
          'shape': [1, 3, 128, 128],
        };
      case 'runInference':
        inferences++;
        if (failInference) {
          failInference = false;
          throw PlatformException(code: 'FRAME_INTERRUPTED');
        }
        final id = 'output_${sequence++}';
        handles.add(id);
        return {
          'probabilities': [
            id,
            'float32',
            [1, 1, 128, 128],
          ],
        };
      case 'getOrtValueData':
        return {'data': probabilities ?? Float32List(128 * 128)};
      case 'releaseOrtValue':
        expect(handles.remove(arguments['valueId']), isTrue);
        return null;
      case 'closeSession':
        expect(handles, isEmpty);
        closedSessions++;
        return null;
      default:
        throw MissingPluginException(call.method);
    }
  }
}
