import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

part 'photo_makeup_rendering.dart';

enum MakeupPart {
  foundation('粉底', [
    ('自然米', 0xffd3a68b),
    ('柔象牙', 0xffe3c0a5),
    ('暖小麦', 0xffb78063),
    ('深杏棕', 0xffa16f55),
    ('冷瓷米', 0xffe8c5b7),
    ('橄榄米', 0xffc5a580),
    ('蜂蜜棕', 0xffa47552),
    ('深可可', 0xff795441),
  ]),
  concealer('遮瑕', [
    ('自然杏', 0xffdbb397),
    ('浅奶杏', 0xffe5c5a9),
    ('暖沙色', 0xffbf9274),
    ('蜜桃校色', 0xffd7977d),
    ('深蜂蜜', 0xff9c6d4f),
  ]),
  powder('散粉', [
    ('柔米色', 0xffead8c7),
    ('淡粉纱', 0xfff0ddd2),
    ('暖杏纱', 0xffdfc1a7),
    ('暖棕纱', 0xffb68f71),
  ]),
  blush('腮红', [
    ('烟粉玫瑰', 0xffca6778),
    ('蜜桃珊瑚', 0xffe28d72),
    ('覆盆莓', 0xffaf536a),
    ('奶茶杏', 0xffc58578),
    ('杏橘', 0xffd68163),
    ('藕紫', 0xffb27d9b),
    ('裸米粉', 0xffbe8b7e),
    ('暖砖红', 0xffad6353),
    ('冷莓粉', 0xff9f647e),
    ('暖玫木', 0xffa5656a),
    ('明珊瑚', 0xffe77461),
    ('蓝调浅粉', 0xffe89eb6),
    ('蜜桃太妃', 0xffbb7a60),
    ('冷调樱红', 0xffc64f69),
    ('暗莓紫', 0xff89506d),
    ('净杏粉', 0xffd89584),
    ('绢面玫瑰', 0xffbf7184),
    ('冷樱粉', 0xffd979a0),
    ('红茶陶土', 0xffa85f4d),
  ]),
  contour('修容', [
    ('柔棕', 0xff83594c),
    ('暖沙棕', 0xff9b7261),
    ('冷灰棕', 0xff74554f),
    ('深可可', 0xff60433c),
    ('浅灰杏', 0xffa58378),
  ]),
  highlight('高光', [
    ('香槟', 0xfff0d7b9),
    ('玫瑰珠光', 0xfff2ced0),
    ('暖金', 0xffe6c092),
    ('柔月光', 0xfff3e2da),
    ('焦糖金', 0xffd2a679),
    ('冰珠光', 0xffe5dfe9),
  ]),
  brows('眉妆', [
    ('深灰棕', 0xff56413c),
    ('暖深棕', 0xff503e37),
    ('雾浅棕', 0xff736157),
    ('柔灰黑', 0xff39343a),
    ('浅亚麻', 0xff8a7767),
  ]),
  shadow(
    '眼影',
    [
      ('干枯玫瑰', 0xffae6f79),
      ('蜜桃棕', 0xffad7659),
      ('烟紫灰', 0xff675765),
      ('暖咖', 0xff95644f),
      ('柔粉杏', 0xffc28980),
      ('香槟棕', 0xffb19278),
      ('藕灰紫', 0xff947184),
      ('燕麦灰', 0xffa29891),
      ('烟熏梅', 0xff6d495d),
      ('深可可', 0xff664b40),
      ('琥珀金棕', 0xffb48054),
      ('墨苔绿', 0xff576348),
      ('玫瑰木', 0xff996468),
      ('冰紫银', 0xffacabc9),
      ('肉桂铜', 0xffb97654),
      ('冷咖啡', 0xff68534c),
      ('灰粉雾', 0xffb9979b),
      ('杏米珠光', 0xffd5ae9b),
      ('炭棕', 0xff4d4549),
      ('雾青灰', 0xff8e949c),
      ('丝缎浅棕', 0xffa68779),
      ('赤陶棕', 0xff996859),
      ('茱萸粉', 0xffcb7892),
      ('墨兰紫', 0xff605b70),
      ('古金', 0xffc7a668),
      ('银粉晶', 0xffc6aec8),
      ('蜜糖金', 0xffc79b69),
      ('午夜靛蓝', 0xff4d5a7e),
    ],
    ['柔雾', '加深眼尾', '细闪'],
  ),
  liner(
    '眼线',
    [
      ('炭黑', 0xff3b2831),
      ('可可棕', 0xff57352f),
      ('梅紫', 0xff65475e),
      ('柔灰棕', 0xff6f5650),
      ('深苔绿', 0xff484c41),
      ('墨青', 0xff3d4b59),
      ('黛蓝', 0xff38476b),
    ],
    ['细线', '上扬', '拉长'],
  ),
  lashes(
    '美睫',
    [
      ('柔黑', 0xff2b2024),
      ('可可棕', 0xff5a3a2d),
      ('暖浅棕', 0xff765849),
      ('灰棕', 0xff594b4b),
    ],
    [
      '自然短密',
      '眼尾拉长',
      '漫画束感',
      '浓密卷翘',
      '圆眼加长',
      '下睫毛',
      '纤长羽感',
      '半截眼尾',
      '湿束轻翘',
      '柔弯短睫',
    ],
  ),
  eyeCorner('开眼角', [('自然棕', 0xff71483e)], ['内眼角', '外眼角']),
  doubleLid(
    '双眼皮',
    [('柔棕', 0xff8a5b54), ('暖浅棕', 0xff9f7060), ('深棕', 0xff785449)],
    ['自然折线', '稍宽'],
  ),
  lipstick(
    '口红',
    [
      ('玫瑰豆沙', 0xffab4e61),
      ('复古朱红', 0xffbc4239),
      ('蜜桃裸粉', 0xffcb7265),
      ('烟莓红', 0xff914756),
      ('奶茶棕', 0xffb56d62),
      ('焦糖砖红', 0xff944137),
      ('燕麦裸杏', 0xffba8576),
      ('冷藕紫', 0xffa26383),
      ('珊瑚杏橘', 0xffce745a),
      ('黑莓果酱', 0xff803e5c),
      ('琥珀红茶', 0xffa75c48),
      ('肉桂裸棕', 0xff9c695c),
      ('蔷薇冷红', 0xffa83e55),
      ('葡萄酒红', 0xff753545),
      ('杏蜜裸粉', 0xffd08b79),
      ('玫木梅', 0xff945467),
      ('冰莓粉', 0xffb96d89),
      ('肉桂糖', 0xffaa553a),
      ('裸咖玫', 0xffa36c63),
      ('深桑莓', 0xff7a304f),
      ('朱砂绒', 0xffb23a3b),
      ('黑樱桃', 0xff602f3f),
      ('花瓣粉', 0xffc4788e),
      ('白茶杏', 0xffcd9a90),
      ('雾紫玫', 0xff9b687a),
      ('丝缎玫瑰', 0xffab556c),
      ('港红', 0xffb2333b),
      ('甜樱粉', 0xffca6e8f),
      ('柿子泥', 0xffac5749),
      ('赤金酒红', 0xff87373a),
      ('粉晶豆沙', 0xffb6808d),
      ('蜜糖裸杏', 0xffbb8975),
    ],
    ['柔雾', '水光', '咬唇', '缎光', '镜面唇釉', '细闪唇釉'],
  );

