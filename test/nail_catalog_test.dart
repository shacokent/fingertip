import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';

const _seasonalPatterns = {
  NailCategory.holidayArt: {
    NailPattern.snowCrystal,
    NailPattern.giftRibbon,
    NailPattern.winterSprig,
    NailPattern.candyCane,
  },
  NailCategory.orientalArt: {
    NailPattern.jadeCloud,
    NailPattern.inkPeaks,
    NailPattern.porcelainBranch,
  },
  NailCategory.frostJewels: {
    NailPattern.frostedGlaze,
    NailPattern.foilFlakes,
    NailPattern.crystalGems,
  },
  NailCategory.winterMagnetic: {NailPattern.velvet, NailPattern.catEye},
  NailCategory.fineFrench: {NailPattern.microFrench, NailPattern.chromeFrench},
  NailCategory.winterPrints: {
    NailPattern.amberInlay,
    NailPattern.wovenPlaid,
    NailPattern.fawnSpots,
  },
};

void main() {
  test(
    'catalogue supplies 240 distinct recipes across original and seasonal categories',
    () {
      final styles = NailStyle.all;
      expect(styles, hasLength(240));
      expect(NailCategory.values, hasLength(18));
      expect(styles.map((style) => style.id).toSet(), hasLength(styles.length));
      expect(
        styles.map((style) => style.name).toSet(),
        hasLength(styles.length),
      );
      for (final category in NailCategory.values) {
        final group = styles.where((style) => style.category == category);
        final seasonalPatterns = _seasonalPatterns[category];
        expect(
          group,
          hasLength(seasonalPatterns == null ? 15 : 10),
          reason: category.label,
        );
        if (seasonalPatterns != null) {
          expect(group.map((style) => style.pattern).toSet(), seasonalPatterns);
        }
      }
      final recipes = styles
          .map(
            (style) => [
              style.color.toARGB32(),
              style.accent.toARGB32(),
              style.pattern.index,
              style.coverage,
              style.patternScale,
              style.variant,
              style.finishGloss,
            ].join('/'),
          )
          .toSet();
      expect(
        recipes,
        hasLength(styles.length),
        reason: 'Names must not duplicate one render recipe.',
      );
      expect(
        styles.map((style) => style.pattern).toSet().length,
        NailPattern.values.length,
      );
    },
  );

  test('material recipes are bounded and usable by the shader', () {
    for (final style in NailStyle.all) {
      expect(style.id, matches(RegExp(r'^[a-z][a-z0-9_]*$')));
      expect(style.name.trim(), isNotEmpty);
      expect(style.subtitle.trim(), isNotEmpty);
      expect(style.color.a, 1);
      expect(style.accent.a, 1);
      for (final value in [
        style.coverage,
        style.patternScale,
        style.variant,
        style.finishGloss,
      ]) {
        expect(value.isFinite, isTrue, reason: style.id);
      }
      expect(style.patternScale, inInclusiveRange(.7, 1.5));
      expect(style.variant, inInclusiveRange(0, 1));
      expect(style.finishGloss, inInclusiveRange(.6, 1.2));
      if (style.category == NailCategory.jelly) {
        expect(style.coverage, inInclusiveRange(.5, .8));
        expect(style.pattern, NailPattern.jelly);
      } else if (_seasonalPatterns.containsKey(style.category)) {
        expect(style.coverage, inInclusiveRange(.54, .98));
      } else {
        expect(style.coverage, .98);
      }
    }
  });

  test(
    'existing styles keep stable identities and category lookup is read only',
    () {
      const legacy = {
        'rose': ('玫瑰豆沙', NailCategory.classic),
        'wine': ('勃艮第红', NailCategory.classic),
        'french': ('奶油法式', NailCategory.french),
        'peach': ('蜜桃渐变', NailCategory.gradient),
        'sage': ('鼠尾草绿', NailCategory.classic),
        'lilac': ('微光紫雾', NailCategory.sparkle),
        'cocoa': ('可可拿铁', NailCategory.nude),
        'blue': ('雾霾蓝', NailCategory.classic),
        'velvet_plum': ('透梅丝绒', NailCategory.winterMagnetic),
        'trim_silver': ('冷银单勾边', NailCategory.fineFrench),
        'print_fawn': ('奶油小鹿纹', NailCategory.winterPrints),
      };
      expect(NailStyle.all.first.id, 'rose');
      for (final entry in legacy.entries) {
        final style = NailStyle.byId(entry.key);
        expect(style, isNotNull);
        expect(style!.name, entry.value.$1);
        expect(style.category, entry.value.$2);
        expect(identical(style, NailStyle.byId(entry.key)), isTrue);
      }
      expect(NailStyle.byId('does_not_exist'), isNull);
      expect(
        () => NailStyle.all.add(NailStyle.all.first),
        throwsUnsupportedError,
      );
      expect(() => NailStyle.all.clear(), throwsUnsupportedError);
      expect(NailPattern.values.take(4), [
        NailPattern.solid,
        NailPattern.french,
        NailPattern.ombre,
        NailPattern.shimmer,
      ]);
    },
  );
}
