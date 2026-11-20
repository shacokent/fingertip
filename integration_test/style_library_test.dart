import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_nail_demo/main.dart' as app;
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/screens/editor_page.dart';
import 'package:offline_nail_demo/screens/home_page.dart';
import 'package:offline_nail_demo/services/nail_analysis.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('categorized library applies and exports real patterned styles', (
    tester,
  ) async {
    app.main();
    await tester.pumpAndSettle();
    final catalogSheet = await _renderCatalog();
    final engine = NailAnalysisEngine();
    final fixture = await rootBundle.load('assets/samples/hand.jpg');
    final analysis = await engine.analyze(fixture.buffer.asUint8List());
    await engine.close();
    unawaited(
      Navigator.of(tester.element(find.byType(HomePage))).push<void>(
        MaterialPageRoute(builder: (_) => EditorPage(analysis: analysis)),
      ),
    );
    for (var attempt = 0; attempt < 120; attempt++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(NailScene).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    expect(find.byType(NailScene), findsOneWidget);
    final originalScene = tester.widget<NailScene>(find.byType(NailScene));
    expect(originalScene.nails.length, greaterThanOrEqualTo(3));

    final holidayCategory = find.byKey(
      const ValueKey('inline-category-holidayArt'),
    );
    final categories = find.descendant(
      of: find.byKey(const ValueKey('inline-style-categories')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      holidayCategory,
      150,
      scrollable: categories,
    );
    await tester.tap(holidayCategory);
    await tester.pumpAndSettle();
    expect(
      tester.widget<NailScene>(find.byType(NailScene)).styles,
      originalScene.styles,
    );
    await tester.tap(
      find.byKey(const ValueKey('inline-style-holiday_snow_blue')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<NailScene>(find.byType(NailScene))
          .styles
          .values
          .every((style) => style.id == 'holiday_snow_blue'),
      isTrue,
    );
    expect(find.byType(BottomSheet), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('inline-category-botanical')),
      220,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('inline-style-categories')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('inline-category-botanical')));
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
    }
    await binding.takeScreenshot('style_library_botanical');
    final flower = NailStyle.all.firstWhere(
      (style) => style.pattern == NailPattern.flowers,
    );
    expect(find.byType(BottomSheet), findsNothing);
    await tester.tap(find.byKey(ValueKey('inline-style-${flower.id}')));
    await tester.pumpAndSettle();
    final floralScene = tester.widget<NailScene>(find.byType(NailScene));
    expect(floralScene.styles.values.every((s) => s.id == flower.id), isTrue);
    await binding.takeScreenshot('style_applied_flowers');
    final floralImage = await floralScene.renderer.export(
      floralScene.nails,
      floralScene.styles,
      floralScene.gloss,
    );
    final floralPng = (await floralImage.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    floralImage.dispose();

    // Selecting a new design in single-finger mode must leave other nails as-is.
    final target = floralScene.nails.first;
    final sceneRect = tester.getRect(find.byType(NailScene));
    final fitted = applyBoxFit(
      BoxFit.contain,
      Size(analysis.width.toDouble(), analysis.height.toDouble()),
      sceneRect.size,
    ).destination;
    final imageOrigin =
        sceneRect.topLeft +
        Offset(
          (sceneRect.width - fitted.width) / 2,
          (sceneRect.height - fitted.height) / 2,
        );
    await tester.tapAt(
      imageOrigin + target.center * (fitted.width / analysis.width),
    );
    await tester.pumpAndSettle();
    final checker = NailStyle.all.firstWhere(
      (style) => style.pattern == NailPattern.checker,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('inline-category-geometry')),
      200,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('inline-style-categories')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('inline-category-geometry')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(ValueKey('inline-style-${checker.id}')),
      170,
      scrollable: find.descendant(
        of: find.byKey(const ValueKey('inline-style-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(ValueKey('inline-style-${checker.id}')));
    await tester.pumpAndSettle();
    final single = tester.widget<NailScene>(find.byType(NailScene));
    expect(single.styles[target.id]!.id, checker.id);
    expect(
      single.styles.entries
          .where((entry) => entry.key != target.id)
          .every((entry) => entry.value.id == flower.id),
      isTrue,
    );
    await tester.tap(find.byTooltip('撤销'));
    await tester.pumpAndSettle();
    final undone = tester.widget<NailScene>(find.byType(NailScene));
    expect(undone.styles.values.every((s) => s.id == flower.id), isTrue);
    expect(find.text(flower.name), findsWidgets);
    expect(tester.takeException(), isNull);
    binding.reportData = {
      ...?binding.reportData,
      'styleMetrics': {
        'styleCount': NailStyle.all.length,
        'categoryCount': NailCategory.values.length,
        'patternCount': NailPattern.values.length,
        'allStylesRenderedAndUnique': true,
        'inlineCategorySelection': true,
        'noPickerWindowOverPreview': true,
        'wholeHandAndSingleFinger': true,
        'undoRestoresStyle': true,
        'photoFixtureNails': floralScene.nails.length,
        'device': Platform.operatingSystem,
        'scope': 'Simulator and bundled fixture; no private photos',
      },
      'exports': {
        'style_catalog': base64Encode(catalogSheet),
        'demo_flowers': base64Encode(floralPng),
      },
    };
  });
}

Future<Uint8List> _renderCatalog() async {
  final baseRecorder = ui.PictureRecorder();
  Canvas(baseRecorder).drawColor(const Color(0xFFD9B39B), BlendMode.src);
  final basePicture = baseRecorder.endRecording();
  final photo = await basePicture.toImage(64, 96);
  basePicture.dispose();
  final renderer = NailRenderer(
    photo,
    await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
  );
  final nail = NailRegion.manual(
    0,
    const Offset(32, 48),
    64,
  ).copyWith(width: 48, height: 80);
  await renderer.addMask(nail);
  final signatures = <String, String>{};
  final rendered = <ui.Image>[];
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const width = 1566;
  final height = 60 + NailCategory.values.length * 148;
  canvas.drawColor(const Color(0xFFF9F5F2), BlendMode.src);
  void label(
    String text,
    Offset offset,
    double fontSize, {
    double maxWidth = 92,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: const Color(0xFF4D303B), fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, offset);
    painter.dispose();
  }

  label(
    '煜莹 · ${NailStyle.all.length} 款内置美甲',
    const Offset(24, 16),
    23,
    maxWidth: 1500,
  );
  try {
    for (var row = 0; row < NailCategory.values.length; row++) {
      final category = NailCategory.values[row];
      final styles = NailStyle.all
          .where((s) => s.category == category)
          .toList();
      expect(styles, isNotEmpty);
      label(category.label, Offset(18, 60 + row * 148.0 + 43), 17);
      for (var column = 0; column < styles.length; column++) {
        final style = styles[column];
        final image = await renderer.export([nail], {0: style}, .65);
        rendered.add(image);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final signature = base64Encode(bytes);
        expect(
          signatures[signature],
          isNull,
          reason: '${style.id} duplicates ${signatures[signature]} visually',
        );
        signatures[signature] = style.id;
        final x = 126 + column * 96.0, y = 60 + row * 148.0;
        canvas.drawImage(image, Offset(x + 12, y), Paint());
        label(style.name, Offset(x + 1, y + 100), 11);
      }
    }
    expect(signatures, hasLength(NailStyle.all.length));
    final picture = recorder.endRecording();
    final sheet = await picture.toImage(width, height);
    picture.dispose();
    try {
      return (await sheet.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
    } finally {
      sheet.dispose();
    }
  } finally {
    for (final image in rendered) {
      image.dispose();
    }
    renderer.dispose();
  }
}
