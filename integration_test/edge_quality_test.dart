import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:offline_nail_demo/main.dart' as app;
import 'package:offline_nail_demo/models/diy_stickers.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/screens/editor_page.dart';
import 'package:offline_nail_demo/screens/home_page.dart';
import 'package:offline_nail_demo/services/nail_analysis.dart';
import 'package:offline_nail_demo/services/nail_photo_refinement.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';
import 'package:offline_nail_demo/services/nail_segmentation.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real photo edge refinement compared with the coarse baseline', (
    tester,
  ) async {
    final sample = await rootBundle.load('assets/samples/hand.jpg');
    final raw = sample.buffer.asUint8List(
      sample.offsetInBytes,
      sample.lengthInBytes,
    );
    final prepared = preparePhoto(raw);
    final coarseEngine = NailSegmentationEngine();
    final coarsePrediction = await coarseEngine.detectPhoto(
      prepared.tensor,
      width: prepared.width,
      height: prepared.height,
    );
    final coarse = coarsePrediction.nails;
    final variants = <String, List<NailRegion>>{};
    final variantReports = <String, Object>{};
    final predictions = <List<double>>[];
    final cropInputs = <List<double>>[];
    for (final threshold in [.30, .32, .34, .38]) {
      var predictionIndex = 0;
      final name =
          'variant_${(threshold * 100).round().toString().padLeft(3, '0')}';
      final reports = <Map<String, Object>>[];
      variants[name] = await refinePhotoNails(
        pngBytes: prepared.bytes,
        imageWidth: prepared.width,
        imageHeight: prepared.height,
        nails: coarse,
        coarseProbabilities: coarsePrediction.probabilities,
        engine: coarseEngine,
        contourThreshold: threshold,
        predictor: (tensor) async {
          final index = predictionIndex++;
          if (index < predictions.length) {
            expect(tensor, orderedEquals(cropInputs[index]));
            return predictions[index];
          }
          cropInputs.add(List<double>.of(tensor));
          final prediction = await coarseEngine.predictPhotoCrop(tensor);
          predictions.add(prediction);
          return prediction;
        },
        onRefinement: (report) => reports.add(report.toJson()),
      );
      expect(predictionIndex, 5);
      variantReports[name] = {
        'contourThreshold': threshold,
        'reports': reports,
      };
    }
    expect(predictions.length, 5);
    await coarseEngine.close();
    final photoEngine = NailAnalysisEngine();
    final refined = await photoEngine.analyze(raw);
    await photoEngine.close();
    expect(coarse.length, 5);
    expect(refined.nails.length, 5);
    expect(
      refined.nails.map((nail) => nail.id).toSet(),
      coarse.map((nail) => nail.id).toSet(),
    );

    final directory = await getTemporaryDirectory();
    final texture = File(
      '${directory.path}/edge_qa_${DateTime.now().microsecondsSinceEpoch}.png',
    );
    final design = await _design();
    await texture.writeAsBytes(await _png(design));
    design.dispose();
    final custom = NailStyle(
      'edge-qa-diy',
      '蓝蝶边缘验证',
      '',
      Colors.transparent,
      NailPattern.solid,
      coverage: 1,
      texturePath: texture.path,
    );
    final wine = NailStyle.byId('wine')!;
    final exports = <String, String>{};
    final metrics = <String, Object?>{};
    final equivalencePixels = <String, Uint8List>{};
    try {
      for (final entry in {
        'before': coarse,
        'after': refined.nails,
        ...variants,
      }.entries) {
        final codec = await ui.instantiateImageCodec(prepared.bytes);
        final photo = (await codec.getNextFrame()).image;
        codec.dispose();
        final program = await ui.FragmentProgram.fromAsset('shaders/nail.frag');
        final renderer = NailRenderer(photo, program);
        try {
          for (final nail in entry.value) {
            await renderer.addMask(nail);
          }
          final mask = await _mask(renderer, entry.value);
          final maskPixels = (await mask.toByteData())!.buffer.asUint8List();
          if (entry.key == 'after' || entry.key == 'variant_030') {
            equivalencePixels['${entry.key}_mask'] = maskPixels;
          }
          exports['edge_${entry.key}_mask'] = base64Encode(await _png(mask));
          mask.dispose();
          final photoPixels = (await photo.toByteData())!.buffer.asUint8List();
          var protectedPixels = 0;
          for (final style in [
            wine,
            if (!entry.key.startsWith('variant_')) custom,
          ]) {
            final output = await renderer.export(entry.value, {
              for (final nail in entry.value) nail.id: style,
            }, .65);
            final outputPixels = (await output.toByteData())!.buffer
                .asUint8List();
            if (!style.isCustom &&
                (entry.key == 'after' || entry.key == 'variant_030')) {
              equivalencePixels['${entry.key}_wine'] = outputPixels;
            }
            protectedPixels = _assertOutsideUnchanged(
              photoPixels,
              outputPixels,
              maskPixels,
              photo.width,
              photo.height,
            );
            exports['edge_${entry.key}_${style.isCustom ? 'diy' : 'wine'}'] =
                base64Encode(await _png(output));
            output.dispose();
          }
          for (final nail in entry.value) {
            final one = await _mask(renderer, [nail]);
            exports['edge_${entry.key}_mask_${nail.id}'] = base64Encode(
              await _png(one),
            );
            one.dispose();
          }
          metrics[entry.key] = {
            'protectedOutsidePixels': protectedPixels,
            'nails': [
              for (final nail in entry.value)
                {
                  'id': nail.id,
                  'center': [nail.center.dx, nail.center.dy],
                  'width': nail.width,
                  'height': nail.height,
                  'angle': nail.angle,
                  'maskWidth': nail.maskWidth,
                  'maskHeight': nail.maskHeight,
                },
            ],
          };
        } finally {
          renderer.dispose();
        }
      }
      for (final kind in ['mask', 'wine']) {
        expect(
          equivalencePixels['after_$kind'],
          orderedEquals(equivalencePixels['variant_030_$kind']!),
          reason: 'Production default must match the validated .30 variant',
        );
      }
      await tester.pumpWidget(const app.NailStudioApp());
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(tester.element(find.byType(HomePage))).push<void>(
          MaterialPageRoute(builder: (_) => EditorPage(analysis: refined)),
        ),
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(NailScene).evaluate().isNotEmpty) break;
      }
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inline-style-wine')));
      await tester.pumpAndSettle();
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();
      }
      await binding.takeScreenshot('edge_editor_after');
      expect(tester.takeException(), isNull);
      binding.reportData = {
        ...?binding.reportData,
        'exports': exports,
        'edgeMetrics': {
          'fixture': 'assets/samples/hand.jpg',
          'width': prepared.width,
          'height': prepared.height,
          'beforeMethod': 'unchanged whole-photo 0/180 model and coarse masks',
          'afterMethod': 'production photo analysis',
          'analysisMilliseconds': refined.elapsed.inMilliseconds,
          'outsidePhotoPreservedForWineAndDiy': true,
          'variantPredictionsCached': predictions.length,
          'allVariantsUseIdenticalCropInputs': true,
          'productionDefaultMatchesVariant030Pixels': true,
          'variantReports': variantReports,
          ...metrics,
          'scope':
              'Native simulator and one upstream example; supplied upstream GT '
              'is compared on host. This is not an independent accuracy test.',
        },
      };
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      if (await texture.exists()) await texture.delete();
    }
  });
}

