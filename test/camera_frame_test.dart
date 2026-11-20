import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/services/camera_frame.dart';

CameraFrameData bgraFrame(
  int width,
  int height,
  List<int> Function(int x, int y) rgb, {
  int turns = 0,
  bool mirror = false,
  int rowPadding = 0,
}) {
  final stride = width * 4 + rowPadding;
  // Model the iOS row padding and its optional absence after the last row.
  final bytes = Uint8List((height - 1) * stride + width * 4);
  bytes.fillRange(0, bytes.length, 213);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final color = rgb(x, y), offset = y * stride + x * 4;
      bytes[offset] = color[2];
      bytes[offset + 1] = color[1];
      bytes[offset + 2] = color[0];
      bytes[offset + 3] = 0; // Camera alpha must not erase the RGB channels.
    }
  }
  return CameraFrameData(
    width: width,
    height: height,
    format: CameraFrameFormat.bgra8888,
    planes: [CameraFramePlane(bytes: bytes, rowStride: stride, pixelStride: 4)],
    clockwiseQuarterTurns: turns,
    mirror: mirror,
  );
}

double value(PreparedCameraFrame frame, int x, int y, [int channel = 0]) =>
    frame.tensor[channel * 128 * 128 + y * 128 + x];

void main() {
  test('BGRA padding, alpha and RGB NCHW normalization are handled', () {
    final prepared = prepareCameraFrame(
      bgraFrame(128, 128, (x, y) => [x, y, 13], rowPadding: 12),
    );
    expect(prepared.width, 128);
    expect(prepared.height, 128);
    expect(prepared.tensor.length, 3 * 128 * 128);
    expect(value(prepared, 64, 23), closeTo(64 / 127.5 - 1, 1e-6));
    expect(value(prepared, 64, 23, 1), closeTo(23 / 127.5 - 1, 1e-6));
    expect(value(prepared, 64, 23, 2), closeTo(13 / 127.5 - 1, 1e-6));
    expect(value(prepared, 127, 127), closeTo(127 / 127.5 - 1, 1e-6));
  });

  for (var turns = 0; turns < 4; turns++) {
    for (final mirror in [false, true]) {
      test('non-square rotation $turns then horizontal mirror $mirror', () {
        final prepared = prepareCameraFrame(
          bgraFrame(
            4,
            2,
            (x, y) => [20 + (y * 4 + x) * 25, 0, 0],
            turns: turns,
            mirror: mirror,
          ),
        );
        final expectedCorners = [
          [0, 3, 4, 7],
          [4, 0, 7, 3],
          [7, 4, 3, 0],
          [3, 7, 0, 4],
        ][turns];
        final corners = mirror
            ? [
                expectedCorners[1],
                expectedCorners[0],
                expectedCorners[3],
                expectedCorners[2],
              ]
            : expectedCorners;
        expect(prepared.width, turns.isOdd ? 2 : 4);
        expect(prepared.height, turns.isOdd ? 4 : 2);
        for (final (index, point) in [
          (0, (0, 0)),
          (1, (127, 0)),
          (2, (0, 127)),
          (3, (127, 127)),
        ]) {
          expect(
            value(prepared, point.$1, point.$2),
            closeTo((20 + corners[index] * 25) / 127.5 - 1, 1e-6),
          );
        }
      });
    }
  }

  test('area sampling averages a downsampled checkerboard', () {
    final prepared = prepareCameraFrame(
      bgraFrame(256, 256, (x, y) {
        final channel = (x + y).isEven ? 0 : 255;
        return [channel, channel, channel];
      }),
    );
    expect(prepared.tensor.every((channel) => channel.abs() < 1e-6), isTrue);
  });

  test('video-range YUV black and white preserve normalized endpoints', () {
    final y = Uint8List(128 * 128);
    for (var row = 0; row < 128; row++) {
      y.fillRange(row * 128, row * 128 + 64, 16);
      y.fillRange(row * 128 + 64, (row + 1) * 128, 235);
    }
    final neutral = Uint8List(64 * 64)..fillRange(0, 64 * 64, 128);
    final prepared = prepareCameraFrame(
      CameraFrameData(
        width: 128,
        height: 128,
        format: CameraFrameFormat.yuv420,
        planes: [
          CameraFramePlane(bytes: y, rowStride: 128),
          CameraFramePlane(bytes: neutral, rowStride: 64),
          CameraFramePlane(bytes: neutral, rowStride: 64),
        ],
      ),
    );
    for (var channel = 0; channel < 3; channel++) {
      expect(value(prepared, 0, 127, channel), -1);
      expect(value(prepared, 127, 127, channel), closeTo(1, 1e-5));
    }
  });

  test('odd YUV sizes honor independent row/pixel strides and final row', () {
    final y = Uint8List(21)..fillRange(0, 21, 1);
    final u = Uint8List(9)..fillRange(0, 9, 1);
    final v = Uint8List(11)..fillRange(0, 11, 1);
    for (var row = 0; row < 3; row++) {
      for (var x = 0; x < 3; x++) {
        y[row * 8 + x * 2] = 81;
      }
    }
    for (var row = 0; row < 2; row++) {
      for (var x = 0; x < 2; x++) {
        u[row * 6 + x * 2] = 90;
        v[row * 7 + x * 3] = 240;
      }
    }
    y[20] = 235;
    u[8] = v[10] = 128;
    final prepared = prepareCameraFrame(
      CameraFrameData(
        width: 3,
        height: 3,
        format: CameraFrameFormat.yuv420,
        planes: [
          CameraFramePlane(bytes: y, rowStride: 8, pixelStride: 2),
          CameraFramePlane(bytes: u, rowStride: 6, pixelStride: 2),
          CameraFramePlane(bytes: v, rowStride: 7, pixelStride: 3),
        ],
      ),
    );
    expect(value(prepared, 0, 0), closeTo(254.44 / 127.5 - 1, .01));
    expect(value(prepared, 0, 0, 1), closeTo(-1, .01));
    expect(value(prepared, 0, 0, 2), closeTo(-1, .01));
    for (var channel = 0; channel < 3; channel++) {
      expect(value(prepared, 127, 127, channel), closeTo(1, 1e-5));
    }
  });

  test('frame transfer and conversion run through compute', () async {
    final prepared = await compute(
      prepareCameraFrame,
      bgraFrame(3, 2, (x, y) => [255, 0, 128]),
    );
    expect(prepared.width, 3);
    expect(value(prepared, 0, 0), 1);
    expect(value(prepared, 0, 0, 1), -1);
  });

  test('malformed planes and frame metadata fail before pixel access', () {
    CameraFrameData frame({
      int width = 2,
      int height = 2,
      int turns = 0,
      int rowStride = 8,
      int pixelStride = 4,
      int byteCount = 16,
      List<CameraFramePlane>? planes,
    }) => CameraFrameData(
      width: width,
      height: height,
      format: CameraFrameFormat.bgra8888,
      clockwiseQuarterTurns: turns,
      planes:
          planes ??
          [
            CameraFramePlane(
              bytes: Uint8List(byteCount),
              rowStride: rowStride,
              pixelStride: pixelStride,
            ),
          ],
    );
    for (final invalid in [
      frame(width: 0),
      frame(height: -1),
      frame(turns: -1),
      frame(turns: 4),
      frame(rowStride: 7),
      frame(rowStride: 0),
      frame(pixelStride: 3),
      frame(byteCount: 15),
      frame(planes: []),
      const CameraFrameData(
        width: 2,
        height: 2,
        format: CameraFrameFormat.yuv420,
        planes: [],
      ),
    ]) {
      expect(() => prepareCameraFrame(invalid), throwsFormatException);
    }
  });
}
