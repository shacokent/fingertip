import 'dart:math' as math;
import 'package:flutter/material.dart';

enum DiyMotif {
  butterfly,
  swallowtail,
  moth,
  dragonfly,
  daisy,
  rose,
  tulip,
  blossom,
  lavender,
  branch,
  fern,
  leaf,
  star,
  crescent,
  sun,
  sparkle,
  constellation,
  snowflake,
  heart,
  loveLetter,
  bow,
  ribbon,
  lace,
  pearls,
  marble,
  watercolor,
  linen,
  glitter,
  checker,
  zebra,
  leopard,
  foil,
  shell,
  cloud,
  cherry,
  diamond,
  iceLattice,
  facetedCrystal,
  gildedArc,
  hollySprig,
  pineSprig,
  porcelainVine,
  plumBough,
  candyHook,
  goldFoilShard,
  inkRidges,
}

class DiySticker {
  const DiySticker(
    this.id,
    this.name,
    this.category,
    this.motif,
    this.primary,
    this.secondary,
    this.variant,
  );
  final String id, name, category;
  final DiyMotif motif;
  final Color primary, secondary;
  final int variant;

  static final List<DiySticker> all = List.unmodifiable([
    for (final entry in _motifs)
      for (var variant = 0; variant < 2; variant++)
        DiySticker(
          '${entry.$1.name}_$variant',
          '${variant == 0 ? entry.$4 : entry.$5}${entry.$2}',
          entry.$3,
          entry.$1,
          variant == 0 ? entry.$6 : const Color(0xFFB68C42),
          variant == 0 ? entry.$7 : const Color(0xFFFFE7B0),
          variant,
        ),
    ..._seasonalStickers,
  ]);
  static DiySticker? byId(String id) =>
      all.where((s) => s.id == id).firstOrNull;
  static final List<String> categories = List.unmodifiable(
    all.map((e) => e.category).toSet(),
  );
}

