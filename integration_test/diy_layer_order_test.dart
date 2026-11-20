import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:offline_nail_demo/main.dart' as app;
import 'package:offline_nail_demo/models/diy_models.dart';
import 'package:offline_nail_demo/screens/diy_studio_page.dart';
import 'package:offline_nail_demo/screens/home_page.dart';
import 'package:offline_nail_demo/services/diy_library.dart';
import 'package:offline_nail_demo/services/diy_renderer.dart';
import 'package:offline_nail_demo/widgets/diy_canvas.dart';

const _red = Color(0xFFD32340), _blue = Color(0xFF236BD3);
const _ink = DiyLayer(
  id: 'ink',
  kind: DiyLayerKind.stroke,
  name: '红色手绘',
  width: 1,
  height: 1,
  color: _red,
  strokeWidth: .16,
  points: [Offset(.25, .5), Offset(.75, .5)],
);
const _eraser = DiyLayer(
  id: 'eraser',
  kind: DiyLayerKind.stroke,
  name: '橡皮',
  width: 1,
  height: 1,
  erase: true,
  strokeWidth: .28,
  points: [Offset(.2, .5), Offset(.8, .5)],
);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('layer arrows change real occlusion and persist after reload', (
    tester,
  ) async {
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    final temporary = await getTemporaryDirectory();
    final folder = Directory(
      '${temporary.path}/layer_qa_${DateTime.now().microsecondsSinceEpoch}',
    );
    await folder.create(recursive: true);
    final library = DiyLibrary(directory: Directory('${folder.path}/library'));
    final source = File('${folder.path}/blue.png');
    final sourceBytes = await _solidPng(_blue);
    await source.writeAsBytes(sourceBytes);
    final image = DiyLayer(
      id: 'image',
      name: '蓝色图片',
      kind: DiyLayerKind.image,
      imagePath: source.path,
      width: .8,
      height: .8,
    );
    const accent = DiyLayer(
      id: 'accent',
      name: '心形素材',
      kind: DiyLayerKind.sticker,
      stickerId: 'heart_0',
      x: .5,
      y: .24,
      width: .24,
      height: .18,
    );
    final saved = await library.save(
      DiyNailDesign(name: '排序验收', layers: [_ink, image, accent]),
    );
    try {
      await tester.pumpWidget(const app.NailStudioApp());
      await tester.pumpAndSettle();
      final route = Navigator.of(tester.element(find.byType(HomePage)))
          .push<DiySavedStyle>(
            MaterialPageRoute(
              builder: (_) => DiyStudioPage(initial: saved, library: library),
            ),
          );
      unawaited(route);
      await _until(tester, () => find.byType(DiyCanvas).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('diy-layers-tool')));
      await tester.pumpAndSettle();
      final before = await _captureCanvasCenter(
        tester,
        binding,
        'layers_image_above',
      );
      expect(before, _rgba(_blue));

      await _tap(tester, 'diy-layer-down-image');
      expect(_ids(tester), ['image', 'ink', 'accent']);
      final behind = await _captureCanvasCenter(
        tester,
        binding,
        'layers_ink_above',
      );
      expect(behind, _rgba(_red));
      await _tap(tester, 'diy-layer-up-image');
      expect(_ids(tester), ['ink', 'image', 'accent']);
      expect(await _canvasCenter(tester, binding), _rgba(_blue));
      await tester.tap(find.byTooltip('撤销设计'));
      await tester.pumpAndSettle();
      expect(_ids(tester), ['image', 'ink', 'accent']);
      expect(await _canvasCenter(tester, binding), _rgba(_red));
      await tester.tap(find.byTooltip('重做设计'));
      await tester.pumpAndSettle();
      expect(_ids(tester), ['ink', 'image', 'accent']);
      expect(await _canvasCenter(tester, binding), _rgba(_blue));
      await _tap(tester, 'diy-layer-down-image');
      final design = tester.widget<DiyCanvas>(find.byType(DiyCanvas)).design;
      final raster = await rasterizeDiyDesign(design);
      expect(await _pngPixel(raster, .5, .5), _rgba(_red));

      await tester.tap(find.byKey(const ValueKey('diy-save')));
      await _until(tester, () => find.byType(DiyStudioPage).evaluate().isEmpty);
      expect(await route, isNotNull);
      final reloaded = (await library.load()).single;
      expect(reloaded.design.layers.map((l) => l.id), [
        'image',
        'ink',
        'accent',
      ]);
      final savedPng = await File(reloaded.style.texturePath!).readAsBytes();
      expect(await _pngPixel(savedPng, .5, .5), _rgba(_red));
      final reRaster = await rasterizeDiyDesign(reloaded.design);
      expect(
        await _rawPixels(reRaster),
        orderedEquals(await _rawPixels(raster)),
      );
      expect(await source.readAsBytes(), orderedEquals(sourceBytes));

      final centeredSticker = accent.copyWith(y: .5);
      final expectedArt = await rasterizeDiyDesign(
        DiyNailDesign(layers: [image, centeredSticker]),
      );
      final erased = await rasterizeDiyDesign(
        DiyNailDesign(layers: [image, _ink, centeredSticker, _eraser]),
      );
      expect(
        await _rawPixels(erased),
        orderedEquals(await _rawPixels(expectedArt)),
      );
      final penAfterEraser = await rasterizeDiyDesign(
        DiyNailDesign(layers: [image, _eraser, _ink]),
      );
      expect(await _pngPixel(penAfterEraser, .5, .5), _rgba(_red));
      expect(tester.takeException(), isNull);
      binding.reportData = {
        ...?binding.reportData,
        'layerMetrics': {
          'imageAboveStrokePreviewRgba': before,
          'strokeAboveImagePreviewRgba': behind,
          'realArrowButtonsChangeOcclusion': true,
          'undoRedoRestoreOrderAndPixels': true,
          'savedReloadedOrder': reloaded.design.layers
              .map((l) => l.id)
              .toList(),
          'savedPngMatchesPreview': true,
          'reloadedDesignRendersSamePixels': true,
          'eraserPreservesImageStickerAndBase': true,
          'eraserDoesNotRemoveHigherInk': true,
          'originalSourceUnchanged': true,
          'platform': Platform.operatingSystem,
          'scope':
              'Native simulator with generated fixtures; no private photos',
        },
        'layerExports': {
          'layers_saved_design': base64Encode(savedPng),
          'layers_eraser_protection': base64Encode(erased),
        },
      };
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      if (await folder.exists()) await folder.delete(recursive: true);
    }
  });
}

