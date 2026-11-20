import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
import 'package:offline_nail_demo/widgets/photo_viewport.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native version, directional lamp and view-only photo gestures', (
    tester,
  ) async {
    await tester.pumpWidget(const app.NailStudioApp());
    await _until(
      tester,
      () =>
          find.byKey(const ValueKey('home-app-version')).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    final nativeVersion = await const MethodChannel(
      'offline_nail/app_info',
    ).invokeMethod<String>('getVersion');
    expect(nativeVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(find.text('版本 $nativeVersion'), findsOneWidget);
    await precacheImage(
      const AssetImage('assets/branding/logo.jpg'),
      tester.element(find.byType(HomePage)),
    );
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
    }
    await binding.takeScreenshot('controls_home_version');

    final engine = NailAnalysisEngine();
    final sample = await rootBundle.load('assets/samples/hand.jpg');
    final AnalysisResult analysis;
    try {
      analysis = await engine.analyze(sample.buffer.asUint8List());
    } finally {
      await engine.close();
    }
    expect(analysis.nails.length, greaterThanOrEqualTo(3));
    unawaited(
      Navigator.of(tester.element(find.byType(HomePage))).push<void>(
        MaterialPageRoute(builder: (_) => EditorPage(analysis: analysis)),
      ),
    );
    await _until(tester, () => find.byType(NailScene).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('inline-style-wine')));
    await tester.pumpAndSettle();
    await _tapSlider(tester, 'nail-gloss', 1);
    expect(_scene(tester).gloss, greaterThan(.9));

    await _tapSlider(tester, 'light-direction', 0);
    final leftScene = _scene(tester);
    expect(leftScene.lightDirection, lessThan(-2.8));
    final left = await _export(leftScene);
    await binding.takeScreenshot('controls_light_left');
    await _tapSlider(tester, 'light-direction', .5);
    final rightScene = _scene(tester);
    expect(rightScene.lightDirection.abs(), lessThan(.2));
    final right = await _export(rightScene);
    expect(listEquals(left.pixels, right.pixels), isFalse);
    await binding.takeScreenshot('controls_light_right');

    await tester.tap(find.byTooltip('撤销'));
    await _until(
      tester,
      () =>
          _scene(tester).lightDirection == leftScene.lightDirection &&
          tester
                  .widget<Slider>(find.byKey(const ValueKey('light-direction')))
                  .onChanged !=
              null,
    );
    await tester.pumpAndSettle();
    expect(
      listEquals(left.pixels, (await _export(_scene(tester))).pixels),
      isTrue,
      reason: 'Undo restores both the lamp direction and its rendered result',
    );
    await _tapSlider(tester, 'light-direction', .5);
    expect(_scene(tester).lightDirection, rightScene.lightDirection);
    expect(
      listEquals(right.pixels, (await _export(_scene(tester))).pixels),
      isTrue,
    );

    final originalNails = List<NailRegion>.of(rightScene.nails);
    final originalMasks = [
      for (final nail in originalNails) Uint8List.fromList(nail.maskRgba),
    ];
    final viewport = tester.widget<PhotoViewport>(find.byType(PhotoViewport));
    final viewportRect = tester.getRect(find.byType(PhotoViewport));
    final pictureSize = Size(
      analysis.width.toDouble(),
      analysis.height.toDouble(),
    );
    final fitted = applyBoxFit(
      BoxFit.contain,
      pictureSize,
      viewportRect.size,
    ).destination;
    final origin = Offset(
      (viewportRect.width - fitted.width) / 2,
      (viewportRect.height - fitted.height) / 2,
    );
    final sorted = [...originalNails]
      ..sort(
        (a, b) => (a.center - pictureSize.center(Offset.zero)).distance
            .compareTo((b.center - pictureSize.center(Offset.zero)).distance),
      );
    final target = sorted.first;
    final sceneTarget =
        origin + target.center * (fitted.width / pictureSize.width);
    final focal = viewportRect.topLeft + sceneTarget;
    expect(viewportRect.deflate(35).contains(focal), isTrue);
    final first = await tester.createGesture(pointer: 1);
    final second = await tester.createGesture(pointer: 2);
    await first.down(focal + const Offset(-30, 0));
    await second.down(focal + const Offset(30, 0));
    await tester.pump();
    await first.moveTo(focal + const Offset(-50, -30));
    await second.moveTo(focal + const Offset(50, 30));
    await tester.pump();
    await first.moveTo(focal + const Offset(-65, -55));
    await second.moveTo(focal + const Offset(65, 55));
    await tester.pump();
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    final transformed = viewport.controller.value.clone();
    final zoomedScale = _scale(transformed);
    final rotation = math.atan2(
      transformed.entry(1, 0),
      transformed.entry(0, 0),
    );
    expect(zoomedScale, greaterThan(1.3));
    expect(rotation.abs(), greaterThan(.2));
    _expectSameNails(_scene(tester).nails, originalNails, originalMasks);
    final afterGestures = await _export(_scene(tester));
    expect(
      listEquals(right.pixels, afterGestures.pixels),
      isTrue,
      reason: 'Viewing transforms cannot change a saved photograph',
    );

    final displayedTarget =
        viewportRect.topLeft +
        MatrixUtils.transformPoint(transformed, sceneTarget);
    expect(viewportRect.deflate(20).contains(displayedTarget), isTrue);
    await tester.tapAt(displayedTarget);
    await tester.pumpAndSettle();
    expect(
      _scene(tester).selectedId,
      target.id,
      reason: 'Tap selection applies the full inverse scale and rotation',
    );
    _expectSameNails(_scene(tester).nails, originalNails, originalMasks);
    await binding.takeScreenshot('controls_transformed');

    // A second actual pinch reduces the magnification again.
    final shrinkFirst = await tester.createGesture(pointer: 3);
    final shrinkSecond = await tester.createGesture(pointer: 4);
    await shrinkFirst.down(focal + const Offset(-65, 0));
    await shrinkSecond.down(focal + const Offset(65, 0));
    await tester.pump();
    await shrinkFirst.moveTo(focal + const Offset(-48, -10));
    await shrinkSecond.moveTo(focal + const Offset(48, 10));
    await tester.pump();
    await shrinkFirst.moveTo(focal + const Offset(-25, -8));
    await shrinkSecond.moveTo(focal + const Offset(25, 8));
    await tester.pump();
    await shrinkSecond.up();
    await shrinkFirst.up();
    await tester.pumpAndSettle();
    final reducedScale = _scale(viewport.controller.value);
    expect(reducedScale, lessThan(zoomedScale - .2));
    _expectSameNails(_scene(tester).nails, originalNails, originalMasks);
    await tester.tap(find.byKey(const ValueKey('reset-photo-view')));
    await tester.pumpAndSettle();
    expect(
      viewport.controller.value.storage,
      orderedEquals(Matrix4.identity().storage),
    );
    expect(_scene(tester).lightDirection, rightScene.lightDirection);
    expect(
      listEquals(right.pixels, (await _export(_scene(tester))).pixels),
      isTrue,
    );
    await binding.takeScreenshot('controls_reset');
    expect(tester.takeException(), isNull);

    binding.reportData = {
      ...?binding.reportData,
      'controlsMetrics': {
        'nativeAppVersion': nativeVersion,
        'nativeVersionChannelUsed': true,
        'photoFixture': 'assets/samples/hand.jpg',
        'recognizedNails': analysis.nails.length,
        'leftLampRadians': leftScene.lightDirection,
        'rightLampRadians': rightScene.lightDirection,
        'lampChangesExportPixels': true,
        'lampUndoRestoresDirectionAndPixels': true,
        'viewScaleAfterPinch': zoomedScale,
        'viewRotationRadians': rotation,
        'viewScaleAfterReduction': reducedScale,
        'nailGeometryAndMasksUnchanged': true,
        'exportPixelsUnchangedAfterViewGestures': true,
        'transformedTapSelectedId': target.id,
        'resetReturnsIdentity': true,
        'resetKeepsLampAndExport': true,
        'platform': Platform.operatingSystem,
        'scope':
            'Native simulator and bundled fixture; no private photos or real camera',
      },
      'exports': {
        'demo_lamp_left': base64Encode(left.png),
        'demo_lamp_right': base64Encode(right.png),
      },
    };
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

NailScene _scene(WidgetTester tester) =>
    tester.widget<NailScene>(find.byType(NailScene));

double _scale(Matrix4 matrix) => math.sqrt(
  math.pow(matrix.entry(0, 0), 2) + math.pow(matrix.entry(1, 0), 2),
);

Future<void> _tapSlider(
  WidgetTester tester,
  String key,
  double fraction,
) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  final rect = tester.getRect(finder);
  await tester.tapAt(
    Offset(rect.left + 12 + (rect.width - 24) * fraction, rect.center.dy),
  );
  await tester.pumpAndSettle();
}

void _expectSameNails(
  List<NailRegion> actual,
  List<NailRegion> expected,
  List<Uint8List> masks,
) {
  expect(actual.length, expected.length);
  for (var index = 0; index < actual.length; index++) {
    final a = actual[index], b = expected[index];
    expect(
      [a.id, a.center, a.width, a.height, a.angle, a.enabled],
      [b.id, b.center, b.width, b.height, b.angle, b.enabled],
    );
    expect(
      listEquals(a.maskRgba, masks[index]),
      isTrue,
      reason: 'View gestures leave nail ${a.id} coverage untouched',
    );
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 150; attempt++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  expect(
    ready(),
    isTrue,
    reason: 'Native version or editor did not become ready',
  );
}

Future<({Uint8List pixels, Uint8List png})> _export(NailScene scene) async {
  final image = await scene.renderer.export(
    scene.nails,
    scene.styles,
    scene.gloss,
    lightDirection: scene.lightDirection,
  );
  try {
    return (
      pixels: (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List(),
      png: (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List(),
    );
  } finally {
    image.dispose();
  }
}
