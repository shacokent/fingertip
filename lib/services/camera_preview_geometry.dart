import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

import '../models/nail_models.dart';

/// Clockwise rotation from camera stream pixels to the upright preview.
///
/// iOS rotates its pixel buffer before sharing it with both the texture and
/// image stream. Android sends sensor-oriented planes. For Android, supply the
/// orientation used by the preview/display, not an unrelated physical pose
/// while the screen orientation is locked.
int cameraStreamQuarterTurns({
  required TargetPlatform platform,
  required int sensorOrientation,
  required DeviceOrientation deviceOrientation,
  required CameraLensDirection lensDirection,
}) {
  if (platform != TargetPlatform.android) return 0;
  if (sensorOrientation % 90 != 0) {
    throw ArgumentError.value(sensorOrientation, 'sensorOrientation');
  }
  final compensation = switch (deviceOrientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  final degrees = lensDirection == CameraLensDirection.front
      ? sensorOrientation + compensation
      : sensorOrientation - compensation;
  return (degrees % 360) ~/ 90;
}

/// iOS mirrors its shared video buffer; Android mirrors only the preview.
bool cameraStreamNeedsMirror({
  required TargetPlatform platform,
  required CameraLensDirection lensDirection,
}) =>
    platform == TargetPlatform.android &&
    lensDirection == CameraLensDirection.front;

/// Matches a centered FittedBox using BoxFit.cover without stretching pixels.
class PreviewGeometry {
  PreviewGeometry.cover({required this.imageSize, required this.viewportSize}) {
    if (!_validSize(imageSize) || !_validSize(viewportSize)) {
      throw ArgumentError('Preview dimensions must be finite and positive.');
    }
    scale = math.max(
      viewportSize.width / imageSize.width,
      viewportSize.height / imageSize.height,
    );
    offset = Offset(
      (viewportSize.width - imageSize.width * scale) / 2,
      (viewportSize.height - imageSize.height * scale) / 2,
    );
  }

  final Size imageSize;
  final Size viewportSize;
  late final double scale;
  late final Offset offset;

  static bool _validSize(Size size) =>
      size.width.isFinite &&
      size.height.isFinite &&
      size.width > 0 &&
      size.height > 0;

  Offset toViewport(Offset sourcePoint) => sourcePoint * scale + offset;

  /// Point on the full, upright preview before the centered cover crop.
  /// Camera metering APIs use that full surface, not the visible cropped box.
  Offset normalizedPoint(Offset viewportPoint) {
    if (!viewportPoint.dx.isFinite || !viewportPoint.dy.isFinite) {
      throw ArgumentError('Preview point must be finite.');
    }
    final sourcePoint = (viewportPoint - offset) / scale;
    return Offset(
      (sourcePoint.dx / imageSize.width).clamp(0.0, 1.0),
      (sourcePoint.dy / imageSize.height).clamp(0.0, 1.0),
    );
  }

  /// Count only detections whose centers can actually be seen in the preview.
  /// Border detections stay eligible, rather than requiring the entire nail to
  /// fit and losing useful feedback when the user adjusts framing.
  bool isVisible(NailRegion region) {
    if (!region.enabled) return false;
    final center = toViewport(region.center);
    return center.dx.isFinite &&
        center.dy.isFinite &&
        center.dx >= 0 &&
        center.dy >= 0 &&
        center.dx <= viewportSize.width &&
        center.dy <= viewportSize.height;
  }
}

/// The CameraX backend maps points in display coordinates itself. The pinned
/// AVFoundation backend instead maps them using the physical device pose, even
/// when capture/preview is locked. Compensate that difference before passing a
/// point to iOS, keeping a tap on the visible nail on that nail's sensor area.
Offset cameraMeteringPoint({
  required Offset previewPoint,
  required TargetPlatform platform,
  required DeviceOrientation previewOrientation,
  required DeviceOrientation deviceOrientation,
  required CameraLensDirection lensDirection,
  String? nativeDeviceOrientation,
}) {
  if (platform != TargetPlatform.iOS) return previewPoint;
  // AVFoundation's point conversion deliberately does nothing for flat or
  // unknown UIDevice poses. Dart's orientation stream retains its last valid
  // pose in that case, so the small native query takes precedence when present.
  final meteringOrientation = switch (nativeDeviceOrientation) {
    'portraitUp' => DeviceOrientation.portraitUp,
    'portraitDown' => DeviceOrientation.portraitDown,
    'landscapeLeft' || 'flat' || 'unknown' => DeviceOrientation.landscapeLeft,
    'landscapeRight' => DeviceOrientation.landscapeRight,
    _ => deviceOrientation,
  };
  final displayed = lensDirection == CameraLensDirection.front
      ? Offset(1 - previewPoint.dx, previewPoint.dy)
      : previewPoint;
  Offset toSensor(Offset point, DeviceOrientation orientation) =>
      switch (orientation) {
        DeviceOrientation.portraitUp => Offset(point.dy, 1 - point.dx),
        DeviceOrientation.portraitDown => Offset(1 - point.dy, point.dx),
        DeviceOrientation.landscapeRight => Offset(1 - point.dx, 1 - point.dy),
        DeviceOrientation.landscapeLeft => point,
      };
  final sensor = toSensor(displayed, previewOrientation);
  return switch (meteringOrientation) {
    DeviceOrientation.portraitUp => Offset(1 - sensor.dy, sensor.dx),
    DeviceOrientation.portraitDown => Offset(sensor.dy, 1 - sensor.dx),
    DeviceOrientation.landscapeRight => Offset(1 - sensor.dx, 1 - sensor.dy),
    DeviceOrientation.landscapeLeft => sensor,
  };
}
