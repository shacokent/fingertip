import 'dart:math' as math;
import 'dart:typed_data';

/// A camera-independent, isolate-sendable description of the sampled frame.
enum CameraFrameFormat { yuv420, bgra8888 }

class CameraFramePlane {
  const CameraFramePlane({
    required this.bytes,
    required this.rowStride,
    this.pixelStride = 1,
  });

  final Uint8List bytes;
  final int rowStride;
  final int pixelStride;
}

class CameraFrameData {
  const CameraFrameData({
    required this.width,
    required this.height,
    required this.format,
    required this.planes,
    this.clockwiseQuarterTurns = 0,
    this.mirror = false,
    this.yuvFullRange = false,
  });

  final int width;
  final int height;
  final CameraFrameFormat format;
  final List<CameraFramePlane> planes;

  /// Rotation of the buffer into the orientation displayed by the preview.
  final int clockwiseQuarterTurns;

  /// Applied horizontally after rotation, when displaying a mirrored camera.
  final bool mirror;

  /// Android camera YUV is normally video range. This remains explicit for
  /// adapters whose frame producer supplies full-range BT.601 YUV instead.
  final bool yuvFullRange;
}

class PreparedCameraFrame {
  const PreparedCameraFrame({
    required this.tensor,
    required this.width,
    required this.height,
  });

  final Float32List tensor;

  /// Upright source dimensions. Segmentation coordinates use this same space.
  final int width;
  final int height;
}

/// Produces 128x128 RGB NCHW [-1, 1] without encoding or saving an image.
///
/// Downsampling uses a uniform area grid, capped at 4x4 samples per model pixel.
/// This approximates the still-photo area resize while bounding preview work at
/// 262,144 pixel reads even when the camera supplies a large frame. Processing
/// must run in an isolate; no camera/plugin objects are included in the input.
PreparedCameraFrame prepareCameraFrame(CameraFrameData frame) {
  _validate(frame);
  const edge = 128;
  const channelSize = edge * edge;
  final turns = frame.clockwiseQuarterTurns;
  final uprightWidth = turns.isOdd ? frame.height : frame.width;
  final uprightHeight = turns.isOdd ? frame.width : frame.height;
  final samplesX = (uprightWidth / edge).ceil().clamp(1, 4);
  final samplesY = (uprightHeight / edge).ceil().clamp(1, 4);
  final divisor = samplesX * samplesY * 127.5;
  final tensor = Float32List(3 * channelSize);
  final xSamples = List<int>.generate(edge * samplesX, (index) {
    final column = index ~/ samplesX;
    final subpixel = index % samplesX;
    return math.min(
      uprightWidth - 1,
      ((column + (subpixel + .5) / samplesX) * uprightWidth / edge).floor(),
    );
  });
  final ySamples = List<int>.generate(edge * samplesY, (index) {
    final row = index ~/ samplesY;
    final subpixel = index % samplesY;
    return math.min(
      uprightHeight - 1,
      ((row + (subpixel + .5) / samplesY) * uprightHeight / edge).floor(),
    );
  });
  final first = frame.planes[0];
  final isBgra = frame.format == CameraFrameFormat.bgra8888;
  final uPlane = isBgra ? null : frame.planes[1];
  final vPlane = isBgra ? null : frame.planes[2];
  for (var y = 0; y < edge; y++) {
    for (var x = 0; x < edge; x++) {
      var red = 0.0, green = 0.0, blue = 0.0;
      for (var sy = 0; sy < samplesY; sy++) {
        final uprightY = ySamples[y * samplesY + sy];
        for (var sx = 0; sx < samplesX; sx++) {
          var uprightX = xSamples[x * samplesX + sx];
          if (frame.mirror) uprightX = uprightWidth - 1 - uprightX;
          late int rawX, rawY;
          switch (turns) {
            case 0:
              rawX = uprightX;
              rawY = uprightY;
            case 1:
              rawX = uprightY;
              rawY = frame.height - 1 - uprightX;
            case 2:
              rawX = frame.width - 1 - uprightX;
              rawY = frame.height - 1 - uprightY;
            case 3:
              rawX = frame.width - 1 - uprightY;
              rawY = uprightX;
          }
          final offset = rawY * first.rowStride + rawX * first.pixelStride;
          if (isBgra) {
            blue += first.bytes[offset];
            green += first.bytes[offset + 1];
            red += first.bytes[offset + 2];
          } else {
            final chromaX = rawX ~/ 2, chromaY = rawY ~/ 2;
            final u =
                uPlane!.bytes[chromaY * uPlane.rowStride +
                    chromaX * uPlane.pixelStride] -
                128;
            final v =
                vPlane!.bytes[chromaY * vPlane.rowStride +
                    chromaX * vPlane.pixelStride] -
                128;
            final yValue = first.bytes[offset];
            if (frame.yuvFullRange) {
              red += (yValue + 1.402 * v).clamp(0.0, 255.0);
              green += (yValue - .344136 * u - .714136 * v).clamp(0.0, 255.0);
              blue += (yValue + 1.772 * u).clamp(0.0, 255.0);
            } else {
              final luma = math.max(0, yValue - 16) * 1.164383;
              red += (luma + 1.596027 * v).clamp(0.0, 255.0);
              green += (luma - .391762 * u - .812968 * v).clamp(0.0, 255.0);
              blue += (luma + 2.017232 * u).clamp(0.0, 255.0);
            }
          }
        }
      }
      final index = y * edge + x;
      tensor[index] = red / divisor - 1;
      tensor[channelSize + index] = green / divisor - 1;
      tensor[2 * channelSize + index] = blue / divisor - 1;
    }
  }
  return PreparedCameraFrame(
    tensor: tensor,
    width: uprightWidth,
    height: uprightHeight,
  );
}

void _validate(CameraFrameData frame) {
  if (frame.width <= 0 || frame.height <= 0) {
    throw const FormatException('相机画面尺寸无效。');
  }
  if (frame.clockwiseQuarterTurns < 0 || frame.clockwiseQuarterTurns > 3) {
    throw const FormatException('相机画面旋转方向无效。');
  }
  switch (frame.format) {
    case CameraFrameFormat.bgra8888:
      if (frame.planes.length != 1) {
        throw const FormatException('相机 BGRA 图层数量无效。');
      }
      _validatePlane(frame.planes[0], frame.width, frame.height, 4);
    case CameraFrameFormat.yuv420:
      if (frame.planes.length != 3) {
        throw const FormatException('相机 YUV 图层数量无效。');
      }
      _validatePlane(frame.planes[0], frame.width, frame.height, 1);
      final chromaWidth = (frame.width + 1) ~/ 2;
      final chromaHeight = (frame.height + 1) ~/ 2;
      _validatePlane(frame.planes[1], chromaWidth, chromaHeight, 1);
      _validatePlane(frame.planes[2], chromaWidth, chromaHeight, 1);
  }
}

void _validatePlane(
  CameraFramePlane plane,
  int width,
  int height,
  int bytesPerPixel,
) {
  if (plane.pixelStride < bytesPerPixel || plane.rowStride <= 0) {
    throw const FormatException('相机图层步长无效。');
  }
  final rowBytes = (width - 1) * plane.pixelStride + bytesPerPixel;
  final lastPixelEnd = (height - 1) * plane.rowStride + rowBytes;
  // The last row need not include padding; some Android image planes omit it.
  if (plane.rowStride < rowBytes || plane.bytes.length < lastPixelEnd) {
    throw const FormatException('相机图层数据不完整。');
  }
}