const _motifs = <(DiyMotif, String, String, String, String, Color, Color)>[
  (
    DiyMotif.butterfly,
    '蝴蝶',
    '蝴蝶昆虫',
    '蓝梦',
    '金线',
    Color(0xFF6F8FB7),
    Color(0xFFD3E9FF),
  ),
  (
    DiyMotif.swallowtail,
    '凤蝶',
    '蝴蝶昆虫',
    '紫雾',
    '鎏金',
    Color(0xFF9277A9),
    Color(0xFFE9D9F8),
  ),
  (
    DiyMotif.moth,
    '月蛾',
    '蝴蝶昆虫',
    '青瓷',
    '琥珀',
    Color(0xFF648D83),
    Color(0xFFD1E8D1),
  ),
  (
    DiyMotif.dragonfly,
    '蜻蜓',
    '蝴蝶昆虫',
    '海蓝',
    '金羽',
    Color(0xFF5E8499),
    Color(0xFFD9F0EC),
  ),
  (
    DiyMotif.daisy,
    '雏菊',
    '花卉枝叶',
    '奶白',
    '金心',
    Color(0xFFEEDBCB),
    Color(0xFFC49C40),
  ),
  (
    DiyMotif.rose,
    '玫瑰',
    '花卉枝叶',
    '豆沙',
    '香槟',
    Color(0xFFAE6B80),
    Color(0xFFF3C9CD),
  ),
  (
    DiyMotif.tulip,
    '郁金香',
    '花卉枝叶',
    '樱粉',
    '暖金',
    Color(0xFFCC829C),
    Color(0xFFEFC5CF),
  ),
  (
    DiyMotif.blossom,
    '樱花',
    '花卉枝叶',
    '浅粉',
    '鎏金',
    Color(0xFFE4A2B5),
    Color(0xFFFFDDE5),
  ),
  (
    DiyMotif.lavender,
    '薰衣草',
    '花卉枝叶',
    '雾紫',
    '暮金',
    Color(0xFF9C86BE),
    Color(0xFFD8C9F0),
  ),
  (
    DiyMotif.branch,
    '枝叶',
    '花卉枝叶',
    '橄榄',
    '金箔',
    Color(0xFF6E8F70),
    Color(0xFFB3CAA2),
  ),
  (
    DiyMotif.fern,
    '蕨叶',
    '花卉枝叶',
    '雨林',
    '浅金',
    Color(0xFF4D806E),
    Color(0xFFB8D4B2),
  ),
  (
    DiyMotif.leaf,
    '银杏',
    '花卉枝叶',
    '青绿',
    '秋金',
    Color(0xFF7A9D84),
    Color(0xFFD2DFBD),
  ),
  (
    DiyMotif.star,
    '星星',
    '星月闪光',
    '星紫',
    '碎金',
    Color(0xFF8276AA),
    Color(0xFFE5DDF2),
  ),
  (
    DiyMotif.crescent,
    '弯月',
    '星月闪光',
    '冰蓝',
    '金月',
    Color(0xFF8BA4C1),
    Color(0xFFDAE5F5),
  ),
  (
    DiyMotif.sun,
    '太阳',
    '星月闪光',
    '日落',
    '鎏金',
    Color(0xFFD9936D),
    Color(0xFFFFDCAF),
  ),
  (
    DiyMotif.sparkle,
    '闪光',
    '星月闪光',
    '银蓝',
    '香槟',
    Color(0xFF8FA6BA),
    Color(0xFFE5EEF2),
  ),
  (
    DiyMotif.constellation,
    '星座',
    '星月闪光',
    '夜紫',
    '金辉',
    Color(0xFF7B6B9F),
    Color(0xFFDCCDEE),
  ),
  (
    DiyMotif.snowflake,
    '雪花',
    '星月闪光',
    '冰晶',
    '金霜',
    Color(0xFF97B6C3),
    Color(0xFFF0F8FC),
  ),
  (
    DiyMotif.heart,
    '爱心',
    '爱心丝带',
    '樱桃',
    '金砂',
    Color(0xFFB15F7C),
    Color(0xFFF6CAD6),
  ),
  (
    DiyMotif.loveLetter,
    '情书',
    '爱心丝带',
    '奶粉',
    '香槟',
    Color(0xFFC48A99),
    Color(0xFFF9E7E5),
  ),
  (
    DiyMotif.bow,
    '蝴蝶结',
    '爱心丝带',
    '莓粉',
    '金丝',
    Color(0xFFAD6C87),
    Color(0xFFF0CFDD),
  ),
  (
    DiyMotif.ribbon,
    '丝带',
    '爱心丝带',
    '紫缎',
    '金缎',
    Color(0xFF9679A8),
    Color(0xFFE6CEE9),
  ),
  (
    DiyMotif.lace,
    '蕾丝',
    '爱心丝带',
    '奶白',
    '金边',
    Color(0xFFDCCBBE),
    Color(0xFFFFF5E7),
  ),
  (
    DiyMotif.pearls,
    '珠链',
    '爱心丝带',
    '月白',
    '香槟',
    Color(0xFFCCC2B5),
    Color(0xFFFFF8ED),
  ),
  (
    DiyMotif.marble,
    '石纹',
    '纹理叠层',
    '墨蓝',
    '金丝',
    Color(0xFF6C8297),
    Color(0xFFD7E6ED),
  ),
  (
    DiyMotif.watercolor,
    '水彩',
    '纹理叠层',
    '烟紫',
    '琥珀',
    Color(0xFFB59FC6),
    Color(0xFFF4D5D9),
  ),
  (
    DiyMotif.linen,
    '织纹',
    '纹理叠层',
    '雾灰',
    '米金',
    Color(0xFF9B9BA2),
    Color(0xFFE5DBCE),
  ),
  (
    DiyMotif.glitter,
    '碎钻',
    '纹理叠层',
    '银紫',
    '碎金',
    Color(0xFF9884B3),
    Color(0xFFF4EDFF),
  ),
  (
    DiyMotif.checker,
    '棋盘',
    '纹理叠层',
    '可可',
    '奶金',
    Color(0xFF917C6B),
    Color(0xFFF0DFCA),
  ),
  (
    DiyMotif.zebra,
    '斑马纹',
    '纹理叠层',
    '墨黑',
    '金棕',
    Color(0xFF47414C),
    Color(0xFFECE1D5),
  ),
  (
    DiyMotif.leopard,
    '豹纹',
    '纹理叠层',
    '焦糖',
    '金棕',
    Color(0xFF8B6244),
    Color(0xFFE7BE88),
  ),
  (
    DiyMotif.foil,
    '金箔',
    '纹理叠层',
    '玫金',
    '香槟',
    Color(0xFFBB8790),
    Color(0xFFF2D7AE),
  ),
  (
    DiyMotif.shell,
    '贝壳',
    '海洋甜趣',
    '海盐',
    '香槟',
    Color(0xFFA4BBC8),
    Color(0xFFF2E5DE),
  ),
  (
    DiyMotif.cloud,
    '云朵',
    '海洋甜趣',
    '奶蓝',
    '晚霞',
    Color(0xFFAFC8DD),
    Color(0xFFF6F4ED),
  ),
  (
    DiyMotif.cherry,
    '樱桃',
    '海洋甜趣',
    '莓红',
    '金果',
    Color(0xFFAD5470),
    Color(0xFFD8A0A0),
  ),
  (
    DiyMotif.diamond,
    '宝石',
    '海洋甜趣',
    '冰紫',
    '琥珀',
    Color(0xFF9C8BC2),
    Color(0xFFE5DEF4),
  ),
];

// These are separate drawings with persistent IDs, each in one palette.
const _seasonalStickers = [
  DiySticker(
    'ice_lattice',
    '六角冰晶',
    '星月闪光',
    DiyMotif.iceLattice,
    Color(0xFF6597B8),
    Color(0xFFD4EFFA),
    0,
  ),
  DiySticker(
    'faceted_crystal',
    '切面冰钻',
    '星月闪光',
    DiyMotif.facetedCrystal,
    Color(0xFF7285B0),
    Color(0xFFD5E4FF),
    0,
  ),
  DiySticker(
    'gilded_arc',
    '鎏金珠弧',
    '星月闪光',
    DiyMotif.gildedArc,
    Color(0xFFA76E36),
    Color(0xFFFFD790),
    0,
  ),
  DiySticker(
    'holly_sprig',
    '冬青红果',
    '花卉枝叶',
    DiyMotif.hollySprig,
    Color(0xFF355C4D),
    Color(0xFF7B986D),
    0,
  ),
  DiySticker(
    'pine_sprig',
    '松针短枝',
    '花卉枝叶',
    DiyMotif.pineSprig,
    Color(0xFF355D55),
    Color(0xFF88A68A),
    0,
  ),
  DiySticker(
    'porcelain_vine',
    '青花缠枝',
    '花卉枝叶',
    DiyMotif.porcelainVine,
    Color(0xFF2B527E),
    Color(0xFF91B6D6),
    0,
  ),
  DiySticker(
    'plum_bough',
    '雪梅疏枝',
    '花卉枝叶',
    DiyMotif.plumBough,
    Color(0xFFAA475D),
    Color(0xFFF2C5C5),
    0,
  ),
  DiySticker(
    'candy_hook',
    '莓红拐杖糖',
    '海洋甜趣',
    DiyMotif.candyHook,
    Color(0xFFB94156),
    Color(0xFFF8E4D2),
    0,
  ),
  DiySticker(
    'gold_foil_shard',
    '裂面金箔',
    '纹理叠层',
    DiyMotif.goldFoilShard,
    Color(0xFFAA763E),
    Color(0xFFEEC679),
    0,
  ),
  DiySticker(
    'ink_ridges',
    '雾隐山峦',
    '纹理叠层',
    DiyMotif.inkRidges,
    Color(0xFF3D545E),
    Color(0xFF718B91),
    0,
  ),
];