  const MakeupPart(this.label, this._shades, [this.styleNames = const ['自然']]);
  final String label;
  final List<(String, int)> _shades;
  final List<String> styleNames;
  List<Color> get palette =>
      _shades.map((shade) => Color(shade.$2)).toList(growable: false);
  String shadeName(int index) => _shades[index].$1;
  Color _shadeColor(int index) => Color(_shades[index].$2);

  List<(String, List<int>)> get shadeFamilies => switch (this) {
    blush => const [
      ('裸杏', [3, 6, 12, 15]),
      ('粉玫', [0, 9, 11, 16, 17]),
      ('暖橘', [1, 4, 7, 10, 18]),
      ('莓紫', [2, 5, 8, 13, 14]),
    ],
    shadow => const [
      ('裸灰', [5, 7, 15, 19]),
      ('暖棕', [1, 3, 10, 14, 20, 21]),
      ('粉紫', [0, 4, 6, 8, 12, 16, 22, 23]),
      ('冷彩', [2, 11, 13, 25, 27]),
      ('深烟', [9, 18]),
      ('浅金', [17, 24, 26]),
    ],
    lipstick => const [
      ('裸棕', [2, 4, 6, 11, 14, 18, 23, 31]),
      ('粉玫', [0, 12, 22, 25, 27, 30]),
      ('红调', [1, 20, 26, 29]),
      ('暖橘', [5, 8, 10, 17, 28]),
      ('冷紫', [7, 15, 16, 24]),
      ('深莓', [3, 9, 13, 19, 21]),
    ],
    _ => const [],
  };
}

@immutable
class MakeupLayer {
  const MakeupLayer({required this.color, this.amount = 0, this.style = 0});
  final Color color;
  final double amount;
  final int style;

  MakeupLayer copyWith({Color? color, double? amount, int? style}) =>
      MakeupLayer(
        color: color ?? this.color,
        amount: amount ?? this.amount,
        style: style ?? this.style,
      );
}

@immutable
class MakeupDesign {
  const MakeupDesign() : _layers = const {}, _points = const {};
  const MakeupDesign._(this._layers, this._points);
  final Map<MakeupPart, MakeupLayer> _layers;
  final Map<MakeupPart, Map<int, Offset>> _points;

  MakeupLayer layer(MakeupPart part) =>
      _layers[part] ?? MakeupLayer(color: part._shadeColor(0));

