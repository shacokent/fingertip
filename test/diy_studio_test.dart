import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/screens/diy_studio_page.dart';
import 'package:offline_nail_demo/services/diy_library.dart';
import 'package:offline_nail_demo/widgets/diy_canvas.dart';

void main() {
  testWidgets(
    'locking fixes position while zoom stays editable and drawing can be undone',
    (tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('diy-ui-'),
      ))!;
      final library = DiyLibrary(directory: directory);
      await tester.pumpWidget(
        MaterialApp(home: DiyStudioPage(library: library)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diy-sticker-butterfly_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diy-lock-layer')));
      await tester.pumpAndSettle();
      final before = tester
          .widget<DiyCanvas>(find.byType(DiyCanvas))
          .design
          .layers
          .single;
      expect(before.locked, isTrue);
      await tester.drag(find.byType(DiyCanvas), const Offset(25, 18));
      await tester.pumpAndSettle();
      var layer = tester
          .widget<DiyCanvas>(find.byType(DiyCanvas))
          .design
          .layers
          .single;
      expect(layer.x, before.x);
      expect(layer.y, before.y);
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('diy-layer-scale')),
      );
      expect(slider.onChanged, isNotNull);
      slider.onChangeStart!(slider.value);
      slider.onChanged!(1.8);
      await tester.pumpAndSettle();
      layer = tester
          .widget<DiyCanvas>(find.byType(DiyCanvas))
          .design
          .layers
          .single;
      expect(layer.scale, 1.8);
      expect(layer.x, before.x);
      // Name edits are independent of the drawing/transform undo history.
      // Some snapshots above intentionally predate this name change.
      await tester.enterText(
        find.byKey(const ValueKey('diy-style-name')),
        '蓝蝶手绘',
      );
      tester.binding.focusManager.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('diy-draw-tool')));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(DiyCanvas), const Offset(50, 0));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DiyCanvas>(find.byType(DiyCanvas)).design.layers.length,
        2,
      );
      await tester.tap(find.byTooltip('撤销设计'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<DiyCanvas>(find.byType(DiyCanvas)).design.layers.length,
        1,
      );
      void expectCustomName() {
        final nameField = tester.widget<TextField>(
          find.byKey(const ValueKey('diy-style-name')),
        );
        expect(nameField.controller!.text, '蓝蝶手绘');
        expect(
          tester.widget<DiyCanvas>(find.byType(DiyCanvas)).design.name,
          '蓝蝶手绘',
        );
      }

      expectCustomName();
      // Undo into a snapshot created before naming; redo the transform and pen.
      await tester.tap(find.byTooltip('撤销设计'));
      await tester.pumpAndSettle();
      expectCustomName();
      await tester.tap(find.byTooltip('重做设计'));
      await tester.pumpAndSettle();
      expectCustomName();
      await tester.tap(find.byTooltip('重做设计'));
      await tester.pumpAndSettle();
      expectCustomName();
      expect(
        tester.widget<DiyCanvas>(find.byType(DiyCanvas)).design.layers.length,
        2,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (await directory.exists()) await directory.delete(recursive: true);
      });
    },
  );

  testWidgets('DIY tools remain reachable on a small enlarged-text viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('diy-layout-'),
    ))!;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: DiyStudioPage(library: DiyLibrary(directory: directory)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(
      find.byKey(const ValueKey('diy-sticker-butterfly_0')),
    );
    await tester.tap(find.byKey(const ValueKey('diy-sticker-butterfly_0')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (await directory.exists()) await directory.delete(recursive: true);
    });
  });
}