class DiyStickerPainter extends CustomPainter {
  const DiyStickerPainter(this.sticker);
  final DiySticker sticker;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    paintDiySticker(canvas, sticker);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DiyStickerPainter oldDelegate) =>
      oldDelegate.sticker.id != sticker.id;
}

/// Hand-drawn vector motifs; the same paths are used for library thumbnails,
/// the layered editor and the exported design texture.
void paintDiySticker(Canvas canvas, DiySticker sticker) {
  final a = sticker.primary, b = sticker.secondary;
  final ink = Paint()
    ..color = a
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.7
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  void line(Offset x, Offset y, {Color? color, double width = 1.7}) =>
      canvas.drawLine(
        x,
        y,
        Paint()
          ..color = color ?? a
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
  void path(Path path, {Color? color, bool outline = true}) {
    canvas.drawPath(path, Paint()..color = color ?? b);
    if (outline) canvas.drawPath(path, ink);
  }

  void oval(Rect rect, {Color? color}) =>
      canvas.drawOval(rect, Paint()..color = color ?? b);
  Path petal(Offset c, double radius, int count) {
    final p = Path();
    for (var i = 0; i <= count * 12; i++) {
      final theta = i / (count * 12) * math.pi * 2;
      final r = radius * (.73 + .27 * math.cos(theta * count));
      final q = c + Offset(math.cos(theta), math.sin(theta)) * r;
      if (i == 0) {
        p.moveTo(q.dx, q.dy);
      } else {
        p.lineTo(q.dx, q.dy);
      }
    }
    return p..close();
  }

  Path heart(Offset c, double r) => Path()
    ..moveTo(c.dx, c.dy + r * .8)
    ..cubicTo(c.dx - r * 1.5, c.dy, c.dx - r, c.dy - r, c.dx, c.dy - r * .35)
    ..cubicTo(c.dx + r, c.dy - r, c.dx + r * 1.5, c.dy, c.dx, c.dy + r * .8)
    ..close();

  switch (sticker.motif) {
    case DiyMotif.butterfly:
    case DiyMotif.swallowtail:
    case DiyMotif.moth:
      final tail = sticker.motif == DiyMotif.swallowtail;
      final moth = sticker.motif == DiyMotif.moth;
      for (final side in [-1.0, 1.0]) {
        canvas.save();
        canvas.translate(50, 0);
        canvas.scale(side, 1);
        final wing = Path()
          ..moveTo(0, 50)
          ..cubicTo(13, 16, 43, 9, moth ? 43 : 39, 28)
          ..cubicTo(43, 42, 22, 49, 4, 53)
          ..cubicTo(38, 49, 42, 68, tail ? 31 : 27, tail ? 89 : 76)
          ..cubicTo(19, 79, 9, 67, 0, 57)
          ..close();
        path(wing);
        final vein = Path()
          ..moveTo(2, 52)
          ..quadraticBezierTo(20, 36, 35, 24)
          ..moveTo(7, 49)
          ..quadraticBezierTo(18, 45, 34, 43)
          ..moveTo(4, 55)
          ..quadraticBezierTo(17, 64, 27, 73);
        canvas.drawPath(vein, ink..strokeWidth = 1);
        for (var i = 0; i < 4; i++) {
          oval(
            Rect.fromCircle(
              center: Offset(25 + i * 2.0, 28 + i * 5.0),
              radius: 1.8,
            ),
            color: a.withValues(alpha: .65),
          );
        }
        canvas.restore();
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(48, 37, 4, 35),
          const Radius.circular(3),
        ),
        Paint()..color = a,
      );
      canvas.drawPath(
        Path()
          ..moveTo(49, 39)
          ..quadraticBezierTo(39, 27, 42, 24)
          ..moveTo(51, 39)
          ..quadraticBezierTo(61, 27, 58, 24),
        ink..strokeWidth = 1.3,
      );
    case DiyMotif.dragonfly:
      for (final side in [-1.0, 1.0]) {
        canvas.save();
        canvas.translate(50, 0);
        canvas.scale(side, 1);
        path(
          Path()
            ..moveTo(0, 45)
            ..cubicTo(30, 9, 53, 25, 36, 37)
            ..quadraticBezierTo(15, 48, 0, 48)
            ..close(),
        );
        path(
          Path()
            ..moveTo(0, 49)
            ..cubicTo(38, 42, 43, 65, 28, 64)
            ..quadraticBezierTo(13, 61, 0, 51)
            ..close(),
        );
        line(const Offset(1, 47), const Offset(36, 30), width: .8);
        line(const Offset(1, 50), const Offset(29, 59), width: .8);
        canvas.restore();
      }
      line(const Offset(50, 37), const Offset(50, 86), width: 3);
      oval(const Rect.fromLTWH(45, 29, 10, 10), color: a);
    case DiyMotif.daisy:
    case DiyMotif.blossom:
      final count = sticker.motif == DiyMotif.daisy ? 9 : 5;
      path(petal(const Offset(50, 46), 31, count));
      oval(const Rect.fromLTWH(43, 39, 14, 14), color: a);
      for (var i = 0; i < count; i++) {
        final t = i / count * math.pi * 2;
        line(
          const Offset(50, 46) + Offset(math.cos(t), math.sin(t)) * 10,
          const Offset(50, 46) + Offset(math.cos(t), math.sin(t)) * 24,
          width: .7,
        );
      }
      line(
        const Offset(49, 78),
        const Offset(49, 95),
        color: const Color(0xFF729177),
      );
    case DiyMotif.rose:
      for (var i = 3; i >= 0; i--) {
        canvas.save();
        canvas.translate(50, 48);
        canvas.rotate(i * .63);
        path(
          petal(Offset.zero, 14 + i * 7.0, 5),
          color: Color.lerp(a, b, i / 4),
        );
        canvas.restore();
      }
      canvas.drawPath(
        Path()
          ..moveTo(40, 48)
          ..cubicTo(39, 34, 65, 35, 58, 50)
          ..cubicTo(55, 61, 42, 56, 47, 46),
        ink,
      );
      line(
        const Offset(50, 80),
        const Offset(50, 96),
        color: const Color(0xFF729177),
      );
    case DiyMotif.tulip:
      path(
        Path()
          ..moveTo(24, 25)
          ..quadraticBezierTo(36, 44, 50, 18)
          ..quadraticBezierTo(64, 43, 77, 25)
          ..cubicTo(81, 70, 21, 74, 24, 25)
          ..close(),
      );
      line(
        const Offset(50, 66),
        const Offset(50, 96),
        color: const Color(0xFF688976),
      );
      path(
        Path()
          ..moveTo(48, 91)
          ..quadraticBezierTo(21, 80, 24, 65)
          ..quadraticBezierTo(46, 69, 48, 91)
          ..close(),
        color: const Color(0xFF9DB69A),
        outline: false,
      );
    case DiyMotif.lavender:
      canvas.drawPath(
        Path()
          ..moveTo(47, 96)
          ..quadraticBezierTo(58, 49, 51, 13),
        ink..color = const Color(0xFF758D75),
      );
      for (var i = 0; i < 8; i++) {
        final y = 20 + i * 7.5;
        oval(
          Rect.fromCenter(
            center: Offset(48 + (i.isEven ? -4 : 8), y),
            width: 16,
            height: 8,
          ),
          color: i.isEven ? a : b,
        );
      }
    case DiyMotif.branch:
    case DiyMotif.fern:
    case DiyMotif.leaf:
      final ginkgo = sticker.motif == DiyMotif.leaf;
      if (ginkgo) {
        path(
          Path()
            ..moveTo(50, 81)
            ..cubicTo(20, 67, 11, 30, 32, 20)
            ..quadraticBezierTo(48, 34, 51, 18)
            ..cubicTo(76, 11, 96, 57, 50, 81)
            ..close(),
        );
        for (var i = 0; i < 7; i++) {
          line(
            const Offset(50, 80),
            Offset(25 + i * 8.0, 29 + math.sin(i) * 7),
            width: .8,
          );
        }
        line(const Offset(50, 80), const Offset(50, 97));
      } else {
        final count = sticker.motif == DiyMotif.fern ? 9 : 5;
        canvas.drawPath(
          Path()
            ..moveTo(48, 96)
            ..quadraticBezierTo(62, 45, 47, 9),
          ink,
        );
        for (var i = 0; i < count; i++) {
          final y = 18 + i * (65 / count);
          for (final side in [-1.0, 1.0]) {
            path(
              Path()
                ..moveTo(51, y + 12)
                ..quadraticBezierTo(
                  51 + side * 28,
                  y + 9,
                  51 + side * 29,
                  y - 4,
                )
                ..quadraticBezierTo(51 + side * 9, y - 4, 51, y + 12)
                ..close(),
              color: i.isEven ? a : b,
              outline: false,
            );
          }
        }
      }
    case DiyMotif.star:
    case DiyMotif.sparkle:
      final n = sticker.motif == DiyMotif.star ? 5 : 4;
      final p = Path();
      for (var i = 0; i < n * 2; i++) {
        final t = i / (n * 2) * math.pi * 2 - math.pi / 2;
        final r = i.isEven ? 36.0 : 13.0;
        final q = const Offset(50, 50) + Offset(math.cos(t), math.sin(t)) * r;
        if (i == 0) {
          p.moveTo(q.dx, q.dy);
        } else {
          p.lineTo(q.dx, q.dy);
        }
      }
      path(p..close());
      if (n == 4) {
        line(const Offset(14, 17), const Offset(22, 25));
        line(const Offset(22, 17), const Offset(14, 25));
      }
    case DiyMotif.crescent:
      path(
        Path()
          ..moveTo(66, 13)
          ..cubicTo(15, 4, 6, 80, 56, 87)
          ..quadraticBezierTo(83, 90, 89, 64)
          ..cubicTo(54, 89, 27, 33, 66, 13)
          ..close(),
      );
      oval(const Rect.fromLTWH(73, 20, 5, 5), color: a);
    case DiyMotif.sun:
      path(petal(const Offset(50, 50), 37, 12));
      oval(const Rect.fromLTWH(29, 29, 42, 42), color: a);
      oval(const Rect.fromLTWH(33, 33, 34, 34), color: b);
    case DiyMotif.constellation:
      const points = [
        Offset(15, 25),
        Offset(38, 40),
        Offset(60, 22),
        Offset(78, 58),
        Offset(52, 81),
        Offset(29, 67),
      ];
      for (var i = 0; i < points.length - 1; i++) {
        line(points[i], points[i + 1], width: 1);
      }
      for (final p in points) {
        oval(Rect.fromCircle(center: p, radius: 3.5), color: a);
        oval(Rect.fromCircle(center: p, radius: 1.6), color: b);
      }
    case DiyMotif.snowflake:
      for (var i = 0; i < 6; i++) {
        canvas.save();
        canvas.translate(50, 50);
        canvas.rotate(i * math.pi / 3);
        line(Offset.zero, const Offset(0, -37));
        for (final y in [-15.0, -27.0]) {
          line(Offset(0, y), Offset(-8, y - 7));
          line(Offset(0, y), Offset(8, y - 7));
        }
        canvas.restore();
      }
    case DiyMotif.heart:
      path(heart(const Offset(50, 51), 30));
      canvas.drawPath(
        Path()
          ..moveTo(27, 39)
          ..quadraticBezierTo(30, 26, 40, 29),
        Paint()
          ..color = Colors.white.withValues(alpha: .65)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    case DiyMotif.loveLetter:
      path(
        Path()..addRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(13, 24, 74, 52),
            const Radius.circular(4),
          ),
        ),
      );
      canvas.drawPath(
        Path()
          ..moveTo(13, 25)
          ..lineTo(50, 54)
          ..lineTo(87, 25)
          ..moveTo(13, 76)
          ..lineTo(40, 51)
          ..moveTo(87, 76)
          ..lineTo(60, 51),
        ink,
      );
      path(heart(const Offset(50, 51), 12), color: a, outline: false);
    case DiyMotif.bow:
    case DiyMotif.ribbon:
      final p = Path()
        ..moveTo(47, 44)
        ..cubicTo(14, 7, 5, 27, 17, 54)
        ..quadraticBezierTo(33, 59, 48, 49)
        ..moveTo(53, 44)
        ..cubicTo(86, 7, 95, 27, 83, 54)
        ..quadraticBezierTo(67, 59, 52, 49);
      path(p);
      path(
        Path()
          ..moveTo(45, 50)
          ..quadraticBezierTo(38, 76, 23, 90)
          ..lineTo(39, 85)
          ..lineTo(45, 97)
          ..quadraticBezierTo(56, 66, 51, 50)
          ..close(),
      );
      path(
        Path()
          ..moveTo(54, 50)
          ..quadraticBezierTo(57, 76, 79, 90)
          ..lineTo(62, 85)
          ..lineTo(56, 97)
          ..quadraticBezierTo(44, 66, 49, 50)
          ..close(),
      );
      oval(const Rect.fromLTWH(43, 37, 14, 20), color: a);
      canvas.drawPath(
        Path()
          ..moveTo(21, 28)
          ..quadraticBezierTo(28, 40, 42, 44)
          ..moveTo(79, 28)
          ..quadraticBezierTo(72, 40, 58, 44),
        ink..strokeWidth = .9,
      );
    case DiyMotif.lace:
      for (var row = 0; row < 4; row++) {
        for (var col = 0; col < 5; col++) {
          final x = 10 + col * 20.0, y = 15 + row * 22.0;
          canvas.drawCircle(Offset(x, y), 10, ink..strokeWidth = .8);
          canvas.drawCircle(Offset(x, y), 5, ink);
        }
      }
      for (var x = 0.0; x < 100; x += 10) {
        oval(Rect.fromCircle(center: Offset(x, 7), radius: 1), color: a);
      }
    case DiyMotif.pearls:
      final p = Path()
        ..moveTo(6, 23)
        ..quadraticBezierTo(50, 98, 94, 23);
      canvas.drawPath(p, ink..strokeWidth = .7);
      for (var i = 0; i < 12; i++) {
        final t = i / 11;
        final x = 6 + 88 * t, y = 23 + 150 * t * (1 - t);
        final r = Rect.fromCircle(center: Offset(x, y), radius: 4.5);
        canvas.drawOval(
          r,
          Paint()
            ..shader = RadialGradient(
              colors: [Colors.white, b, a],
            ).createShader(r),
        );
      }
    case DiyMotif.marble:
      for (var k = 0; k < 5; k++) {
        final p = Path()..moveTo(-5, k * 24.0);
        for (var j = 0; j < 8; j++) {
          p.relativeCubicTo(8, -7 + (j % 3) * 4, 9, 12, 15, 4);
        }
        canvas.drawPath(
          p,
          ink
            ..color = a.withValues(alpha: .7)
            ..strokeWidth = k.isEven ? 1.4 : .7,
        );
      }
    case DiyMotif.watercolor:
      for (var i = 0; i < 12; i++) {
        final r = Rect.fromCenter(
          center: Offset(15 + (i * 27) % 85, 14 + (i * 37) % 80),
          width: 53,
          height: 43,
        );
        canvas.drawOval(
          r,
          Paint()
            ..shader = RadialGradient(
              colors: [
                (i.isEven ? a : b).withValues(alpha: .25),
                a.withValues(alpha: 0),
              ],
            ).createShader(r),
        );
      }
    case DiyMotif.linen:
      for (var i = 0; i < 25; i++) {
        final x = i * 4.2;
        line(
          Offset(x, 0),
          Offset(x + math.sin(i) * 2, 100),
          color: a.withValues(alpha: .40),
          width: .5,
        );
        line(
          Offset(0, x),
          Offset(100, x + math.sin(i) * 2),
          color: b.withValues(alpha: .65),
          width: .6,
        );
      }
    case DiyMotif.glitter:
      final random = math.Random(17 + sticker.variant);
      for (var i = 0; i < 180; i++) {
        final c = Offset(random.nextDouble() * 100, random.nextDouble() * 100);
        canvas.drawCircle(
          c,
          .4 + random.nextDouble() * 1.3,
          Paint()
            ..color = (i.isEven ? a : b).withValues(
              alpha: .3 + random.nextDouble() * .7,
            ),
        );
      }
    case DiyMotif.checker:
      for (var y = 0; y < 6; y++) {
        for (var x = 0; x < 6; x++) {
          canvas.drawRect(
            Rect.fromLTWH(x * 17.0, y * 17.0, 17, 17),
            Paint()..color = ((x + y).isEven ? a : b).withValues(alpha: .65),
          );
        }
      }
    case DiyMotif.zebra:
      for (var k = 0; k < 8; k++) {
        final x = -15 + k * 18.0;
        final p = Path()
          ..moveTo(x, 0)
          ..cubicTo(x + 29, 30, x - 17, 64, x + 17, 100)
          ..lineTo(x + 24, 100)
          ..cubicTo(x - 3, 64, x + 37, 30, x + 8, 0)
          ..close();
        path(p, color: a.withValues(alpha: .8), outline: false);
      }
    case DiyMotif.leopard:
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          final c = Offset(10 + x * 25.0 + (y.isEven ? 6 : 0), 12 + y * 25.0);
          canvas.drawPath(
            Path()..addArc(
              Rect.fromCenter(center: c, width: 16, height: 13),
              -.3,
              4.5,
            ),
            ink..strokeWidth = 3,
          );
          oval(
            Rect.fromCircle(center: c, radius: 3),
            color: b.withValues(alpha: .7),
          );
        }
      }
    case DiyMotif.foil:
      final random = math.Random(81 + sticker.variant);
      for (var i = 0; i < 30; i++) {
        final x = random.nextDouble() * 95, y = random.nextDouble() * 95;
        path(
          Path()
            ..moveTo(x, y)
            ..lineTo(x + random.nextDouble() * 9, y - 3)
            ..lineTo(x + 13, y + 8)
            ..lineTo(x - 2, y + 5)
            ..close(),
          color: i.isEven ? a : b,
          outline: false,
        );
      }
    case DiyMotif.shell:
      path(
        Path()
          ..moveTo(50, 86)
          ..cubicTo(0, 79, 1, 30, 22, 21)
          ..quadraticBezierTo(50, -1, 78, 21)
          ..cubicTo(99, 30, 100, 79, 50, 86)
          ..close(),
      );
      for (var i = 0; i < 7; i++) {
        canvas.drawPath(
          Path()
            ..moveTo(50, 85)
            ..quadraticBezierTo(25 + i * 8.0, 46, 16 + i * 11.0, 29),
          ink..strokeWidth = .8,
        );
      }
    case DiyMotif.cloud:
      path(
        Path()
          ..moveTo(20, 70)
          ..cubicTo(-1, 68, 5, 38, 27, 41)
          ..cubicTo(29, 14, 64, 11, 70, 39)
          ..cubicTo(91, 29, 108, 68, 82, 71)
          ..close(),
      );
    case DiyMotif.cherry:
      canvas.drawPath(
        Path()
          ..moveTo(32, 59)
          ..quadraticBezierTo(50, 40, 53, 17)
          ..quadraticBezierTo(62, 36, 72, 61),
        ink
          ..color = const Color(0xFF698B6A)
          ..strokeWidth = 2,
      );
      oval(const Rect.fromLTWH(17, 52, 31, 31), color: a);
      oval(const Rect.fromLTWH(57, 55, 31, 31), color: a);
      oval(const Rect.fromLTWH(24, 57, 7, 7), color: b);
      oval(const Rect.fromLTWH(64, 60, 7, 7), color: b);
      path(
        Path()
          ..moveTo(52, 20)
          ..quadraticBezierTo(66, 9, 77, 21)
          ..quadraticBezierTo(65, 33, 52, 20)
          ..close(),
        color: const Color(0xFF91AB83),
        outline: false,
      );
    case DiyMotif.diamond:
      path(
        Path()
          ..moveTo(29, 14)
          ..lineTo(71, 14)
          ..lineTo(90, 39)
          ..lineTo(50, 89)
          ..lineTo(10, 39)
          ..close(),
      );
      canvas.drawPath(
        Path()
          ..moveTo(10, 39)
          ..lineTo(90, 39)
          ..moveTo(29, 14)
          ..lineTo(36, 39)
          ..lineTo(50, 89)
          ..lineTo(64, 39)
          ..lineTo(71, 14)
          ..moveTo(36, 39)
          ..lineTo(50, 14)
          ..lineTo(64, 39),
        ink..strokeWidth = .9,
      );
    case DiyMotif.iceLattice:
      const center = Offset(50, 50);
      final hub = <Offset>[];
      for (var i = 0; i < 6; i++) {
        final angle = i * math.pi / 3;
        hub.add(center + Offset(math.cos(angle), math.sin(angle)) * 13);
        canvas.save();
        canvas.translate(50, 50);
        canvas.rotate(angle);
        path(
          Path()..addPolygon(const [
            Offset(0, -39),
            Offset(8, -29),
            Offset(0, -14),
            Offset(-8, -29),
          ], true),
        );
        line(const Offset(0, -30), const Offset(0, -7), width: 1.3);
        canvas.restore();
      }
      path(Path()..addPolygon(hub, true));
      oval(Rect.fromCircle(center: center, radius: 4), color: a);
    case DiyMotif.facetedCrystal:
      const corners = [
        Offset(27, 14),
        Offset(73, 14),
        Offset(86, 32),
        Offset(86, 68),
        Offset(73, 86),
        Offset(27, 86),
        Offset(14, 68),
        Offset(14, 32),
      ];
      path(Path()..addPolygon(corners, true));
      const facets = [
        ([Offset(27, 14), Offset(73, 14), Offset(65, 31), Offset(35, 31)], .68),
        (
          [
            Offset(73, 14),
            Offset(86, 32),
            Offset(86, 68),
            Offset(65, 65),
            Offset(65, 31),
          ],
          .39,
        ),
        (
          [
            Offset(14, 32),
            Offset(27, 14),
            Offset(35, 31),
            Offset(35, 65),
            Offset(14, 68),
          ],
          .79,
        ),
        (
          [
            Offset(27, 86),
            Offset(14, 68),
            Offset(35, 65),
            Offset(65, 65),
            Offset(86, 68),
            Offset(73, 86),
          ],
          .53,
        ),
      ];
      for (final (points, light) in facets) {
        path(
          Path()..addPolygon(points, true),
          color: Color.lerp(a, b, light),
          outline: false,
        );
      }
      path(
        Path()..addPolygon(const [
          Offset(35, 31),
          Offset(65, 31),
          Offset(65, 65),
          Offset(35, 65),
        ], true),
        color: Color.lerp(b, Colors.white, .38),
        outline: false,
      );
      line(
        const Offset(37, 34),
        const Offset(58, 34),
        color: Colors.white,
        width: 2.7,
      );
      line(
        const Offset(37, 34),
        const Offset(37, 44),
        color: Colors.white,
        width: 2.0,
      );
    case DiyMotif.gildedArc:
      final arc = Path()
        ..moveTo(17, 62)
        ..cubicTo(23, 91, 70, 90, 85, 35)
        ..moveTo(26, 61)
        ..cubicTo(38, 75, 63, 68, 75, 41);
      canvas.drawPath(arc, ink..strokeWidth = 2.6);
      for (final (center, radius) in const [
        (Offset(17, 62), 4.0),
        (Offset(42, 77), 5.0),
        (Offset(67, 63), 7.5),
        (Offset(85, 35), 4.0),
      ]) {
        oval(
          Rect.fromCircle(center: center, radius: radius),
          color: a,
        );
        oval(
          Rect.fromCircle(
            center: center - const Offset(1, 1.5),
            radius: radius * .67,
          ),
        );
      }
      line(const Offset(64, 40), const Offset(64, 22), color: b, width: 2.8);
      line(const Offset(58, 31), const Offset(70, 31), color: b, width: 2.8);
    case DiyMotif.hollySprig:
      for (final (center, angle) in const [
        (Offset(49, 56), -1.04),
        (Offset(50, 55), .90),
      ]) {
        canvas.save();
        canvas.translate(center.dx, center.dy);
        canvas.rotate(angle);
        path(
          Path()
            ..moveTo(0, 4)
            ..quadraticBezierTo(-17, 0, -14, -12)
            ..quadraticBezierTo(-7, -13, -15, -23)
            ..quadraticBezierTo(-5, -22, 0, -41)
            ..quadraticBezierTo(6, -24, 15, -22)
            ..quadraticBezierTo(9, -13, 15, -12)
            ..quadraticBezierTo(16, -1, 0, 4)
            ..close(),
        );
        line(const Offset(0, 0), const Offset(0, -32), width: 1.4);
        canvas.restore();
      }
      for (final center in const [
        Offset(41, 57),
        Offset(57, 55),
        Offset(51, 70),
      ]) {
        oval(
          Rect.fromCircle(center: center, radius: 8),
          color: const Color(0xFFAB394B),
        );
        oval(
          Rect.fromCircle(center: center - const Offset(2.5, 2.5), radius: 2.6),
          color: const Color(0xFFF5ABB3),
        );
      }
    case DiyMotif.pineSprig:
      canvas.drawPath(
        Path()
          ..moveTo(24, 85)
          ..quadraticBezierTo(56, 57, 69, 18)
          ..moveTo(45, 63)
          ..quadraticBezierTo(65, 55, 86, 59),
        ink..strokeWidth = 2.3,
      );
      for (var i = 0; i < 7; i++) {
        final root = Offset(33 + i * 5.3, 73 - i * 7.4);
        line(root, root + Offset(-21 + i * 1.0, -15 - i * 1.2), width: 1.7);
        line(
          root,
          root + Offset(18 + i * 1.1, -24 + i * .7),
          color: b,
          width: 2,
        );
      }
      for (var i = 0; i < 4; i++) {
        final root = Offset(54 + i * 8.0, 59 - i * .8);
        line(root, root + const Offset(11, 13), color: b, width: 1.6);
      }
    case DiyMotif.porcelainVine:
      canvas.drawPath(
        Path()
          ..moveTo(18, 80)
          ..cubicTo(57, 84, 24, 26, 67, 33)
          ..quadraticBezierTo(82, 38, 80, 55)
          ..quadraticBezierTo(79, 65, 70, 62)
          ..moveTo(45, 62)
          ..quadraticBezierTo(57, 49, 70, 51)
          ..moveTo(49, 44)
          ..quadraticBezierTo(51, 32, 38, 26),
        ink..strokeWidth = 2.5,
      );
      for (final (center, radius) in const [
        (Offset(32, 23), 15.0),
        (Offset(73, 28), 17.0),
        (Offset(65, 56), 10.0),
      ]) {
        path(petal(center, radius, 5), color: b);
        oval(
          Rect.fromCircle(center: center, radius: radius * .24),
          color: a,
        );
      }
    case DiyMotif.plumBough:
      canvas.drawPath(
        Path()
          ..moveTo(15, 76)
          ..lineTo(38, 65)
          ..lineTo(56, 47)
          ..lineTo(72, 42)
          ..lineTo(86, 27)
          ..moveTo(37, 66)
          ..quadraticBezierTo(33, 44, 24, 34)
          ..moveTo(56, 47)
          ..quadraticBezierTo(63, 33, 57, 18),
        ink
          ..color = const Color(0xFF604347)
          ..strokeWidth = 3.0,
      );
      for (final (center, radius) in const [
        (Offset(25, 34), 12.0),
        (Offset(43, 54), 13.0),
        (Offset(56, 19), 10.0),
        (Offset(82, 32), 14.0),
      ]) {
        path(petal(center, radius, 5), color: a, outline: false);
        path(petal(center, radius * .73, 5), outline: false);
        oval(
          Rect.fromCircle(center: center, radius: 2.6),
          color: const Color(0xFFF4D596),
        );
      }
    case DiyMotif.candyHook:
      final cane = Path()
        ..moveTo(52, 83)
        ..lineTo(52, 35)
        ..cubicTo(52, 20, 31, 20, 31, 36)
        ..cubicTo(31, 45, 17, 45, 17, 36)
        ..cubicTo(17, 4, 67, 4, 67, 35)
        ..lineTo(67, 83)
        ..quadraticBezierTo(67, 96, 52, 89)
        ..close();
      path(cane, outline: false);
      canvas.save();
      canvas.clipPath(cane);
      for (var i = 0; i < 6; i++) {
        final y = 8.0 + i * 15.5;
        line(Offset(10, y + 28), Offset(75, y - 6), width: 6.5);
      }
      canvas.restore();
      canvas.drawPath(cane, ink);
    case DiyMotif.goldFoilShard:
      const rim = [
        Offset(18, 36),
        Offset(51, 18),
        Offset(63, 25),
        Offset(83, 39),
        Offset(76, 67),
        Offset(60, 69),
        Offset(51, 86),
        Offset(23, 74),
      ];
      const pivot = Offset(50, 46);
      for (var i = 0; i < rim.length; i++) {
        final tint = i.isEven ? b : a;
        path(
          Path()..addPolygon([rim[i], rim[(i + 1) % rim.length], pivot], true),
          color: tint,
          outline: false,
        );
      }
      line(rim[1], pivot, color: const Color(0xFFFFECC4), width: 2.0);
      line(pivot, rim[4], color: const Color(0xFFFFECC4), width: 2.0);
    case DiyMotif.inkRidges:
      final distant = Path()
        ..moveTo(7, 63)
        ..quadraticBezierTo(17, 57, 24, 53)
        ..lineTo(35, 38)
        ..lineTo(46, 28)
        ..lineTo(57, 38)
        ..quadraticBezierTo(65, 55, 79, 60)
        ..lineTo(90, 65)
        ..lineTo(90, 84)
        ..lineTo(7, 84)
        ..close();
      final near = Path()
        ..moveTo(8, 75)
        ..lineTo(29, 67)
        ..lineTo(39, 73)
        ..lineTo(54, 62)
        ..lineTo(65, 47)
        ..lineTo(77, 60)
        ..lineTo(93, 76)
        ..lineTo(93, 90)
        ..lineTo(8, 90)
        ..close();
      for (final (ridge, color, bounds) in [
        (distant, b, const Rect.fromLTRB(7, 28, 90, 83)),
        (near, a, const Rect.fromLTRB(8, 47, 93, 90)),
      ]) {
        canvas.drawPath(
          ridge,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                color,
                color.withValues(alpha: .76),
                color.withValues(alpha: 0),
              ],
              stops: const [0, .56, 1],
            ).createShader(bounds),
        );
      }
      oval(
        Rect.fromCircle(center: const Offset(25, 25), radius: 6),
        color: const Color(0xFFB76255),
      );
  }
}
