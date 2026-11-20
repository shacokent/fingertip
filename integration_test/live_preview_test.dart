import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/camera_frame.dart';
import 'package:offline_nail_demo/services/nail_segmentation.dart';
import 'package:offline_nail_demo/widgets/live_nail_overlay.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('preview frames use the real local model and clear stale nails', (
    tester,
  ) async {
    final sample = await rootBundle.load('assets/samples/hand.jpg');
    final decoded = img.decodeImage(
      sample.buffer.asUint8List(sample.offsetInBytes, sample.lengthInBytes),
    );
    expect(decoded, isNotNull);
    final photo = img.bakeOrientation(decoded!);
    // Preserve the source dimensions and deliberately include camera row padding.
    // No camera permission or personal photo is needed for this integration test.
    final rowStride = photo.width * 4 + 16;
    final pixels = Uint8List(rowStride * photo.height);
    for (var y = 0; y < photo.height; y++) {
      for (var x = 0; x < photo.width; x++) {
        final pixel = photo.getPixel(x, y);
        final offset = y * rowStride + x * 4;
        pixels[offset] = pixel.b.toInt();
        pixels[offset + 1] = pixel.g.toInt();
        pixels[offset + 2] = pixel.r.toInt();
        pixels[offset + 3] = 255;
      }
    }
    final sourceFrame = CameraFrameData(
      width: photo.width,
      height: photo.height,
      format: CameraFrameFormat.bgra8888,
      planes: [
        CameraFramePlane(bytes: pixels, rowStride: rowStride, pixelStride: 4),
      ],
    );
    final engine = NailSegmentationEngine();
    final counts = <int>[];
    final conversionMilliseconds = <int>[];
    final inferenceMilliseconds = <int>[];
    final warmUp = Stopwatch()..start();
    try {
      await engine.warmUp();
      warmUp.stop();
      var nails = <NailRegion>[];
      for (var frameIndex = 0; frameIndex < 3; frameIndex++) {
        final conversion = Stopwatch()..start();
        final prepared = await compute(prepareCameraFrame, sourceFrame);
        conversion.stop();
        expect(prepared.width, photo.width);
        expect(prepared.height, photo.height);
        final inference = Stopwatch()..start();
        nails = await engine.detect(
          prepared.tensor,
          width: prepared.width,
          height: prepared.height,
        );
        inference.stop();
        counts.add(nails.length);
        conversionMilliseconds.add(conversion.elapsedMilliseconds);
        inferenceMilliseconds.add(inference.elapsedMilliseconds);
        expect(
          nails.length,
          greaterThanOrEqualTo(3),
          reason:
              'The bundled fixture must still be recognized as a live frame.',
        );
      }
      expect(counts.toSet(), hasLength(1));
      final samplePng = Uint8List.fromList(img.encodePng(photo));
      final imageSize = Size(photo.width.toDouble(), photo.height.toDouble());
      await tester.pumpWidget(
        _PreviewScene(bytes: samplePng, imageSize: imageSize, nails: nails),
      );
      await precacheImage(
        MemoryImage(samplePng),
        tester.element(find.byType(LiveNailOverlay)),
      );
      await tester.pumpAndSettle();
      expect(find.text('已识别到 ${nails.length} 个指甲'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();
      }
      await binding.takeScreenshot('live_preview_detected');

      final blank = await compute(
        prepareCameraFrame,
        CameraFrameData(
          width: photo.width,
          height: photo.height,
          format: CameraFrameFormat.bgra8888,
          planes: [
            CameraFramePlane(
              bytes: Uint8List(pixels.length),
              rowStride: rowStride,
              pixelStride: 4,
            ),
          ],
        ),
      );
      final blankNails = await engine.detect(
        blank.tensor,
        width: blank.width,
        height: blank.height,
      );
      expect(blankNails, isEmpty);
      final blankPng = Uint8List.fromList(
        img.encodePng(img.Image(width: photo.width, height: photo.height)),
      );
      await tester.pumpWidget(
        _PreviewScene(bytes: blankPng, imageSize: imageSize, nails: blankNails),
      );
      await precacheImage(
        MemoryImage(blankPng),
        tester.element(find.byType(LiveNailOverlay)),
      );
      await tester.pumpAndSettle();
      expect(find.text('尚未识别到指甲'), findsOneWidget);
      expect(find.text('已识别到 ${nails.length} 个指甲'), findsNothing);
      expect(tester.takeException(), isNull);
      await binding.takeScreenshot('live_preview_empty');

      // Closing the cached session must remain safe after multiple frames.
      await Future.wait([engine.close(), engine.close()]);
      await expectLater(
        engine.detect(blank.tensor, width: blank.width, height: blank.height),
        throwsStateError,
      );
      binding.reportData = {
        ...?binding.reportData,
        'previewMetrics': {
          'fixture': 'assets/samples/hand.jpg',
          'fixtureIsUserPhoto': false,
          'sourceWidth': photo.width,
          'sourceHeight': photo.height,
          'frameFormat': 'BGRA8888 with row padding',
          'model': 'bundled ONNX, RGB NCHW 128x128, 0/180 ensemble',
          'frameCounts': counts,
          'blankCount': blankNails.length,
          'warmUpMilliseconds': warmUp.elapsedMilliseconds,
          'conversionMilliseconds': conversionMilliseconds,
          'inferenceMilliseconds': inferenceMilliseconds,
          'closedEngineRejectsNewFrame': true,
          'platform': Platform.operatingSystem,
          'performanceScope':
              'Test device only; not a production phone benchmark',
        },
      };
    } finally {
      await engine.close();
    }
  });
}

/// Keeps the original photo aspect ratio so this fixture can show every marker.
/// The same production overlay still uses BoxFit.cover mapping, as the camera
/// page does; separate geometry tests cover cropped preview viewports.
class _PreviewScene extends StatelessWidget {
  const _PreviewScene({
    required this.bytes,
    required this.imageSize,
    required this.nails,
  });

  final Uint8List bytes;
  final Size imageSize;
  final List<NailRegion> nails;

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      backgroundColor: const Color(0xFFFAF3F0),
      appBar: AppBar(
        title: const Text('拍照试戴'),
        backgroundColor: const Color(0xFFFAF3F0),
        foregroundColor: const Color(0xFF34242B),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Text(
                '自然拍摄，让指甲清晰可见即可',
                style: TextStyle(color: Color(0xFF806B71), fontSize: 13),
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: AspectRatio(
                    aspectRatio: imageSize.aspectRatio,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          const ColoredBox(color: Colors.black),
                          Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                          LiveNailOverlay(nails: nails, imageSize: imageSize),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(24),
              child: Icon(
                Icons.camera_alt_outlined,
                size: 36,
                color: Color(0xFF7A3F4E),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