  /// Apply a preset without losing adjustments to the photographed contours.
  MakeupDesign replaceLayers(MakeupDesign preset) =>
      MakeupDesign._(preset._layers, _points);

  MakeupDesign setLayer(MakeupPart part, MakeupLayer layer) => MakeupDesign._({
    ..._layers,
    part: layer.copyWith(
      amount: layer.amount.isFinite ? layer.amount.clamp(0.0, 1.0) : 0.0,
      style: layer.style.clamp(0, part.styleNames.length - 1),
    ),
  }, _points);

  MakeupDesign setPoint(
    MakeupPhoto photo,
    MakeupPart part,
    int index,
    Offset normalized,
  ) {
    final controls = _controls(photo, this, part);
    if (index < 0 || index >= controls.length || !normalized.isFinite) {
      return this;
    }
    final origin = controls[index];
    final delta = normalized - origin;
    final limit = photo.faceWidth * (part == MakeupPart.eyeCorner ? .045 : .11);
    final bounded =
        origin +
        (delta.distance > limit ? delta / delta.distance * limit : delta);
    return MakeupDesign._(_layers, {
      ..._points,
      part: {
        ...?_points[part],
        index:
            Offset(bounded.dx.clamp(0.0, 1.0), bounded.dy.clamp(0.0, 1.0)) -
            origin,
      },
    });
  }

  MakeupDesign resetPoints(MakeupPart part) =>
      MakeupDesign._(_layers, {..._points}..remove(part));
}

enum MakeupLookGroup {
  daily('日常'),
  soft('柔彩'),
  glow('光泽'),
  bold('浓妆'),
  seasonal('秋冬新妆'),
  signature('风格妆'),
  holiday('节日妆');

  const MakeupLookGroup(this.label);
  final String label;
}

enum MakeupLook {
  fresh('清透日常', MakeupLookGroup.daily),
  peach('蜜桃暖妆', MakeupLookGroup.soft),
  rose('玫瑰氛围', MakeupLookGroup.soft),
  evening('晚宴烟熏', MakeupLookGroup.bold),
  retro('复古红唇', MakeupLookGroup.bold),
  oat('燕麦裸妆', MakeupLookGroup.daily),
  milkTea('奶茶通勤', MakeupLookGroup.daily),
  mist('低饱和雾妆', MakeupLookGroup.daily),
  apricot('杏橘元气', MakeupLookGroup.soft),
  mauve('藕紫柔雾', MakeupLookGroup.soft),
  champagne('香槟微光', MakeupLookGroup.glow),
  berry('莓果釉光', MakeupLookGroup.glow),
  amber('琥珀红茶', MakeupLookGroup.glow),
  plum('梅子夜色', MakeupLookGroup.bold),
  forestCoral('森绿珊瑚', MakeupLookGroup.seasonal),
  rosewood('玫木水光', MakeupLookGroup.seasonal),
  icedLavender('冰紫珠光', MakeupLookGroup.seasonal),
  cinnamon('肉桂暖釉', MakeupLookGroup.seasonal),
  espresso('咖啡烟熏', MakeupLookGroup.seasonal),
  velvetBerry('深莓丝绒', MakeupLookGroup.seasonal),
  redSilk('朱砂国风', MakeupLookGroup.seasonal),
  lacquerCherry('黑樱漆光', MakeupLookGroup.seasonal),
  porcelainPink('洛可可粉', MakeupLookGroup.seasonal),
  winterFlush('寒风冻红', MakeupLookGroup.seasonal),
  whiteTea('白开水妆', MakeupLookGroup.daily),
  softCool('淡颜清冷', MakeupLookGroup.signature),
  silkHeir('千金妆', MakeupLookGroup.signature),
  hongKong('港风红唇', MakeupLookGroup.signature),
  roseRabbit('甜兔粉妆', MakeupLookGroup.signature),
  inkOrchid('墨兰国风', MakeupLookGroup.signature),
  winterGold('金箔暖宴', MakeupLookGroup.holiday),
  pinkCrystal('粉晶微闪', MakeupLookGroup.holiday),
  honeyGlow('蜜糖亮片', MakeupLookGroup.holiday),
  midnightBlue('午夜蓝光', MakeupLookGroup.holiday);

  const MakeupLook(this.label, this.group);
  final String label;
  final MakeupLookGroup group;
  static final _designs = [for (final look in values) look._buildDesign()];

  MakeupDesign get design => _designs[index];

  MakeupDesign atStrength(double strength) {
    final amount = strength.isFinite ? strength.clamp(0.0, 1.0) : 0.0;
    return MakeupDesign._({
      for (final entry in design._layers.entries)
        entry.key: entry.value.copyWith(amount: entry.value.amount * amount),
    }, const {});
  }

  double strengthIn(MakeupDesign current) {
    final entry = design._layers.entries.first;
    return (current.layer(entry.key).amount / entry.value.amount).clamp(
      0.0,
      1.0,
    );
  }

