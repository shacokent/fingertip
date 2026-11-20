import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/camera_preview_geometry.dart';

NailRegion _nail(Offset center, {bool enabled = true}) => NailRegion(
  id: 1,
  label: 'test',
  center: center,
  width: 40,
  height: 70,
  angle: .4,
  maskRgba: Uint8List(0),
  enabled: enabled,
);

void main() {
  test('cover crops a wide stream equally and excludes unseen nails', () {
    final geometry = PreviewGeometry.cover(
      imageSize: const Size(1920, 1080),
      viewportSize: const Size(300, 600),
    );
    expect(geometry.scale, closeTo(600 / 1080, 1e-9));
    expect(geometry.toViewport(const Offset(960, 540)), const Offset(150, 300));
    expect(geometry.isVisible(_nail(const Offset(960, 540))), isTrue);
    expect(geometry.isVisible(_nail(const Offset(100, 540))), isFalse);
    expect(geometry.isVisible(_nail(const Offset(1800, 540))), isFalse);
  });

  test('cover crops a tall stream vertically in landscape', () {
    final geometry = PreviewGeometry.cover(
      imageSize: const Size(1080, 1920),
      viewportSize: const Size(600, 300),
    );
    expect(geometry.toViewport(const Offset(540, 960)), const Offset(300, 150));
    expect(geometry.isVisible(_nail(const Offset(540, 100))), isFalse);
    expect(geometry.isVisible(_nail(const Offset(540, 960))), isTrue);
  });

  test('metering tap reverses the centered cover crop before normalizing', () {
    final wide = PreviewGeometry.cover(
      imageSize: const Size(1920, 1080),
      viewportSize: const Size(300, 600),
    );
    final edge = wide.normalizedPoint(const Offset(0, 150));
    expect(edge.dx, closeTo(.359375, 1e-9));
    expect(edge.dy, .25);
    expect(wide.normalizedPoint(const Offset(150, 300)), const Offset(.5, .5));
    final tall = PreviewGeometry.cover(
      imageSize: const Size(1080, 1920),
      viewportSize: const Size(600, 300),
    );
    final top = tall.normalizedPoint(const Offset(150, 0));
    expect(top.dx, .25);
    expect(top.dy, closeTo(.359375, 1e-9));
    expect(
      () => tall.normalizedPoint(const Offset(double.nan, 1)),
      throwsArgumentError,
    );
  });

  test('iOS focus compensates physical pose while preview stays portrait', () {
    const tap = Offset(.2, .7);
    const orientations = [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeRight,
    ];
    const expected = [
      Offset(.2, .7),
      Offset(.7, .8),
      Offset(.8, .3),
      Offset(.3, .2),
    ];
    for (var i = 0; i < orientations.length; i++) {
      final point = cameraMeteringPoint(
        previewPoint: tap,
        platform: TargetPlatform.iOS,
        previewOrientation: DeviceOrientation.portraitUp,
        deviceOrientation: orientations[i],
        lensDirection: CameraLensDirection.back,
      );
      expect(point.dx, closeTo(expected[i].dx, 1e-9));
      expect(point.dy, closeTo(expected[i].dy, 1e-9));
      expect(
        cameraMeteringPoint(
          previewPoint: tap,
          platform: TargetPlatform.android,
          previewOrientation: DeviceOrientation.portraitUp,
          deviceOrientation: orientations[i],
          lensDirection: CameraLensDirection.back,
        ),
        tap,
        reason: 'CameraX already maps display coordinates to its sensor',
      );
    }
    final front = cameraMeteringPoint(
      previewPoint: tap,
      platform: TargetPlatform.iOS,
      previewOrientation: DeviceOrientation.portraitUp,
      deviceOrientation: DeviceOrientation.portraitUp,
      lensDirection: CameraLensDirection.front,
    );
    expect(front.dx, closeTo(.8, 1e-9));
    expect(front.dy, closeTo(.7, 1e-9));
    for (final pose in ['flat', 'unknown']) {
      final flat = cameraMeteringPoint(
        previewPoint: tap,
        platform: TargetPlatform.iOS,
        previewOrientation: DeviceOrientation.portraitUp,
        deviceOrientation: DeviceOrientation.portraitUp,
        lensDirection: CameraLensDirection.back,
        nativeDeviceOrientation: pose,
      );
      expect(flat.dx, closeTo(.7, 1e-9));
      expect(flat.dy, closeTo(.8, 1e-9));
    }
  });

  test('partially clipped nail remains counted if its center is visible', () {
    final geometry = PreviewGeometry.cover(
      imageSize: const Size(100, 200),
      viewportSize: const Size(100, 200),
    );
    expect(geometry.isVisible(_nail(const Offset(1, 1))), isTrue);
    expect(geometry.isVisible(_nail(const Offset(-1, 50))), isFalse);
    expect(
      geometry.isVisible(_nail(const Offset(50, 50), enabled: false)),
      isFalse,
    );
    expect(geometry.isVisible(_nail(const Offset(double.nan, 50))), isFalse);
  });

  test('zero or nonfinite preview dimensions are rejected', () {
    for (final imageSize in [Size.zero, const Size(double.infinity, 100)]) {
      expect(
        () => PreviewGeometry.cover(
          imageSize: imageSize,
          viewportSize: const Size(100, 200),
        ),
        throwsArgumentError,
      );
    }
  });

  test('Android sensor rotation matches four back and front orientations', () {
    const orientations = [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeRight,
    ];
    for (var i = 0; i < orientations.length; i++) {
      expect(
        cameraStreamQuarterTurns(
          platform: TargetPlatform.android,
          sensorOrientation: 90,
          deviceOrientation: orientations[i],
          lensDirection: CameraLensDirection.back,
        ),
        [1, 0, 3, 2][i],
      );
      expect(
        cameraStreamQuarterTurns(
          platform: TargetPlatform.android,
          sensorOrientation: 270,
          deviceOrientation: orientations[i],
          lensDirection: CameraLensDirection.front,
        ),
        [3, 0, 1, 2][i],
      );
    }
  });

  test('iOS shared video buffer is already upright and mirrored as needed', () {
    for (final orientation in DeviceOrientation.values) {
      expect(
        cameraStreamQuarterTurns(
          platform: TargetPlatform.iOS,
          sensorOrientation: 90,
          deviceOrientation: orientation,
          lensDirection: CameraLensDirection.front,
        ),
        0,
      );
    }
    expect(
      cameraStreamNeedsMirror(
        platform: TargetPlatform.iOS,
        lensDirection: CameraLensDirection.front,
      ),
      isFalse,
    );
    expect(
      cameraStreamNeedsMirror(
        platform: TargetPlatform.android,
        lensDirection: CameraLensDirection.front,
      ),
      isTrue,
    );
    expect(
      cameraStreamNeedsMirror(
        platform: TargetPlatform.android,
        lensDirection: CameraLensDirection.back,
      ),
      isFalse,
    );
  });
}
