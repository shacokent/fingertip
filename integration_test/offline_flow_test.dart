import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:offline_nail_demo/main.dart' as app;
import 'package:offline_nail_demo/screens/editor_page.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';
import 'package:offline_nail_demo/services/nail_analysis.dart';
import 'package:offline_nail_demo/screens/home_page.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('bundled photo uses real local models and changes styles', (
    tester,
  ) async {
    app.main();
    await tester.pumpAndSettle();
    await precacheImage(
      const AssetImage('assets/branding/logo.jpg'),
      tester.element(find.byType(HomePage)),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('用示例体验'), findsNothing);
    expect(find.text('完全离线'), findsNothing);
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
    }
    await binding.takeScreenshot('nail_home');
    // The sample is a test fixture; it is deliberately absent from the home UI.
    final engine = NailAnalysisEngine();
    final sample = await rootBundle.load('assets/samples/hand.jpg');
    final analysis = await engine.analyze(
      sample.buffer.asUint8List(sample.offsetInBytes, sample.lengthInBytes),
    );
    await engine.close();
    final context = tester.element(find.byType(HomePage));
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => EditorPage(analysis: analysis)),
      ),
    );
    for (var attempt = 0; attempt < 120; attempt++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byType(NailScene).evaluate().isNotEmpty) break;
    }
    expect(find.byType(EditorPage), findsOneWidget);
    expect(find.byType(NailScene), findsOneWidget);
    expect(tester.takeException(), isNull);
    final before = tester.widget<NailScene>(find.byType(NailScene));
    expect(before.nails.length, greaterThanOrEqualTo(3));
    final dir = await getApplicationDocumentsDirectory();
    final originalOut = await before.renderer.export(
      before.nails,
      before.styles,
      before.gloss,
    );
    final originalBytes = await originalOut.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await File(
      '${dir.path}/demo_rose.png',
    ).writeAsBytes(originalBytes!.buffer.asUint8List());
    originalOut.dispose();
    await tester.tap(find.byKey(const ValueKey('inline-style-wine')));
    await tester.pumpAndSettle();
    final after = tester.widget<NailScene>(find.byType(NailScene));
    expect(after.styles.values.every((s) => s.id == 'wine'), isTrue);
    final wineOut = await after.renderer.export(
      after.nails,
      after.styles,
      after.gloss,
    );
    final wineBytes = await wineOut.toByteData(format: ui.ImageByteFormat.png);
    expect(
      wineBytes!.buffer.asUint8List(),
      isNot(orderedEquals(originalBytes.buffer.asUint8List())),
    );
    await File(
      '${dir.path}/demo_wine.png',
    ).writeAsBytes(wineBytes.buffer.asUint8List());
    wineOut.dispose();
    final screenshot = await binding.takeScreenshot('nail_editor');
    await File('${dir.path}/preview_editor.png').writeAsBytes(screenshot);
    binding.reportData = {
      ...?binding.reportData,
      'exports': {
        'demo_rose': base64Encode(originalBytes.buffer.asUint8List()),
        'demo_wine': base64Encode(wineBytes.buffer.asUint8List()),
      },
      'metrics': {
        'recognizedNails': before.nails.length,
        'localHandLocatorAvailable': tester
            .widget<EditorPage>(find.byType(EditorPage))
            .analysis
            .handAvailable,
        'analysisMilliseconds': tester
            .widget<EditorPage>(find.byType(EditorPage))
            .analysis
            .elapsed
            .inMilliseconds,
        'model': 'bundled ONNX, 128x128 RGB NCHW, 0/180 ensemble',
        'device': Platform.operatingSystem,
      },
    };
    // Capture is not exercised here: real hardware and camera permissions are
    // covered by the documented device checklist.
    await tester.tap(find.byTooltip('微调甲面'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加手动甲面'));
    await tester.pumpAndSettle();
    final sceneRect = tester.getRect(find.byType(NailScene));
    await tester.tapAt(sceneRect.center);
    await tester.pumpAndSettle();
    final edited = tester.widget<NailScene>(find.byType(NailScene));
    expect(edited.nails.length, before.nails.length + 1);
    expect(edited.nails.where((n) => n.isManual).length, 1);
    expect(tester.takeException(), isNull);
  });
}