  MakeupDesign _buildDesign() {
    final entries = switch (this) {
      fresh => [
        (MakeupPart.foundation, 0, .23, 0),
        (MakeupPart.powder, 0, .22, 0),
        (MakeupPart.lashes, 1, .46, 0),
        (MakeupPart.lipstick, 2, .38, 0),
      ],
      peach => [
        (MakeupPart.foundation, 1, .29, 0),
        (MakeupPart.blush, 1, .47, 0),
        (MakeupPart.shadow, 1, .42, 2),
        (MakeupPart.lashes, 1, .55, 4),
        (MakeupPart.lipstick, 2, .58, 1),
      ],
      rose => [
        (MakeupPart.powder, 1, .29, 0),
        (MakeupPart.blush, 0, .50, 0),
        (MakeupPart.shadow, 0, .53, 0),
        (MakeupPart.lashes, 0, .58, 2),
        (MakeupPart.lipstick, 0, .62, 2),
      ],
      evening => [
        (MakeupPart.foundation, 0, .33, 0),
        (MakeupPart.contour, 0, .37, 0),
        (MakeupPart.highlight, 0, .31, 0),
        (MakeupPart.shadow, 2, .69, 1),
        (MakeupPart.liner, 0, .61, 1),
        (MakeupPart.lashes, 0, .76, 3),
        (MakeupPart.lipstick, 3, .64, 0),
      ],
      retro => [
        (MakeupPart.foundation, 1, .33, 0),
        (MakeupPart.powder, 0, .34, 0),
        (MakeupPart.brows, 1, .30, 0),
        (MakeupPart.liner, 0, .66, 2),
        (MakeupPart.lashes, 0, .64, 1),
        (MakeupPart.lipstick, 1, .82, 0),
      ],
      oat => [
        (MakeupPart.concealer, 0, .22, 0),
        (MakeupPart.brows, 2, .24, 0),
        (MakeupPart.shadow, 7, .26, 0),
        (MakeupPart.lashes, 2, .35, 9),
        (MakeupPart.lipstick, 6, .38, 3),
      ],
      milkTea => [
        (MakeupPart.powder, 0, .18, 0),
        (MakeupPart.blush, 3, .30, 0),
        (MakeupPart.shadow, 3, .40, 0),
        (MakeupPart.liner, 1, .28, 0),
        (MakeupPart.lashes, 1, .43, 7),
        (MakeupPart.lipstick, 4, .50, 3),
      ],
      mist => [
        (MakeupPart.powder, 1, .27, 0),
        (MakeupPart.blush, 6, .23, 0),
        (MakeupPart.brows, 0, .23, 0),
        (MakeupPart.shadow, 7, .32, 0),
        (MakeupPart.lashes, 3, .33, 6),
        (MakeupPart.lipstick, 11, .40, 0),
      ],
      apricot => [
        (MakeupPart.blush, 4, .45, 0),
        (MakeupPart.shadow, 4, .33, 0),
        (MakeupPart.liner, 1, .25, 0),
        (MakeupPart.lashes, 2, .42, 4),
        (MakeupPart.lipstick, 8, .53, 2),
      ],
      mauve => [
        (MakeupPart.blush, 5, .41, 0),
        (MakeupPart.shadow, 6, .52, 1),
        (MakeupPart.liner, 2, .39, 0),
        (MakeupPart.lashes, 3, .47, 6),
        (MakeupPart.lipstick, 7, .50, 0),
      ],
      champagne => [
        (MakeupPart.highlight, 0, .43, 0),
        (MakeupPart.blush, 6, .28, 0),
        (MakeupPart.shadow, 5, .49, 2),
        (MakeupPart.lashes, 1, .44, 6),
        (MakeupPart.lipstick, 6, .43, 3),
      ],
      berry => [
        (MakeupPart.blush, 8, .34, 0),
        (MakeupPart.shadow, 0, .31, 0),
        (MakeupPart.highlight, 1, .28, 0),
        (MakeupPart.lashes, 0, .52, 8),
        (MakeupPart.lipstick, 9, .65, 4),
      ],
      amber => [
        (MakeupPart.contour, 1, .30, 0),
        (MakeupPart.highlight, 2, .34, 0),
        (MakeupPart.blush, 7, .31, 0),
        (MakeupPart.shadow, 10, .49, 2),
        (MakeupPart.lashes, 1, .49, 7),
        (MakeupPart.lipstick, 10, .57, 4),
      ],
      plum => [
        (MakeupPart.blush, 2, .35, 0),
        (MakeupPart.shadow, 8, .70, 1),
        (MakeupPart.liner, 2, .62, 2),
        (MakeupPart.lashes, 0, .64, 8),
        (MakeupPart.lipstick, 13, .72, 3),
      ],
      forestCoral => [
        (MakeupPart.blush, 10, .39, 0),
        (MakeupPart.shadow, 11, .61, 1),
        (MakeupPart.liner, 4, .36, 0),
        (MakeupPart.lashes, 1, .44, 7),
        (MakeupPart.lipstick, 14, .36, 3),
      ],
      rosewood => [
        (MakeupPart.blush, 9, .35, 0),
        (MakeupPart.highlight, 1, .24, 0),
        (MakeupPart.shadow, 12, .46, 0),
        (MakeupPart.lashes, 3, .43, 6),
        (MakeupPart.lipstick, 15, .56, 1),
      ],
      icedLavender => [
        (MakeupPart.highlight, 3, .31, 0),
        (MakeupPart.blush, 11, .35, 0),
        (MakeupPart.shadow, 13, .57, 2),
        (MakeupPart.liner, 2, .27, 0),
        (MakeupPart.lashes, 3, .43, 8),
        (MakeupPart.lipstick, 16, .43, 3),
      ],
      cinnamon => [
        (MakeupPart.contour, 1, .22, 0),
        (MakeupPart.blush, 12, .36, 0),
        (MakeupPart.shadow, 14, .45, 2),
        (MakeupPart.lashes, 1, .43, 9),
        (MakeupPart.lipstick, 17, .60, 4),
      ],
      espresso => [
        (MakeupPart.brows, 0, .23, 0),
        (MakeupPart.blush, 12, .25, 0),
        (MakeupPart.shadow, 15, .71, 1),
        (MakeupPart.liner, 1, .51, 2),
        (MakeupPart.lashes, 0, .57, 1),
        (MakeupPart.lipstick, 18, .42, 0),
      ],
      velvetBerry => [
        (MakeupPart.powder, 1, .18, 0),
        (MakeupPart.blush, 14, .35, 0),
        (MakeupPart.shadow, 16, .30, 0),
        (MakeupPart.lashes, 3, .48, 4),
        (MakeupPart.lipstick, 19, .73, 0),
      ],
      redSilk => [
        (MakeupPart.blush, 9, .27, 0),
        (MakeupPart.brows, 0, .24, 0),
        (MakeupPart.shadow, 4, .31, 0),
        (MakeupPart.liner, 1, .44, 2),
        (MakeupPart.lashes, 1, .38, 7),
        (MakeupPart.lipstick, 20, .70, 2),
      ],
      lacquerCherry => [
        (MakeupPart.blush, 14, .22, 0),
        (MakeupPart.shadow, 18, .44, 1),
        (MakeupPart.liner, 0, .40, 1),
        (MakeupPart.lashes, 0, .53, 3),
        (MakeupPart.lipstick, 21, .72, 4),
      ],
      porcelainPink => [
        (MakeupPart.highlight, 1, .33, 0),
        (MakeupPart.blush, 11, .55, 0),
        (MakeupPart.shadow, 17, .43, 2),
        (MakeupPart.lashes, 1, .55, 4),
        (MakeupPart.lipstick, 22, .53, 3),
      ],
      winterFlush => [
        (MakeupPart.blush, 13, .42, 0),
        (MakeupPart.highlight, 3, .20, 0),
        (MakeupPart.shadow, 16, .24, 0),
        (MakeupPart.lashes, 2, .35, 9),
        (MakeupPart.lipstick, 16, .46, 1),
      ],
      whiteTea => [
        (MakeupPart.blush, 15, .19, 0),
        (MakeupPart.brows, 2, .17, 0),
        (MakeupPart.lashes, 2, .29, 9),
        (MakeupPart.lipstick, 23, .29, 1),
      ],
      softCool => [
        (MakeupPart.shadow, 19, .38, 0),
        (MakeupPart.brows, 0, .18, 0),
        (MakeupPart.liner, 3, .23, 0),
        (MakeupPart.lashes, 3, .32, 6),
        (MakeupPart.lipstick, 24, .36, 0),
      ],
      silkHeir => [
        (MakeupPart.powder, 0, .20, 0),
        (MakeupPart.highlight, 0, .30, 0),
        (MakeupPart.blush, 16, .42, 0),
        (MakeupPart.shadow, 20, .42, 0),
        (MakeupPart.liner, 1, .27, 0),
        (MakeupPart.lashes, 1, .56, 6),
        (MakeupPart.lipstick, 25, .59, 3),
      ],
      hongKong => [
        (MakeupPart.brows, 3, .36, 0),
        (MakeupPart.blush, 18, .36, 0),
        (MakeupPart.shadow, 21, .44, 1),
        (MakeupPart.liner, 0, .64, 2),
        (MakeupPart.lashes, 0, .55, 1),
        (MakeupPart.lipstick, 26, .80, 3),
      ],
      roseRabbit => [
        (MakeupPart.blush, 17, .52, 0),
        (MakeupPart.shadow, 22, .51, 0),
        (MakeupPart.liner, 2, .30, 0),
        (MakeupPart.lashes, 3, .50, 5),
        (MakeupPart.lipstick, 27, .57, 2),
      ],
      inkOrchid => [
        (MakeupPart.brows, 3, .31, 0),
        (MakeupPart.shadow, 23, .46, 1),
        (MakeupPart.liner, 5, .53, 2),
        (MakeupPart.lashes, 0, .34, 7),
        (MakeupPart.lipstick, 28, .55, 2),
      ],
      winterGold => [
        (MakeupPart.blush, 18, .34, 0),
        (MakeupPart.highlight, 2, .40, 0),
        (MakeupPart.shadow, 24, .64, 2),
        (MakeupPart.liner, 1, .48, 1),
        (MakeupPart.lashes, 0, .60, 3),
        (MakeupPart.lipstick, 29, .70, 3),
      ],
      pinkCrystal => [
        (MakeupPart.highlight, 5, .35, 0),
        (MakeupPart.blush, 17, .35, 0),
        (MakeupPart.shadow, 25, .54, 2),
        (MakeupPart.lashes, 3, .49, 4),
        (MakeupPart.lipstick, 30, .55, 5),
      ],
      honeyGlow => [
        (MakeupPart.highlight, 4, .38, 0),
        (MakeupPart.blush, 15, .34, 0),
        (MakeupPart.shadow, 26, .57, 2),
        (MakeupPart.liner, 1, .32, 0),
        (MakeupPart.lashes, 1, .48, 8),
        (MakeupPart.lipstick, 31, .62, 5),
      ],
      midnightBlue => [
        (MakeupPart.highlight, 5, .31, 0),
        (MakeupPart.shadow, 27, .63, 1),
        (MakeupPart.liner, 6, .62, 1),
        (MakeupPart.lashes, 0, .54, 1),
        (MakeupPart.lipstick, 23, .38, 3),
      ],
    };
    var design = const MakeupDesign();
    for (final (part, shade, amount, style) in entries) {
      design = design.setLayer(
        part,
        MakeupLayer(
          color: part._shadeColor(shade),
          amount: amount,
          style: style,
        ),
      );
    }
    return design;
  }
}

