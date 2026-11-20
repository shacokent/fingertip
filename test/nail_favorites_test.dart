import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/diy_models.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_favorites.dart';
import 'package:offline_nail_demo/widgets/inline_style_browser.dart';

void main() {
  late Directory temporary;
  late File file;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('nail_favorites_test_');
    file = File('${temporary.path}/favorites.json');
  });

  tearDown(() async => temporary.delete(recursive: true));

  test(
    'concurrent edits are durable and a failed write does not block later edits',
    () async {
      final favorites = NailFavorites(file: file);
      expect(await favorites.load(), isEmpty);
      await Future.wait([
        favorites.setFavorite('wine', true),
        favorites.setFavorite('custom_1_1', true),
        favorites.setFavorite('wine', true),
      ]);
      expect(await NailFavorites(file: file).load(), {'wine', 'custom_1_1'});

      final contents = await file.readAsString();
      await file.writeAsString('invalid');
      await expectLater(
        favorites.setFavorite('rose', true),
        throwsFormatException,
      );
      expect(await file.readAsString(), 'invalid');

      await file.writeAsString(contents);
      await favorites.setFavorite('wine', false);
      expect(await NailFavorites(file: file).load(), {'custom_1_1'});
    },
  );

  testWidgets(
    'favorite list survives a new browser and resolves the current DIY revision',
    (tester) async {
      final wine = NailStyle.byId('wine')!;
      final rose = NailStyle.byId('rose')!;
      const diyId = 'custom_1_1';
      DiySavedStyle revision(String name, String id) => DiySavedStyle(
        id: diyId,
        style: NailStyle(
          diyId,
          name,
          '',
          Colors.pink,
          NailPattern.solid,
          texturePath: '${temporary.path}/$id.png',
        ),
        design: DiyNailDesign(name: name),
        updatedAt: DateTime.now(),
      );

      final original = revision('自建原版', 'rev1');
      var custom = [original];
      var selected = wine;
      late StateSetter update;
      final favorites = NailFavorites(file: file);
      await tester.runAsync(() => favorites.setFavorite(diyId, true));

      Widget browser(NailFavorites store) => MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return InlineStyleBrowser(
                selectedStyle: selected,
                customStyles: custom,
                onSelected: (style) => update(() => selected = style),
                onCreateDiy: () {},
                onEditDiy: (_) {},
                onDeleteDiy: (_) {},
                favorites: store,
              );
            },
          ),
        ),
      );

      final toggle = find.byKey(const ValueKey('toggle-nail-favorite'));
      final shelf = find.byKey(const ValueKey('inline-category-favorites'));
      final wineCard = find.byKey(const ValueKey('inline-style-wine'));
      final diyCard = find.byKey(const ValueKey('inline-style-$diyId'));
      await tester.pumpWidget(browser(favorites));
      await _until(tester, () => find.text('收藏 1').evaluate().isNotEmpty);
      await tester.tap(toggle);
      await _until(tester, () => find.text('收藏 2').evaluate().isNotEmpty);
      await tester.tap(shelf);
      await tester.pump();
      expect(wineCard, findsOneWidget);
      expect(diyCard, findsOneWidget);
      await tester.tap(diyCard);
      await tester.pump();
      expect(selected.id, diyId);
      expect(tester.widget<ChoiceChip>(shelf).selected, isTrue);

      final updated = revision('自建修订', 'rev2');
      update(() {
        custom = [updated];
        selected = updated.style;
      });
      await tester.pump();
      expect(
        find.descendant(of: diyCard, matching: find.text('自建修订')),
        findsOneWidget,
      );

      update(() {
        custom = [];
        selected = rose;
      });
      await tester.pump();
      expect(diyCard, findsNothing);
      expect(find.text('收藏 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(browser(NailFavorites(file: file)));
      await _until(tester, () => find.text('收藏 1').evaluate().isNotEmpty);
      await tester.tap(shelf);
      await tester.pump();
      await tester.tap(wineCard);
      await tester.pump();
      expect(selected.id, 'wine');
      await tester.tap(toggle);
      await _until(tester, () => find.text('收藏 0').evaluate().isNotEmpty);
      expect(find.text('试戴喜欢的款式后，点上方爱心收藏。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    if (done()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(done(), isTrue);
}
