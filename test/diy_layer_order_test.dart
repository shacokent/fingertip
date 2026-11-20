import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/diy_models.dart';
import 'package:offline_nail_demo/screens/diy_studio_page.dart';
import 'package:offline_nail_demo/services/diy_library.dart';
import 'package:offline_nail_demo/services/diy_renderer.dart';
import 'package:offline_nail_demo/widgets/diy_canvas.dart';

const _red = Color(0xFFE51E32);
const _blue = Color(0xFF245ED2);
const _green = Color(0xFF19A04A);
const _size = Size(120, 180);
const _ink = DiyLayer(
  id: 'ink',
  name: '红色手绘',
  kind: DiyLayerKind.stroke,
  width: 1,
  height: 1,
  color: _red,
  strokeWidth: .2,
  points: [Offset(.1, .5), Offset(.9, .5)],
);
const _sticker = DiyLayer(
  id: 'heart',
  name: '爱心素材',
  kind: DiyLayerKind.sticker,
  stickerId: 'heart_0',
  width: .6,
  height: .5,
);
const _eraser = DiyLayer(
  id: 'eraser',
  kind: DiyLayerKind.stroke,
  width: 1,
  height: 1,
  erase: true,
  strokeWidth: .08,
  points: [Offset(.1, .5), Offset(.9, .5)],
);

void main() {
  testWidgets('mixed image, sticker and ink honor their complete layer order', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final image = await _solidImage(_blue);
      final photo = _imageLayer('/owned/blue.png');
      try {
        final images = {'/owned/blue.png': image};
        final stickerOnly = await _paint([_sticker], images);
        final inkOverImage = await _paint([photo, _ink], images);
        final imageOverInk = await _paint([_ink, photo], images);
        expect(_pixel(inkOverImage, 60, 90), [229, 30, 50, 255]);
        expect(_pixel(imageOverInk, 60, 90), [36, 94, 210, 255]);
        final stickerOverInk = await _paint([photo, _ink, _sticker], images);
        expect(_pixel(stickerOverInk, 60, 90), _pixel(stickerOnly, 60, 90));
        final inkOverSticker = await _paint([photo, _sticker, _ink], images);
        expect(_pixel(inkOverSticker, 60, 90), [229, 30, 50, 255]);
        final imageAboveBoth = await _paint([_sticker, _ink, photo], images);
        expect(_pixel(imageAboveBoth, 60, 90), [36, 94, 210, 255]);
      } finally {
        image.dispose();
      }
    });
  });

  testWidgets('eraser crosses artwork without clearing it or later ink', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final image = await _solidImage(_blue);
      final photo = _imageLayer('/owned/blue.png').copyWith(x: .3, width: .2);
      final heart = _sticker.copyWith(x: .7, width: .25);
      final images = {'/owned/blue.png': image};
      try {
        final artwork = await _paint([photo, heart], images);
        // An image separates two ink runs; the higher eraser must reach both.
        final early = _ink.copyWith(name: '下层手绘');
        const late = DiyLayer(
          id: 'later-ink',
          kind: DiyLayerKind.stroke,
          width: 1,
          height: 1,
          color: _red,
          strokeWidth: .2,
          points: [Offset(.1, .5), Offset(.9, .5)],
        );
        final erased = await _paint([
          early,
          photo,
          late,
          heart,
          _eraser,
        ], images);
        for (final x in [36, 60, 84]) {
          expect(
            _pixel(erased, x, 90),
            _pixel(artwork, x, 90),
            reason: 'Eraser reveals original artwork/base at x=$x',
          );
        }
        expect(_pixel(erased, 60, 99), [229, 30, 50, 255]);
        const afterEraser = DiyLayer(
          id: 'fresh-ink',
          kind: DiyLayerKind.stroke,
          width: 1,
          height: 1,
          color: _green,
          strokeWidth: .04,
          points: [Offset(.1, .5), Offset(.9, .5)],
        );
        final fresh = await _paint([
          early,
          photo,
          heart,
          _eraser,
          afterEraser,
        ], images);
        expect(_pixel(fresh, 60, 90), [25, 160, 74, 255]);
        final erasedFresh = await _paint([
          early,
          photo,
          heart,
          afterEraser,
          _eraser,
        ], images);
        expect(_pixel(erasedFresh, 60, 90), _pixel(artwork, 60, 90));
      } finally {
        image.dispose();
      }
    });
  });

  testWidgets(
    'layer buttons repaint occlusion and undo, save and reload retain it',
    (tester) async {
      tester.view.physicalSize = const Size(440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final folder = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('diy-layer-order-'),
      ))!;
      late final DiyLibrary library;
      late DiySavedStyle initial;
      await tester.runAsync(() async {
        library = DiyLibrary(directory: Directory('${folder.path}/library'));
        final image = await _solidImage(_blue);
        try {
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List();
          final source = File('${folder.path}/blue.png');
          await source.writeAsBytes(bytes);
          initial = await library.save(
            DiyNailDesign(
              name: '遮挡排序',
              layers: [_ink, _imageLayer(source.path)],
            ),
          );
        } finally {
          image.dispose();
        }
      });
      final navigator = GlobalKey<NavigatorState>();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: SizedBox()),
        ),
      );
      DiySavedStyle? saved;
      unawaited(
        navigator.currentState!
            .push<DiySavedStyle>(
              MaterialPageRoute(
                builder: (_) => RepaintBoundary(
                  key: boundary,
                  child: DiyStudioPage(initial: initial, library: library),
                ),
              ),
            )
            .then((value) => saved = value),
      );
      try {
        await _until(
          tester,
          () => find.byType(DiyCanvas).evaluate().isNotEmpty,
        );
        await _untilPixel(tester, boundary, [36, 94, 210, 255]);
        await tester.tap(find.byKey(const ValueKey('diy-layers-tool')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('diy-layer-down-image')));
        await _untilPixel(tester, boundary, [229, 30, 50, 255]);
        expect(_design(tester).layers.map((l) => l.id), ['image', 'ink']);
        await tester.tapAt(tester.getCenter(find.byType(DiyCanvas)));
        await tester.pumpAndSettle();
        expect(
          tester.widget<DiyCanvas>(find.byType(DiyCanvas)).selectedLayerId,
          'ink',
        );
        await tester.tap(find.byTooltip('撤销设计'));
        await _untilPixel(tester, boundary, [36, 94, 210, 255]);
        await tester.tap(find.byTooltip('重做设计'));
        await _untilPixel(tester, boundary, [229, 30, 50, 255]);
        await tester.tap(find.byKey(const ValueKey('diy-layer-up-image')));
        await _untilPixel(tester, boundary, [36, 94, 210, 255]);
        await tester.tapAt(tester.getCenter(find.byType(DiyCanvas)));
        await tester.pumpAndSettle();
        expect(
          tester.widget<DiyCanvas>(find.byType(DiyCanvas)).selectedLayerId,
          'image',
        );
        await tester.tap(find.byKey(const ValueKey('diy-layer-down-image')));
        await _untilPixel(tester, boundary, [229, 30, 50, 255]);
        await tester.tap(find.byKey(const ValueKey('diy-save')));
        await _until(tester, () => saved != null);
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final loaded = (await library.load()).single;
          expect(loaded.design.layers.map((l) => l.id), ['image', 'ink']);
          final png = await decodeDiyImage(loaded.style.texturePath!);
          try {
            final pixels = (await png.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            expect(_pixel(pixels, 256, 384, width: 512), [229, 30, 50, 255]);
          } finally {
            png.dispose();
          }
          initial = loaded;
        });
        unawaited(
          navigator.currentState!.push<void>(
            MaterialPageRoute(
              builder: (_) => RepaintBoundary(
                key: boundary,
                child: DiyStudioPage(initial: initial, library: library),
              ),
            ),
          ),
        );
        await _until(
          tester,
          () => find.byType(DiyCanvas).evaluate().isNotEmpty,
        );
        await _untilPixel(tester, boundary, [229, 30, 50, 255]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          if (await folder.exists()) await folder.delete(recursive: true);
        });
      }
    },
  );
}