@immutable
class MakeupFaceGeometry {
  MakeupFaceGeometry(Map<String, List<Offset>> regions, {double aspect = 1})
    : this._(regions, aspect, null);

  MakeupFaceGeometry._(
    Map<String, List<Offset>> regions,
    this.aspect,
    this._tone,
  ) : _regions = Map.unmodifiable(
        regions.map(
          (key, value) => MapEntry(key, List<Offset>.unmodifiable(value)),
        ),
      );

  final Map<String, List<Offset>> _regions;
  final double aspect;
  final _SkinSample? _tone;
  List<Offset> region(String name) => _regions[name] ?? const [];
  late final double faceWidth = _measureFaceWidth();

  double _measureFaceWidth() {
    final outline = region('outline');
    if (outline.isEmpty) return 0;
    return outline.map((p) => p.dx).reduce(math.max) -
        outline.map((p) => p.dx).reduce(math.min);
  }

  /// Smooth small detector fluctuations and respond faster to actual motion.
  MakeupFaceGeometry smoothToward(
    MakeupFaceGeometry current, {
    required double elapsedSeconds,
  }) {
    if (!elapsedSeconds.isFinite ||
        elapsedSeconds <= 0 ||
        elapsedSeconds > .25 ||
        current.faceWidth == 0) {
      return current;
    }
    final output = <String, List<Offset>>{};
    var headMotion = (current.faceWidth - faceWidth).abs();
    for (final name in ['eyeA', 'eyeB']) {
      final previous = region(name), next = current.region(name);
      if (previous.isNotEmpty && next.isNotEmpty) {
        headMotion = math.max(
          headMotion,
          (_center(next) - _center(previous)).distance,
        );
      }
    }
    final sharedMotion = headMotion / current.faceWidth;
    for (final entry in current._regions.entries) {
      final next = entry.value;
      final previous = region(entry.key);
      if (previous.length != next.length || next.isEmpty) {
        output[entry.key] = next;
        continue;
      }
      output[entry.key] = [
        for (var i = 0; i < next.length; i++)
          _smoothPoint(
            previous[i],
            next[i],
            current.faceWidth,
            elapsedSeconds,
            sharedMotion: sharedMotion,
            followsExpression: const {
              'eyeA',
              'eyeB',
              'outerLips',
              'innerLips',
            }.contains(entry.key),
          ),
      ];
    }
    final priorTone = _tone, nextTone = current._tone;
    final t = 1 - math.exp(-elapsedSeconds * 5);
    final tone = switch ((priorTone, nextTone)) {
      (final previous?, final next?) => (
        color: Color.lerp(previous.color, next.color, t)!,
        confidence: previous.confidence * (1 - t) + next.confidence * t,
      ),
      (final previous?, null) when previous.confidence * (1 - t) > .08 => (
        color: previous.color,
        confidence: previous.confidence * (1 - t),
      ),
      _ => nextTone,
    };
    return MakeupFaceGeometry._(output, current.aspect, tone);
  }