List<String> _ids(WidgetTester tester) => tester
    .widget<DiyCanvas>(find.byType(DiyCanvas))
    .design
    .layers
    .map((l) => l.id)
    .toList();

Future<void> _tap(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<List<int>> _captureCanvasCenter(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
  String name,
) async {
  final position = tester.getCenter(find.byType(DiyCanvas));
  final png = Uint8List.fromList(await binding.takeScreenshot(name));
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
  return _pngPixel(
    png,
    position.dx / viewport.width,
    position.dy / viewport.height,
  );
}

Future<List<int>> _canvasCenter(
  WidgetTester tester,
  IntegrationTestWidgetsFlutterBinding binding,
) => _captureCanvasCenter(tester, binding, 'layers_check');

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (done()) return;
  }
  expect(done(), isTrue, reason: 'Layer operation did not finish');
}

List<int> _rgba(Color color) => [
  (color.r * 255).round(),
  (color.g * 255).round(),
  (color.b * 255).round(),
  (color.a * 255).round(),
];

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 64);
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _rawPixels(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<List<int>> _pngPixel(Uint8List png, double x, double y) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    final data = (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
    final ix = (x * image.width).floor().clamp(0, image.width - 1);
    final iy = (y * image.height).floor().clamp(0, image.height - 1);
    return data.sublist(
      (iy * image.width + ix) * 4,
      (iy * image.width + ix) * 4 + 4,
    );
  } finally {
    image.dispose();
  }
}
