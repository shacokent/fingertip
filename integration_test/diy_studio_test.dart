import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:offline_nail_demo/models/diy_models.dart';
import 'package:offline_nail_demo/models/diy_stickers.dart';
import 'package:offline_nail_demo/screens/diy_studio_page.dart';
import 'package:offline_nail_demo/screens/editor_page.dart';
import 'package:offline_nail_demo/services/diy_library.dart';
import 'package:offline_nail_demo/services/nail_analysis.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';
import 'package:offline_nail_demo/widgets/diy_canvas.dart';
import 'package:offline_nail_demo/main.dart' as app;
import 'package:offline_nail_demo/screens/home_page.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('DIY import, draw, save, reload, fit, export and deletion', (
    tester,
  ) async {
    // Keep native IME updates from racing the text injected by this test.
    tester.testTextInput.register();
    addTearDown(tester.testTextInput.unregister);
    final temporary = await getTemporaryDirectory();
    final folder = Directory(
      '${temporary.path}/diy_qa_${DateTime.now().microsecondsSinceEpoch}',
    );
    await folder.create(recursive: true);
    final library = DiyLibrary(directory: Directory('${folder.path}/library'));
    final source = File('${folder.path}/source.png');
    final sourceBytes = await _fixtureImage();
    await source.writeAsBytes(sourceBytes);
    final engine = NailAnalysisEngine();
    final photo = await rootBundle.load('assets/samples/hand.jpg');
    final analysis = await engine.analyze(photo.buffer.asUint8List());
    await engine.close();
    try {
      await tester.pumpWidget(const app.NailStudioApp());
      await tester.pumpAndSettle();
      unawaited(
        Navigator.of(tester.element(find.byType(HomePage))).push<void>(
          MaterialPageRoute(
            builder: (_) => EditorPage(
              analysis: analysis,
              library: library,
              diyImagePicker: () async => source.path,
            ),
          ),
        ),
      );
      await _until(tester, () => find.byType(NailScene).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        tester.getRect(find.byType(NailScene)).bottom,
        lessThanOrEqualTo(
          tester
              .getRect(find.byKey(const ValueKey('inline-style-categories')))
              .top,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('create-diy-style')));
      await tester.pumpAndSettle();
      expect(find.byType(DiyStudioPage), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('diy-style-name')),
        '蓝蝶手绘',
      );
      void checkName(String stage) {
        expect(
          tester
              .widget<TextField>(find.byKey(const ValueKey('diy-style-name')))
              .controller!
              .text,
          '蓝蝶手绘',
          reason: stage,
        );
      }

      checkName('after enterText');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      checkName('after unfocus');
      await tester.tap(find.byKey(const ValueKey('diy-import-image')));
      await _until(
        tester,
        () =>
            find
                .byKey(const ValueKey('diy-layer-scale'))
                .evaluate()
                .isNotEmpty &&
            tester
                    .widget<TextButton>(find.byKey(const ValueKey('diy-save')))
                    .onPressed !=
                null,
      );
      DiyNailDesign currentDesign() =>
          tester.widget<DiyCanvas>(find.byType(DiyCanvas)).design;
      final imported = currentDesign().layers.single;
      checkName('after import');
      expect(imported.imagePath, isNot(source.path));
      await tester.tap(find.byKey(const ValueKey('diy-lock-layer')));
      await tester.pumpAndSettle();
      final canvas = find.byKey(const ValueKey('diy-design-canvas'));
      await tester.drag(canvas, const Offset(45, 0));
      await tester.pumpAndSettle();
      expect(currentDesign().layers.single.x, imported.x);
      expect(currentDesign().layers.single.y, imported.y);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('diy-layer-scale')),
      );
      expect(slider.onChanged, isNotNull);
      slider.onChangeStart?.call(slider.value);
      slider.onChanged!(.6);
      slider.onChangeEnd?.call(.6);
      await tester.pumpAndSettle();
      expect(currentDesign().layers.single.scale, closeTo(.6, .001));
      await tester.tap(find.byKey(const ValueKey('diy-material-tool')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diy-sticker-butterfly_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diy-draw-tool')));
      await tester.pumpAndSettle();
      final canvasRect = tester.getRect(canvas);
      await tester.dragFrom(
        canvasRect.center + const Offset(-20, -30),
        const Offset(40, 60),
      );
      await tester.pumpAndSettle();
      expect(
        currentDesign().layers.where((l) => l.kind == DiyLayerKind.stroke),
        isNotEmpty,
      );
      final layerCount = currentDesign().layers.length;
      await tester.tap(find.byTooltip('撤销设计'));
      await tester.pumpAndSettle();
      expect(currentDesign().layers.length, layerCount - 1);
      checkName('after drawing undo');
      await tester.tap(find.byTooltip('重做设计'));
      await tester.pumpAndSettle();
      expect(currentDesign().layers.length, layerCount);
      checkName('after drawing redo');
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pumpAndSettle();
      }
      await binding.takeScreenshot('diy_studio');
      await tester.tap(find.byKey(const ValueKey('diy-save')));
      await _until(tester, () => find.byType(DiyStudioPage).evaluate().isEmpty);
      await tester.pumpAndSettle();
      var saved = (await library.load()).single;
      expect(saved.name, '蓝蝶手绘');
      expect(saved.design.layers.length, layerCount);
      expect(await source.readAsBytes(), orderedEquals(sourceBytes));
      var scene = tester.widget<NailScene>(find.byType(NailScene));
      expect(scene.styles.values.every((s) => s.id == saved.id), isTrue);
      await binding.takeScreenshot('diy_try_on');
      final texture = await File(saved.style.texturePath!).readAsBytes();
      final output = await scene.renderer.export(
        scene.nails,
        scene.styles,
        scene.gloss,
      );
      final png = (await output.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      output.dispose();

      // A saved style is editable, and a new revision keeps the old image valid.
      final oldTexture = saved.style.texturePath!;
      await tester.tap(find.byKey(ValueKey('custom-style-menu-${saved.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑款式'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('diy-style-name')),
        '蓝蝶手绘·改',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diy-save')));
      await _until(tester, () => find.byType(DiyStudioPage).evaluate().isEmpty);
      await tester.pumpAndSettle();
      saved = (await DiyLibrary(
        directory: Directory('${folder.path}/library'),
      ).load()).single;
      expect(saved.name, '蓝蝶手绘·改');
      expect(saved.style.texturePath, isNot(oldTexture));
      expect(await File(oldTexture).exists(), isTrue);

      // Delete only the private library entry; the imported original is intact.
      await tester.tap(find.byKey(ValueKey('custom-style-menu-${saved.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除款式'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await _until(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
      await tester.pumpAndSettle();
      expect(await library.load(), isEmpty);
      expect(await source.readAsBytes(), orderedEquals(sourceBytes));
      scene = tester.widget<NailScene>(find.byType(NailScene));
      expect(scene.styles.values.any((s) => s.id == saved.id), isFalse);

      // Supplement at a real nail position, then change its contour and undo.
      final beforeCount = scene.nails.length;
      final target = scene.nails.first;
      await tester.tap(find.byTooltip('添加手动甲面'));
      await tester.pumpAndSettle();
      final box = tester.getRect(find.byType(NailScene));
      final fitted = applyBoxFit(
        BoxFit.contain,
        Size(analysis.width.toDouble(), analysis.height.toDouble()),
        box.size,
      ).destination;
      final origin =
          box.topLeft +
          Offset(
            (box.width - fitted.width) / 2,
            (box.height - fitted.height) / 2,
          );
      await tester.tapAt(
        origin + target.center * (fitted.width / analysis.width),
      );
      await _until(
        tester,
        () =>
            tester.widget<NailScene>(find.byType(NailScene)).nails.length ==
            beforeCount + 1,
      );
      await tester.pumpAndSettle();
      var manual = tester.widget<NailScene>(find.byType(NailScene)).nails.last;
      expect(manual.isManual, isTrue);
      expect(manual.label, '局部贴合', reason: 'The real crop model found a nail');
      await tester.tap(find.widgetWithText(ChoiceChip, '位置大小'));
      await tester.pumpAndSettle();
      final rotation = tester.widget<Slider>(
        find.byKey(const ValueKey('nail-adjust-旋转')),
      );
      const chosenAngle = 2.4;
      rotation.onChangeStart?.call(rotation.value);
      rotation.onChanged!(chosenAngle);
      rotation.onChangeEnd?.call(chosenAngle);
      await tester.pumpAndSettle();
      manual = tester.widget<NailScene>(find.byType(NailScene)).nails.last;
      expect(manual.angle, chosenAngle);
      final chosenCenter = manual.center;
      final beforeMask = List<int>.of(manual.maskRgba);
      await tester.tap(find.byKey(const ValueKey('refine-nail-contour')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('放大修边'));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('contour-point-2')),
        const Offset(-42, 8),
      );
      await tester.pumpAndSettle();
      manual = tester.widget<NailScene>(find.byType(NailScene)).nails.last;
      expect(manual.maskRgba, isNot(orderedEquals(beforeMask)));
      final edited = manual;
      final editedMask = List<int>.of(edited.maskRgba);

      // Exercise the native ONNX crop path, with the user's rotation already
      // applied. Refitting must replace the contour without rotating it back.
      ScaffoldMessenger.of(
        tester.element(find.byType(EditorPage)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('refit-nail')));
      await _until(
        tester,
        () =>
            !identical(
              tester
                  .widget<NailScene>(find.byType(NailScene))
                  .nails
                  .last
                  .maskRgba,
              edited.maskRgba,
            ) &&
            tester
                    .widget<TextButton>(
                      find.byKey(const ValueKey('refit-nail')),
                    )
                    .onPressed !=
                null,
      );
      await tester.pumpAndSettle();
      manual = tester.widget<NailScene>(find.byType(NailScene)).nails.last;
      expect(
        find.text('甲缘已更新，保留了您调整的角度和位置。'),
        findsOneWidget,
        reason: 'Real inference succeeded instead of retaining a fallback',
      );
      expect(manual.label, '局部贴合');
      expect(manual.angle, chosenAngle);
      expect(manual.center, chosenCenter);
      expect(manual.id, edited.id);
      expect(manual.maskRgba, isNot(orderedEquals(editedMask)));
      var coveredPixels = 0, opaquePixels = 0, translucentPixels = 0;
      for (var i = 3; i < manual.maskRgba.length; i += 4) {
        final alpha = manual.maskRgba[i];
        if (alpha >= 64) coveredPixels++;
        if (alpha >= 247) opaquePixels++;
        if (alpha > 8 && alpha < 247) translucentPixels++;
      }
      expect(coveredPixels, greaterThan(0));
      expect(
        opaquePixels / coveredPixels,
        greaterThan(.8),
        reason: 'Refit coverage keeps a solid interior and a fine AA outline',
      );
      final refitMetrics = {
        'chosenAngleRadians': chosenAngle,
        'fittedAngleRadians': manual.angle,
        'centerDisplacementPixels': (manual.center - chosenCenter).distance,
        'label': manual.label,
        'nativeRefitSucceeded': true,
        'coverageChanged': true,
        'coveredPixels': coveredPixels,
        'opaquePixels': opaquePixels,
        'translucentPixels': translucentPixels,
        'opaqueFraction': opaquePixels / coveredPixels,
      };
      await binding.takeScreenshot('manual_nail_refinement');

      // Undo the refit, then the edited contour. Neither step changes rotation.
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      manual = tester.widget<NailScene>(find.byType(NailScene)).nails.last;
      expect(manual.maskRgba, orderedEquals(editedMask));
      expect(manual.angle, chosenAngle);
      expect(manual.center, chosenCenter);
      expect(manual.width, edited.width);
      expect(manual.height, edited.height);
      await tester.tap(find.byTooltip('撤销'));
      await tester.pumpAndSettle();
      manual = tester.widget<NailScene>(find.byType(NailScene)).nails.last;
      expect(manual.maskRgba, orderedEquals(beforeMask));
      expect(manual.angle, chosenAngle);
      expect(manual.center, chosenCenter);
      expect(tester.takeException(), isNull);
      binding.reportData = {
        ...?binding.reportData,
        'diyMetrics': {
          'materials': DiySticker.all.length,
          'baseMotifs': DiyMotif.values.length,
          'categories': DiySticker.categories.length,
          'imageImportCopy': true,
          'positionLockAndScale': true,
          'handDrawingUndoRedo': true,
          'saveReloadEdit': true,
          'deletePreservesSource': true,
          'inlinePreviewRemainsVisible': true,
          'manualFitLabel': manual.label,
          'editableContourAndUndo': true,
          'rotationPreservingNativeRefit': refitMetrics,
          'refitUndoPreservesRotationAndContour': true,
          'device': Platform.operatingSystem,
          'scope': 'Simulator and owned fixtures; no personal photos',
        },
        'exports': {
          'diy_design_example': base64Encode(texture),
          'demo_diy_try_on': base64Encode(png),
          'diy_materials': base64Encode(await _materialSheet()),
        },
      };
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      if (await folder.exists()) await folder.delete(recursive: true);
    }
  });
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  expect(
    condition(),
    isTrue,
    reason: 'The asynchronous DIY action did not finish',
  );
}

Future<Uint8List> _fixtureImage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFC7DDED), BlendMode.src);
  for (var i = -8; i < 16; i++) {
    canvas.drawLine(
      Offset(i * 18.0, 0),
      Offset(i * 18.0 + 120, 180),
      Paint()
        ..color = const Color(0xFF768EBB)
        ..strokeWidth = 5,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(120, 180);
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _materialSheet() async {
  const cellWidth = 144.0, cellHeight = 158.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFFAF5F2), BlendMode.src);
  void label(String text, Offset offset, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: const Color(0xFF5F3D49), fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 138);
    painter.paint(canvas, offset);
    painter.dispose();
  }

  const columns = 8;
  final rows = (DiySticker.all.length + columns - 1) ~/ columns;
  label('DIY素材${DiySticker.all.length}款', const Offset(18, 14), 20);
  for (var i = 0; i < DiySticker.all.length; i++) {
    final sticker = DiySticker.all[i];
    final x = (i % columns) * cellWidth, y = 52 + (i ~/ columns) * cellHeight;
    canvas.save();
    canvas.translate(x + 22, y + 8);
    canvas.clipRect(const Rect.fromLTWH(0, 0, 100, 100));
    paintDiySticker(canvas, sticker);
    canvas.restore();
    label(sticker.name, Offset(x + 5, y + 110), 12);
    label(sticker.category, Offset(x + 5, y + 130), 10);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (columns * cellWidth).round(),
    (52 + rows * cellHeight).round(),
  );
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