  static Offset _smoothPoint(
    Offset before,
    Offset after,
    double width,
    double dt, {
    required double sharedMotion,
    required bool followsExpression,
  }) {
    final motion = math
        .max(
          sharedMotion,
          followsExpression ? (after - before).distance / width : 0.0,
        )
        .clamp(0.0, .12);
    final response = 1 - math.exp(-dt * (12 + 360 * motion));
    return Offset.lerp(before, after, response)!;
  }
}

class MakeupPhoto extends MakeupFaceGeometry {
  MakeupPhoto(this.image, Map<String, List<Offset>> regions)
    : super(regions, aspect: image.width / image.height);

  MakeupPhoto._(
    this.image,
    Map<String, List<Offset>> regions,
    _SkinSample? tone,
  ) : super._(regions, image.width / image.height, tone);

  final ui.Image image;
  void dispose() => image.dispose();
}

typedef _SkinSample = ({Color color, double confidence});

_SkinSample? _readSkinSample(Object? raw) {
  if (raw is! Map) return null;
  double? channel(String key) {
    final value = raw[key];
    return value is num && value.isFinite && value >= 0 && value <= 1
        ? value.toDouble()
        : null;
  }

  final r = channel('r'), g = channel('g'), b = channel('b');
  final confidence = channel('confidence');
  if (r == null ||
      g == null ||
      b == null ||
      confidence == null ||
      confidence < .08) {
    return null;
  }
  return (
    color: Color.from(alpha: 1, red: r, green: g, blue: b),
    confidence: confidence,
  );
}