DiyLayer _imageLayer(String path) => DiyLayer(
  id: 'image',
  name: '蓝色图片',
  kind: DiyLayerKind.image,
  imagePath: path,
  width: .6,
  height: .6,
);

DiyNailDesign _design(WidgetTester tester) =>
    tester.widget<DiyCanvas>(find.byType(DiyCanvas)).design;

Future<ui.Image> _solidImage(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(24, 36);
  picture.dispose();
  return image;
}

Future<Uint8List> _paint(
  List<DiyLayer> layers,
  Map<String, ui.Image> images,
) async {
  final recorder = ui.PictureRecorder();
  paintDiyDesign(
    Canvas(recorder),
    _size,
    DiyNailDesign(baseColor: Colors.white, layers: layers),
    images,
    clipToNail: false,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    _size.width.toInt(),
    _size.height.toInt(),
  );
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

List<int> _pixel(Uint8List bytes, int x, int y, {int width = 120}) {
  final offset = (y * width + x) * 4;
  return bytes.sublist(offset, offset + 4);
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (condition()) return;
  }
  expect(
    condition(),
    isTrue,
    reason: 'Asynchronous layer action did not complete',
  );
}

Future<List<int>> _previewPixel(WidgetTester tester, GlobalKey boundary) async {
  await tester.pump();
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final canvasCenter = tester.getCenter(find.byType(DiyCanvas));
  final local = render.globalToLocal(canvasCenter);
  final image = render.toImageSync();
  try {
    final data = (await tester.runAsync(
      () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    return _pixel(
      data.buffer.asUint8List(),
      local.dx.floor(),
      local.dy.floor(),
      width: image.width,
    );
  } finally {
    image.dispose();
  }
}

Future<void> _untilPixel(
  WidgetTester tester,
  GlobalKey boundary,
  List<int> expected,
) async {
  List<int>? actual;
  for (var i = 0; i < 80; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    actual = await _previewPixel(tester, boundary);
    if (actual.toString() == expected.toString()) return;
  }
  expect(
    actual,
    expected,
    reason: 'Visible canvas occlusion must follow the layer order',
  );
}