Future<Uint8List> _png(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.png,
))!.buffer.asUint8List();

Future<ui.Image> _mask(NailRenderer renderer, List<NailRegion> nails) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  for (final nail in nails.where((nail) => nail.enabled)) {
    final mask = renderer.masks[nail.id]!;
    canvas.save();
    canvas.translate(nail.center.dx, nail.center.dy);
    canvas.rotate(nail.angle);
    canvas.drawImageRect(
      mask,
      Rect.fromLTWH(0, 0, mask.width.toDouble(), mask.height.toDouble()),
      Rect.fromCenter(
        center: Offset.zero,
        width: nail.width,
        height: nail.height,
      ),
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();
  }
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(renderer.photo.width, renderer.photo.height);
  } finally {
    picture.dispose();
  }
}

int _assertOutsideUnchanged(
  Uint8List photo,
  Uint8List output,
  Uint8List mask,
  int width,
  int height,
) {
  var protected = 0;
  var mismatches = 0;
  String? firstMismatch;
  for (var y = 1; y < height - 1; y++) {
    for (var x = 1; x < width - 1; x++) {
      var clear = true;
      for (var dy = -1; dy <= 1 && clear; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (mask[((y + dy) * width + x + dx) * 4 + 3] != 0) {
            clear = false;
            break;
          }
        }
      }
      if (!clear) continue;
      final i = (y * width + x) * 4;
      for (var channel = 0; channel < 4; channel++) {
        if (output[i + channel] != photo[i + channel]) {
          mismatches++;
          firstMismatch ??= '$x,$y';
          break;
        }
      }
      protected++;
    }
  }
  expect(
    mismatches,
    0,
    reason: 'Pixels outside all nail masks changed; first at $firstMismatch',
  );
  expect(protected, greaterThan(width * height * .7));
  return protected;
}

Future<ui.Image> _design() async {
  const width = 256.0, height = 384.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFFF8EF), BlendMode.src);
  final bounds = const Rect.fromLTWH(34, 57, 188, 270);
  canvas.save();
  canvas.clipRect(bounds);
  canvas.drawRect(bounds, Paint()..color = const Color(0xFFCCE0EE));
  for (var x = -400.0; x < 400; x += 20) {
    canvas.drawLine(
      Offset(x, 0),
      Offset(x + 250, height),
      Paint()
        ..color = const Color(0xFF6F8FB7)
        ..strokeWidth = 6,
    );
  }
  canvas.restore();
  canvas.save();
  canvas.translate(53, 111);
  canvas.scale(1.5);
  paintDiySticker(canvas, DiySticker.byId('butterfly_0')!);
  canvas.restore();
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width.toInt(), height.toInt());
  } finally {
    picture.dispose();
  }
}