const _meshRegions = <String, List<int>>{
  'outline': [
    10,
    338,
    297,
    332,
    284,
    251,
    389,
    356,
    454,
    323,
    361,
    288,
    397,
    365,
    379,
    378,
    400,
    377,
    152,
    148,
    176,
    149,
    150,
    136,
    172,
    58,
    132,
    93,
    234,
    127,
    162,
    21,
    54,
    103,
    67,
    109,
  ],
  'eyeA': [
    33,
    246,
    161,
    160,
    159,
    158,
    157,
    173,
    133,
    155,
    154,
    153,
    145,
    144,
    163,
    7,
  ],
  'eyeB': [
    362,
    398,
    384,
    385,
    386,
    387,
    388,
    466,
    263,
    249,
    390,
    373,
    374,
    380,
    381,
    382,
  ],
  'browA': [70, 63, 105, 66, 107, 55, 65, 52, 53, 46],
  'browB': [336, 296, 334, 293, 300, 276, 283, 282, 295, 285],
  'outerLips': [
    61,
    185,
    40,
    39,
    37,
    0,
    267,
    269,
    270,
    409,
    291,
    375,
    321,
    405,
    314,
    17,
    84,
    181,
    91,
    146,
  ],
  'innerLips': [
    78,
    191,
    80,
    81,
    82,
    13,
    312,
    311,
    310,
    415,
    308,
    324,
    318,
    402,
    317,
    14,
    87,
    178,
    88,
    95,
  ],
  'nose': [168, 6, 197, 195, 5, 4, 1, 2, 98, 327],
};

List<Offset> _readPoints(Object? raw) {
  if (raw is! List) return const [];
  final result = <Offset>[];
  for (final pair in raw) {
    if (pair is! List ||
        pair.length < 2 ||
        pair[0] is! num ||
        pair[1] is! num) {
      return const [];
    }
    final point = Offset(
      (pair[0] as num).toDouble(),
      (pair[1] as num).toDouble(),
    );
    if (!point.isFinite ||
        point.dx < -.1 ||
        point.dx > 1.1 ||
        point.dy < -.1 ||
        point.dy > 1.1) {
      return const [];
    }
    result.add(point);
  }
  return result;
}

Map<String, List<Offset>> _readRegions(Map<Object?, Object?> result) {
  final mesh = _readPoints(result['makeupMesh']);
  if (mesh.length >= 468) {
    return _meshRegions.map(
      (key, indices) =>
          MapEntry(key, [for (final index in indices) mesh[index]]),
    );
  }
  final raw = result['makeupRegions'];
  if (raw is! Map) return const {};
  final regions = {
    for (final key in _meshRegions.keys) key: _readPoints(raw[key]),
  };
  final contour = regions['outline']!;
  final brows = [...regions['browA']!, ...regions['browB']!];
  if (contour.length >= 6 && brows.isNotEmpty) {
    final browY = brows.map((p) => p.dy).reduce(math.min);
    final chin = contour.map((p) => p.dy).reduce(math.max);
    final x = (contour.first.dx + contour.last.dx) / 2;
    final width = (contour.first.dx - contour.last.dx).abs();
    final crown = (browY - (chin - browY) * .34).clamp(0.0, 1.0);
    final firstSide = contour.first.dx < contour.last.dx ? -1 : 1;
    // Vision measures the cheeks and jaw. Close the skin mask with a
    // conservative forehead arc, leaving a margin below the estimated hairline.
    regions['outline'] = [
      ...contour,
      Offset(x - firstSide * width * .42, browY - (browY - crown) * .51),
      Offset(x - firstSide * width * .25, crown + (browY - crown) * .12),
      Offset(x, crown),
      Offset(x + firstSide * width * .25, crown + (browY - crown) * .12),
      Offset(x + firstSide * width * .42, browY - (browY - crown) * .51),
    ];
  }
  return regions;
}

