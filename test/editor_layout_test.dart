import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/screens/editor_page.dart';
import 'package:offline_nail_demo/screens/diy_studio_page.dart';
import 'package:offline_nail_demo/services/diy_library.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';
import 'package:offline_nail_demo/widgets/inline_style_browser.dart';
import 'package:offline_nail_demo/widgets/photo_viewport.dart';

void main() {
  late Directory temporary;
  late DiyLibrary library;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('inline_editor_test_');
    library = DiyLibrary(directory: Directory('${temporary.path}/library'));
  });
  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  testWidgets('original preview ends when the held pointer lifts or cancels', (
    tester,
  ) async {
    await _open(tester, library);
    final control = find.text('按住看原图');
    final originalLabel = find.text('原始照片');

    final held = await tester.startGesture(tester.getCenter(control));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_scene(tester).original, isTrue);
    expect(originalLabel, findsOneWidget);
    await held.up();
    await tester.pump();
    expect(_scene(tester).original, isFalse);
    expect(originalLabel, findsNothing);

    final dragged = await tester.startGesture(tester.getCenter(control));
    await tester.pump(const Duration(milliseconds: 250));
    await dragged.moveTo(tester.getTopLeft(find.byType(PhotoViewport)));
    await tester.pump();
    expect(_scene(tester).original, isTrue);
    await dragged.up();
    await tester.pump();
    expect(_scene(tester).original, isFalse);

    final cancelled = await tester.startGesture(tester.getCenter(control));
    await tester.pump(const Duration(milliseconds: 250));
    expect(_scene(tester).original, isTrue);
    await cancelled.cancel();
    await tester.pump();
    expect(_scene(tester).original, isFalse);
    await _close(tester);
  });

  testWidgets(
    'three same-photo plans retain independent edits and share geometry',
    (tester) async {
      await _open(tester, library, twoNails: true);
      final plan1 = _scene(tester);

      Future<void> tap(String key) =>
          _tapVisible(tester, find.byKey(ValueKey(key)));

      Future<void> changeSlider(String key, double position) async {
        final target = find.byKey(ValueKey(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        final track = tester.getRect(target);
        await tester.tapAt(
          Offset(track.left + track.width * position, track.center.dy),
        );
        await tester.pumpAndSettle();
      }

      void expectPlan(int id, NailScene expected) {
        final chip = tester.widget<ChoiceChip>(
          find.byKey(ValueKey('nail-plan-$id')),
        );
        final actual = _scene(tester);
        expect(chip.selected, isTrue);
        expect(actual.styles, expected.styles);
        expect(actual.coatAmounts, expected.coatAmounts);
        expect(actual.gloss, expected.gloss);
        expect(actual.lightDirection, expected.lightDirection);
        expect(actual.nails, orderedEquals(plan1.nails));
      }

      await tap('nail-plan-add');
      expectPlan(2, plan1);
      await tap('inline-style-wine');
      await _until(
        tester,
        () => _scene(tester).styles.values.every((s) => s.id == 'wine'),
      );
      await tap('nail-tool-finish');
      await changeSlider('nail-coat-amount', .25);
      await changeSlider('nail-gloss', .82);
      await changeSlider('light-direction', .7);
      final plan2 = _scene(tester);
      expect(plan2.coatAmounts.values, everyElement(lessThan(1)));
      expect(plan2.gloss, isNot(plan1.gloss));
      expect(plan2.lightDirection, isNot(plan1.lightDirection));

      await tap('nail-plan-add');
      expectPlan(3, plan2);
      await tap('nail-tool-styles');
      await tester.tap(find.byType(NailScene));
      await tester.pumpAndSettle();
      expect(_scene(tester).selectedId, 0);
      await tap('inline-style-rose');
      await _until(tester, () => _scene(tester).styles[0]?.id == 'rose');
      await tap('nail-tool-finish');
      await changeSlider('nail-coat-amount', .75);
      await changeSlider('nail-gloss', .36);
      await changeSlider('light-direction', .18);
      final plan3 = _scene(tester);
      expect(plan3.styles[1]?.id, 'wine');
      expect(plan3.coatAmounts[0], greaterThan(1));
      expect(plan3.coatAmounts[1], plan2.coatAmounts[1]);
      expect(plan3.gloss, isNot(plan2.gloss));
      expect(plan3.lightDirection, isNot(plan2.lightDirection));

      final viewport = tester.widget<PhotoViewport>(find.byType(PhotoViewport));
      viewport.controller.value = Matrix4.identity()
        ..translateByDouble(12, -6, 0, 1)
        ..scaleByDouble(1.2, 1.2, 1, 1);
      final photoTransform = Matrix4.copy(viewport.controller.value);
      await tester.pump();
      final photoRect = tester.getRect(find.byType(NailScene));
      for (final (id, expected) in [(1, plan1), (2, plan2), (3, plan3)]) {
        await tap('nail-plan-$id');
        expectPlan(id, expected);
        expect(_scene(tester).nails, same(plan1.nails));
        expect(tester.getRect(find.byType(NailScene)), photoRect);
        expect(
          viewport.controller.value.storage,
          orderedEquals(photoTransform.storage),
        );
        expect(find.byType(BottomSheet), findsNothing);
        expect(find.byType(Dialog), findsNothing);
      }

      await tap('nail-plan-menu');
      await tap('nail-plan-rename');
      await tester.enterText(
        find.byKey(const ValueKey('nail-plan-name')),
        '单指玫瑰',
      );
      await _tapVisible(tester, find.widgetWithText(TextButton, '确定'));
      expect(find.text('单指玫瑰'), findsOneWidget);

      await tap('nail-plan-menu');
      await tap('nail-plan-delete');
      expect(find.byKey(const ValueKey('nail-plan-3')), findsNothing);
      expectPlan(2, plan2);
      await _tapVisible(tester, find.byTooltip('撤销'));
      await _until(
        tester,
        () => find.byKey(const ValueKey('nail-plan-3')).evaluate().isNotEmpty,
      );
      expect(find.text('单指玫瑰'), findsOneWidget);
      expectPlan(3, plan3);
      expect(
        viewport.controller.value.storage,
        orderedEquals(photoTransform.storage),
      );
      expect(tester.takeException(), isNull);
      await _close(tester);
    },
  );

  testWidgets('preview hides recognition marks and keeps manual edge review', (
    tester,
  ) async {
    await _open(
      tester,
      library,
      twoNails: true,
      edgeReview: const {0: NailEdgeReviewReason.photoEdge},
    );
    final nail = _scene(tester).nails.first;
    final contourPoint = find.byKey(const ValueKey('contour-point-0'));
    final confirm = find.byKey(const ValueKey('nail-edge-confirm'));
    expect(find.textContaining('识别到'), findsNothing);
    expect(find.textContaining('甲缘待确认'), findsNothing);
    expect(find.textContaining(nail.label), findsNothing);
    expect(find.text('0.1s'), findsNothing);
    expect(_scene(tester).outlines, isFalse);

    await tester.tap(find.byType(NailScene));
    await tester.pumpAndSettle();
    expect(_scene(tester).selectedId, nail.id);
    expect(_scene(tester).outlines, isFalse);
    expect(contourPoint, findsNothing);
    expect(confirm, findsNothing);

    Future<void> openRefine() async {
      final adjust = find.byTooltip('微调甲面');
      await tester.ensureVisible(adjust);
      await tester.pumpAndSettle();
      await tester.tap(adjust);
      await tester.pumpAndSettle();
      final refine = find.byKey(const ValueKey('refine-nail-contour'));
      await tester.ensureVisible(refine);
      await tester.pumpAndSettle();
      await tester.tap(refine);
      await tester.pumpAndSettle();
    }

    await openRefine();
    expect(find.textContaining(nail.label), findsNothing);
    expect(contourPoint, findsOneWidget);
    expect(confirm, findsOneWidget);
    await tester.tap(find.byTooltip('放大修边'));
    await tester.pumpAndSettle();
    final viewport = tester.widget<PhotoViewport>(find.byType(PhotoViewport));
    expect(viewport.controller.value.getMaxScaleOnAxis(), greaterThan(1.4));

    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(contourPoint, findsNothing);
    expect(_scene(tester).outlines, isFalse);
    expect(_scene(tester).nails.first, same(nail));
    expect(viewport.controller.value.getMaxScaleOnAxis(), 1);

    await tester.tap(find.byTooltip('撤销'));
    await _until(
      tester,
      () => !tester
          .widget<AbsorbPointer>(
            find.byKey(const ValueKey('editor-operation-lock')),
          )
          .absorbing,
    );
    await openRefine();
    expect(confirm, findsOneWidget);
    await _close(tester);
  });

  testWidgets('coat slider updates whole hand and one nail, with undo', (
    tester,
  ) async {
    await _open(tester, library, twoNails: true);
    await _tapVisible(tester, find.byKey(const ValueKey('nail-tool-finish')));
    final coat = find.byKey(const ValueKey('nail-coat-amount'));
    await tester.ensureVisible(coat);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(coat).value, defaultNailCoatAmount);
    final track = tester.getRect(coat);
    await tester.tapAt(Offset(track.left + track.width * .24, track.center.dy));
    await tester.pump();
    final thin = tester.widget<Slider>(coat).value;
    expect(thin, lessThan(defaultNailCoatAmount));
    expect(_scene(tester).coatAmounts, {0: thin, 1: thin});

    await tester.tapAt(tester.getCenter(find.byType(NailScene)));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '单指')).selected,
      isTrue,
    );
    await tester.tapAt(Offset(track.left + track.width * .76, track.center.dy));
    await tester.pump();
    final thick = tester.widget<Slider>(coat).value;
    expect(thick, greaterThan(defaultNailCoatAmount));
    expect(_scene(tester).coatAmounts, {0: thick, 1: thin});

    await tester.tap(find.byTooltip('撤销'));
    await _until(tester, () => _scene(tester).coatAmounts[0] == thin);
    expect(_scene(tester).coatAmounts, {0: thin, 1: thin});
    expect(tester.widget<Slider>(coat).value, thin);
    await _close(tester);
  });

  testWidgets(
    'inline style choice keeps photo visible on narrow and short screens',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await _open(tester, library, textScale: 1.3);
      expect(tester.takeException(), isNull);
      expect(find.byType(InlineStyleBrowser), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('inline-style-wine')),
      );
      await tester.tap(find.byKey(const ValueKey('inline-style-wine')));
      await _until(
        tester,
        () => _scene(tester).styles.values.every((s) => s.id == 'wine'),
      );
      expect(tester.getSize(find.byType(NailScene)).height, greaterThan(100));
      expect(find.byType(BottomSheet), findsNothing);

      final scene = find.byType(NailScene);
      final photoBeforePlans = tester.getRect(scene);
      final addPlan = find.byKey(const ValueKey('nail-plan-add'));
      for (var i = 0; i < 5; i++) {
        await _tapVisible(tester, addPlan);
      }
      expect(
        find.byKey(const ValueKey('nail-plan-6')).hitTestable(),
        findsOneWidget,
      );
      await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-1')));
      expect(tester.getRect(scene), photoBeforePlans);
      await _tapVisible(tester, find.byKey(const ValueKey('nail-tool-finish')));
      expect(tester.getRect(scene), photoBeforePlans);
      final coat = find.byKey(const ValueKey('nail-coat-amount'));
      await tester.ensureVisible(coat);
      await tester.pumpAndSettle();
      final photoBeforeAdjustment = tester.getRect(find.byType(NailScene));
      await tester.tapAt(tester.getCenter(coat) + const Offset(-45, 0));
      await tester.pump();
      expect(
        tester.widget<Slider>(coat).value,
        lessThan(defaultNailCoatAmount),
      );
      expect(tester.getRect(find.byType(NailScene)), photoBeforeAdjustment);
      expect(
        photoBeforeAdjustment.overlaps(Offset.zero & tester.view.physicalSize),
        isTrue,
      );

      tester.view.physicalSize = const Size(640, 320);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('editor-compact-scroll')),
        findsOneWidget,
      );
      expect(tester.getSize(find.byType(NailScene)).height, greaterThan(100));
      final landscapePhoto = tester.getRect(scene);
      await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-6')));
      await _tapVisible(tester, find.byKey(const ValueKey('nail-tool-styles')));
      expect(tester.getRect(scene), landscapePhoto);
      await tester.ensureVisible(
        find.byKey(const ValueKey('inline-style-rose')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inline-style-rose')));
      await _until(
        tester,
        () => _scene(tester).styles.values.every((s) => s.id == 'rose'),
      );
      final photoRect = tester.getRect(find.byType(NailScene));
      expect(
        photoRect.overlaps(Offset.zero & tester.view.physicalSize),
        isTrue,
      );
      expect(find.byType(BottomSheet), findsNothing);
      await _close(tester);
    },
  );

  testWidgets(
    'dragged contour updates mask and undo restores the previous edge',
    (tester) async {
      await _open(tester, library);
      await tester.tapAt(tester.getCenter(find.byType(NailScene)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('微调甲面'));
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('refine-nail-contour')),
      );
      await tester.tap(find.byTooltip('放大修边'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('contour-point-2')), findsOneWidget);
      final before = List<int>.from(_scene(tester).nails.single.maskRgba);
      await tester.drag(
        find.byKey(const ValueKey('contour-point-2')),
        const Offset(45, 0),
      );
      await _until(
        tester,
        () => !_same(before, _scene(tester).nails.single.maskRgba),
      );
      await tester.tap(find.byTooltip('撤销'));
      await _until(
        tester,
        () => _same(before, _scene(tester).nails.single.maskRgba),
      );
      expect(tester.takeException(), isNull);
      await _close(tester);
    },
  );

  testWidgets(
    'rotated preview keeps photo coordinates and contour handles follow the finger',
    (tester) async {
      await _open(tester, library);
      final original = _scene(tester).nails.single;
      var viewport = tester.widget<PhotoViewport>(find.byType(PhotoViewport));
      var rect = tester.getRect(find.byType(PhotoViewport));
      viewport.controller.value = _viewAround(
        rect.size.center(Offset.zero),
        .6,
        1.4,
      );
      await tester.pump();
      final displayed = MatrixUtils.transformPoint(
        viewport.controller.value,
        rect.size.center(Offset.zero),
      );
      await tester.tapAt(rect.topLeft + displayed);
      await tester.pumpAndSettle();
      expect(_scene(tester).selectedId, original.id);
      expect(_scene(tester).nails.single.center, original.center);
      expect(_scene(tester).nails.single.angle, original.angle);
      expect(
        _scene(tester).nails.single.maskRgba,
        orderedEquals(original.maskRgba),
      );

      await tester.tap(find.byTooltip('微调甲面'));
      await tester.pumpAndSettle();
      await _tapVisible(
        tester,
        find.byKey(const ValueKey('refine-nail-contour')),
      );
      viewport = tester.widget<PhotoViewport>(find.byType(PhotoViewport));
      rect = tester.getRect(find.byType(PhotoViewport));
      viewport.controller.value = _viewAround(
        rect.size.center(Offset.zero),
        math.pi / 2,
        1.2,
      );
      await tester.pump();
      final point = find.byKey(const ValueKey('contour-point-2'));
      final beforePosition = tester.getCenter(point);
      final beforeMask = List<int>.of(_scene(tester).nails.single.maskRgba);
      final view = viewport.controller.value.clone();
      await tester.drag(point, const Offset(-60, 0));
      await _until(
        tester,
        () => !_same(beforeMask, _scene(tester).nails.single.maskRgba),
      );
      final movement = tester.getCenter(point) - beforePosition;
      expect(movement.dx, lessThan(-10));
      expect(movement.dy.abs(), lessThan(2));
      expect(viewport.controller.value.storage, orderedEquals(view.storage));
      await tester.tap(find.byTooltip('撤销'));
      await _until(
        tester,
        () => _same(beforeMask, _scene(tester).nails.single.maskRgba),
      );
      expect(viewport.controller.value.storage, orderedEquals(view.storage));
      await tester.tap(find.byKey(const ValueKey('reset-photo-view')));
      await tester.pump();
      expect(
        viewport.controller.value.storage,
        orderedEquals(Matrix4.identity().storage),
      );
      expect(tester.takeException(), isNull);
      await _close(tester);
    },
  );

  testWidgets(
    'supplementing and deleting a nail shares photo geometry across plans',
    (tester) async {
      await _open(tester, library);
      await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-add')));
      await _tapVisible(tester, find.byKey(const ValueKey('nail-tool-edges')));
      await _tapVisible(tester, find.widgetWithText(TextButton, '补选'));
      final viewport = tester.widget<PhotoViewport>(find.byType(PhotoViewport));
      final rect = tester.getRect(find.byType(PhotoViewport));
      viewport.controller.value = _viewAround(
        rect.size.center(Offset.zero),
        .8,
        1.3,
      );
      await tester.pump();
      final fitted = applyBoxFit(
        BoxFit.contain,
        const Size(64, 96),
        rect.size,
      ).destination;
      final origin = Offset(
        (rect.width - fitted.width) / 2,
        (rect.height - fitted.height) / 2,
      );
      const photoPoint = Offset(22, 38);
      final displayed = MatrixUtils.transformPoint(
        viewport.controller.value,
        origin + photoPoint * (fitted.width / 64),
      );
      await tester.tapAt(rect.topLeft + displayed);
      await _until(tester, () => _scene(tester).nails.length == 2);
      final added = _scene(tester).nails.last;
      expect(added.center.dx, closeTo(photoPoint.dx, .001));
      expect(added.center.dy, closeTo(photoPoint.dy, .001));
      expect(added.isManual, isTrue);
      expect(_scene(tester).nails.first.center, const Offset(32, 48));
      await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-1')));
      expect(_scene(tester).nails.last, same(added));
      expect(_scene(tester).styles[added.id], isNotNull);
      await _tapVisible(tester, find.widgetWithText(TextButton, '删除'));
      await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-2')));
      expect(_scene(tester).nails, hasLength(1));
      expect(_scene(tester).styles, isNot(contains(added.id)));
      await _tapVisible(tester, find.byTooltip('撤销'));
      await _until(tester, () => _scene(tester).nails.length == 2);
      await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-2')));
      expect(_scene(tester).nails.last, same(added));
      expect(_scene(tester).styles[added.id], isNotNull);
      expect(tester.takeException(), isNull);
      await _close(tester);
    },
  );

  testWidgets(
    'deleting an imported DIY style replaces it in all same-photo plans',
    (tester) async {
      final source = File('${temporary.path}/user-photo.png');
      final motif = img.Image(width: 16, height: 24);
      img.fill(motif, color: img.ColorRgb8(96, 72, 176));
      img.fillRect(
        motif,
        x1: 3,
        y1: 5,
        x2: 13,
        y2: 15,
        color: img.ColorRgb8(245, 201, 94),
      );
      await tester.runAsync(() => source.writeAsBytes(img.encodePng(motif)));
      await _open(tester, library, pickImage: () async => source.path);
      await tester.tap(find.byKey(const ValueKey('create-diy-style')));
      await tester.pumpAndSettle();
      expect(find.byType(DiyStudioPage), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('diy-style-name')),
        '我的图片款',
      );
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
      await tester.tap(find.byKey(const ValueKey('diy-save')));
      await _until(
        tester,
        () =>
            find.byType(DiyStudioPage).evaluate().isEmpty &&
            find.byType(NailScene).evaluate().isNotEmpty &&
            _scene(tester).styles.values.every((s) => s.isCustom),
      );
      final style = _scene(tester).styles.values.single;
      expect(style.texturePath, isNotNull);
      expect(
        await tester.runAsync(() => File(style.texturePath!).exists()),
        isTrue,
      );
      expect(find.byType(BottomSheet), findsNothing);
      for (var i = 0; i < 2; i++) {
        await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-add')));
      }
      await _tapVisible(tester, find.byKey(const ValueKey('nail-plan-1')));
      await _tapVisible(
        tester,
        find.byKey(ValueKey('custom-style-menu-${style.id}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除款式'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await _until(
        tester,
        () => _scene(tester).styles.values.every((s) => !s.isCustom),
      );
      for (final id in [2, 3]) {
        await _tapVisible(tester, find.byKey(ValueKey('nail-plan-$id')));
        expect(_scene(tester).styles.values, everyElement(isNot(same(style))));
        expect(_scene(tester).styles.values.every((s) => !s.isCustom), isTrue);
      }
      expect((await tester.runAsync(library.load))!, isEmpty);
      expect(await tester.runAsync(source.exists), isTrue);
      expect(tester.takeException(), isNull);
      await _close(tester);
    },
  );

  testWidgets(
    'refitting keeps the user rotation and undo restores the prior mask',
    (tester) async {
      var calls = 0;
      await _open(
        tester,
        library,
        refit: (current) async {
          calls++;
          expect(current.angle, 1.17);
          final candidate = NailRegion.manual(
            90,
            current.center,
            64,
          ).copyWith(width: 18, height: 27, angle: -.36);
          return NailRegion(
            id: candidate.id,
            label: '局部贴合',
            center: candidate.center,
            width: candidate.width,
            height: candidate.height,
            angle: candidate.angle,
            maskRgba: candidate.maskRgba,
            isManual: true,
          );
        },
      );
      await tester.tapAt(tester.getCenter(find.byType(NailScene)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('微调甲面'));
      await tester.pumpAndSettle();
      final rotation = tester.widget<Slider>(
        find.byKey(const ValueKey('nail-adjust-旋转')),
      );
      rotation.onChangeStart?.call(rotation.value);
      rotation.onChanged!(1.17);
      await tester.pump();
      final previous = _scene(tester).nails.single;
      final previousMask = List<int>.of(previous.maskRgba);
      await _tapVisible(tester, find.byKey(const ValueKey('refit-nail')));
      await _until(
        tester,
        () =>
            calls == 1 &&
            _scene(tester).nails.single.angle == 1.17 &&
            !_same(previousMask, _scene(tester).nails.single.maskRgba) &&
            tester
                    .widget<IconButton>(
                      find.byWidgetPredicate(
                        (widget) =>
                            widget is IconButton && widget.tooltip == '撤销',
                      ),
                    )
                    .onPressed !=
                null,
      );
      final fitted = _scene(tester).nails.single;
      expect(fitted.angle, 1.17);
      expect(fitted.center, previous.center);
      expect(fitted.id, previous.id);
      await tester.tap(find.byTooltip('撤销'));
      await _until(
        tester,
        () => _same(previousMask, _scene(tester).nails.single.maskRgba),
      );
      expect(_scene(tester).nails.single.angle, 1.17);
      await _close(tester);
    },
  );

  testWidgets(
    'failed refitting leaves the existing rotation and contour intact',
    (tester) async {
      var calls = 0;
      await _open(
        tester,
        library,
        refit: (current) async {
          calls++;
          return NailRegion.manual(current.id, current.center, 64);
        },
      );
      await tester.tapAt(tester.getCenter(find.byType(NailScene)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('微调甲面'));
      await tester.pumpAndSettle();
      tester
          .widget<Slider>(find.byKey(const ValueKey('nail-adjust-旋转')))
          .onChanged!(-2.3);
      await tester.pump();
      final previous = _scene(tester).nails.single;
      final mask = List<int>.of(previous.maskRgba);
      await _tapVisible(tester, find.byKey(const ValueKey('refit-nail')));
      await _until(tester, () => calls == 1);
      await _ticks(tester, 4);
      expect(_scene(tester).nails.single.angle, -2.3);
      expect(_scene(tester).nails.single.maskRgba, orderedEquals(mask));
      expect(find.textContaining('已保留当前角度和轮廓'), findsOneWidget);
      await _close(tester);
    },
  );
}

AnalysisResult _analysis({
  bool twoNails = false,
  Map<int, NailEdgeReviewReason> edgeReview = const {},
}) {
  final photo = img.Image(width: 64, height: 96);
  img.fill(photo, color: img.ColorRgb8(219, 175, 150));
  return AnalysisResult(
    imagePath: '/test/manual-hand.png',
    pngBytes: img.encodePng(photo),
    width: 64,
    height: 96,
    nails: [
      NailRegion(
        id: 0,
        label: '左手拇指',
        center: const Offset(32, 48),
        width: 22,
        height: 34,
        angle: 0,
        maskRgba: NailRegion.manual(0, const Offset(32, 48), 64).maskRgba,
      ),
      if (twoNails)
        NailRegion.manual(
          1,
          const Offset(53, 64),
          64,
        ).copyWith(width: 16, height: 27),
    ],
    elapsed: const Duration(milliseconds: 50),
    handAvailable: false,
    edgeReviewById: edgeReview,
  );
}

Future<void> _open(
  WidgetTester tester,
  DiyLibrary library, {
  double textScale = 1,
  bool twoNails = false,
  Map<int, NailEdgeReviewReason> edgeReview = const {},
  Future<String?> Function()? pickImage,
  Future<NailRegion> Function(NailRegion current)? refit,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: EditorPage(
        analysis: _analysis(twoNails: twoNails, edgeReview: edgeReview),
        library: library,
        diyImagePicker: pickImage,
        refitNail: refit,
      ),
    ),
  );
  await _until(tester, () => find.byType(NailScene).evaluate().isNotEmpty);
  await _ticks(tester, 3);
}

Future<void> _tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

NailScene _scene(WidgetTester tester) =>
    tester.widget<NailScene>(find.byType(NailScene));
Matrix4 _viewAround(Offset center, double rotation, double scale) =>
    Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..rotateZ(rotation)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
bool _same(List<int> a, List<int> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

Future<void> _ticks(WidgetTester tester, int count) async {
  for (var i = 0; i < count; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 15));
  }
}

Future<void> _until(WidgetTester tester, bool Function() predicate) async {
  for (var i = 0; i < 160; i++) {
    if (predicate()) return;
    await _ticks(tester, 1);
  }
  debugPrint(
    tester.allWidgets
        .whereType<Text>()
        .map((w) => w.data)
        .whereType<String>()
        .join(' | '),
  );
  expect(
    predicate(),
    isTrue,
    reason: 'Editor did not reach the expected state',
  );
}

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
  await _ticks(tester, 2);
}