bool _hasMakeupContours(Map<String, List<Offset>> regions) =>
    (regions['outline']?.length ?? 0) >= 6 &&
    (regions['eyeA']?.length ?? 0) >= 6 &&
    (regions['eyeB']?.length ?? 0) >= 6 &&
    (regions['outerLips']?.length ?? 0) >= 6;

MakeupFaceGeometry? makeupFaceGeometryFromNative(Map<Object?, Object?> frame) {
  if (frame['faceCount'] != 1) return null;
  final face = frame['face'];
  if (face is Map) {
    final yaw = face['yaw'];
    if (yaw is num && (!yaw.isFinite || yaw.abs() > .58)) return null;
  }
  final regions = _readRegions(frame);
  if (!_hasMakeupContours(regions)) return null;
  final width = frame['width'], height = frame['height'];
  final aspect =
      width is num &&
          height is num &&
          width.isFinite &&
          height.isFinite &&
          width > 0 &&
          height > 0
      ? (width / height).clamp(.3, 3.0)
      : 1.0;
  final geometry = MakeupFaceGeometry._(
    regions,
    aspect,
    _readSkinSample(frame['skinSample']),
  );
  if (geometry.faceWidth < .09 || geometry.faceWidth > .89) return null;
  return geometry;
}

({Uint8List png, int width, int height}) _normalizeMakeupPhoto(
  Uint8List bytes,
) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('请选择 JPEG、PNG 或重新拍照。');
  var image = img
      .bakeOrientation(decoded)
      .convert(format: img.Format.uint8, numChannels: 3);
  if (math.max(image.width, image.height) > 1800) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 1800 : null,
      height: image.height > image.width ? 1800 : null,
      interpolation: img.Interpolation.average,
    );
  }
  // Reconstruct RGB without retaining location or EXIF metadata.
  final pixels = Uint8List.fromList(
    image.getBytes(order: img.ChannelOrder.rgb),
  );
  final clean = img.Image.fromBytes(
    width: image.width,
    height: image.height,
    bytes: pixels.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );
  return (png: img.encodePng(clean), width: clean.width, height: clean.height);
}

Future<MakeupPhoto> prepareMakeupPhoto(String path) async {
  final photo = await compute(
    _normalizeMakeupPhoto,
    await File(path).readAsBytes(),
  );
  final folder = await (await getTemporaryDirectory()).createTemp(
    'makeup_source_',
  );
  Map<Object?, Object?>? result;
  try {
    final normalized = await File(
      '${folder.path}/source.png',
    ).writeAsBytes(photo.png);
    result = await const MethodChannel('yuying/beauty')
        .invokeMapMethod<Object?, Object?>('analyzeImage', {
          'path': normalized.path,
          'includeMakeup': true,
        });
  } finally {
    await folder.delete(recursive: true);
  }
  if (result?['faceCount'] != 1) {
    throw const FormatException('请选择一张只有一张清晰正脸的照片。');
  }
  if (result?['width'] != photo.width || result?['height'] != photo.height) {
    throw const FormatException('照片方向无法确认，请重新选择。');
  }
  final regions = _readRegions(result!);
  if (!_hasMakeupContours(regions)) {
    throw const FormatException('没看清眼睛或嘴唇，请换一张光线均匀的正面照片。');
  }
  final codec = await ui.instantiateImageCodec(photo.png);
  try {
    return MakeupPhoto._(
      (await codec.getNextFrame()).image,
      regions,
      _readSkinSample(result['skinSample']),
    );
  } finally {
    codec.dispose();
  }
}

Future<String> saveMakeupPhoto(MakeupPhoto photo, MakeupDesign design) async {
  final width = photo.image.width, height = photo.image.height;
  final recorder = ui.PictureRecorder();
  paintMakeup(
    Canvas(recorder),
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    photo,
    design,
  );
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('无法导出妆造照片。');
      final root = await getApplicationDocumentsDirectory();
      final folder = await Directory(
        '${root.path}/beauty_works',
      ).create(recursive: true);
      final output = File(
        '${folder.path}/makeup_${DateTime.now().microsecondsSinceEpoch}.png',
      );
      await output.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      return output.path;
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
