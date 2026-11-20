import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

part 'nail_catalog.dart';

// The numeric order is part of the fragment shader contract. Append new
// patterns rather than reordering the original solid/french/ombre/shimmer.
enum NailPattern {
  solid('纯色'),
  french('经典法式'),
  ombre('柔和渐变'),
  shimmer('细闪'),
  jelly('奶透'),
  diagonalFrench('斜法式'),
  reverseFrench('月牙法式'),
  aura('腮红晕染'),
  catEye('猫眼'),
  chrome('金属'),
  pearl('珠光'),
  marble('石纹'),
  flowers('小花'),
  leaves('叶片'),
  stripes('线条'),
  checker('棋盘'),
  dots('波点'),
  hearts('爱心'),
  stars('星星'),
  bows('蝴蝶结'),
  leopard('豹纹'),
  zebra('斑马纹'),
  cow('奶牛纹'),
  tortoiseshell('玳瑁'),
  goldVein('金丝纹'),
  velvet('天鹅绒磁光'),
  microFrench('极细法式'),
  chromeFrench('金属勾边'),
  amberInlay('琥珀叠色'),
  wovenPlaid('织物格纹'),
  fawnSpots('小鹿斑点'),
  snowCrystal('六角雪晶'),
  giftRibbon('手绘丝带'),
  winterSprig('冬青果枝'),
  candyCane('旋纹糖杖'),
  jadeCloud('玉石云絮'),
  inkPeaks('水墨山峦'),
  porcelainBranch('瓷绘花枝'),
  frostedGlaze('冰霜珠光'),
  foilFlakes('不规则碎箔'),
  crystalGems('切面小钻');

  const NailPattern(this.label);
  final String label;
}

enum NailCategory {
  classic('纯色经典'),
  nude('裸色通勤'),
  jelly('奶透果冻'),
  french('法式边缘'),
  gradient('渐变晕染'),
  sparkle('闪粉珠光'),
  magnetic('猫眼金属'),
  botanical('花卉植物'),
  geometry('线条几何'),
  playful('甜酷趣味'),
  animal('动物纹理'),
  stone('石纹艺术'),
  winterMagnetic('秋冬磁光'),
  fineFrench('细边法式'),
  winterPrints('秋冬纹样'),
  holidayArt('节日手绘'),
  orientalArt('国风手绘'),
  frostJewels('霜光金饰');

  const NailCategory(this.label);
  final String label;
}

class NailStyle {
  const NailStyle(
    this.id,
    this.name,
    this.subtitle,
    this.color,
    this.pattern, {
    this.accent = const Color(0xFFFFF5EF),
    this.category = NailCategory.classic,
    this.coverage = .98,
    this.patternScale = 1.0,
    this.variant = 0.0,
    this.finishGloss = 1.0,
    this.texturePath,
  }) : assert(coverage >= 0 && coverage <= 1),
       assert(patternScale > 0),
       assert(variant >= 0 && variant <= 1),
       assert(finishGloss > 0);

  final String id;
  final String name;
  final String subtitle;
  final Color color;
  final Color accent;
  final NailPattern pattern;
  final NailCategory category;

  /// Polish opacity; jelly shades intentionally let the original nail show.
  final double coverage;

  /// Spatial motif size and a stable layout/material variation in [0, 1].
  final double patternScale;
  final double variant;
  final double finishGloss;

  /// App-owned flattened DIY artwork. A new revision uses a new file path.
  final String? texturePath;
  bool get isCustom => texturePath != null;

  static final List<NailStyle> all = _builtInNailCatalog;
  static final Map<String, NailStyle> _byId = Map.unmodifiable({
    for (final style in all) style.id: style,
  });

  static NailStyle? byId(String id) => _byId[id];
}

/// Coordinates are always pixels in the orientation-corrected working image.
/// Local +Y points from the nail tip towards its root.
class NailRegion {
  const NailRegion({
    required this.id,
    required this.label,
    required this.center,
    required this.width,
    required this.height,
    required this.angle,
    required this.maskRgba,
    this.maskWidth = 64,
    this.maskHeight = 96,
    this.isManual = false,
    this.enabled = true,
  });
  final int id;
  final String label;
  final Offset center;
  final double width;
  final double height;
  final double angle;
  final Uint8List maskRgba;
  final int maskWidth;
  final int maskHeight;
  final bool isManual;
  final bool enabled;

  NailRegion copyWith({
    Offset? center,
    double? width,
    double? height,
    double? angle,
    bool? enabled,
    Uint8List? maskRgba,
    int? maskWidth,
    int? maskHeight,
  }) => NailRegion(
    id: id,
    label: label,
    center: center ?? this.center,
    width: width ?? this.width,
    height: height ?? this.height,
    angle: angle ?? this.angle,
    maskRgba: maskRgba ?? this.maskRgba,
    maskWidth: maskWidth ?? this.maskWidth,
    maskHeight: maskHeight ?? this.maskHeight,
    isManual: isManual,
    enabled: enabled ?? this.enabled,
  );

  Offset toLocal(Offset point) {
    final d = point - center;
    return Offset(
      d.dx * math.cos(angle) + d.dy * math.sin(angle),
      -d.dx * math.sin(angle) + d.dy * math.cos(angle),
    );
  }

  bool contains(Offset point) {
    final p = toLocal(point);
    return p.dx.abs() <= width / 2 && p.dy.abs() <= height / 2;
  }

  factory NailRegion.manual(int id, Offset center, double imageWidth) {
    const mw = 64, mh = 96;
    final rgba = Uint8List(mw * mh * 4);
    for (var y = 0; y < mh; y++) {
      for (var x = 0; x < mw; x++) {
        final nx = (x + .5 - mw / 2) / (mw * .47);
        final ny = (y + .5 - mh / 2) / (mh * .47);
        final distance = math.sqrt(nx * nx + ny * ny);
        final a = ((1 - distance) * 30).clamp(0.0, 1.0);
        final i = (y * mw + x) * 4;
        final channel = (a * 255).round();
        rgba[i] = rgba[i + 1] = rgba[i + 2] = rgba[i + 3] = channel;
      }
    }
    return NailRegion(
      id: id,
      label: '手动甲面',
      center: center,
      width: imageWidth * .065,
      height: imageWidth * .095,
      angle: 0,
      maskRgba: rgba,
      isManual: true,
    );
  }
}

class HandObservation {
  const HandObservation(this.points, this.handedness, {this.pointConfidences});
  final List<Offset> points; // Normalized in the same canonical image.
  final String handedness;
  final List<double>? pointConfidences; // Available from Apple Vision.
}

/// Evidence for reviewing an accepted nail, not a confirmed segmentation error.
enum NailEdgeReviewReason {
  photoEdge('甲面贴近照片边缘'),
  localFitMismatch('全图与局部识别不一致'),
  softBoundary('甲缘信号偏弱'),
  localRecovery('局部复查找到，建议确认');

  const NailEdgeReviewReason(this.label);
  final String label;
}

class AnalysisResult {
  const AnalysisResult({
    required this.imagePath,
    required this.pngBytes,
    required this.width,
    required this.height,
    required this.nails,
    required this.elapsed,
    required this.handAvailable,
    this.notice,
    this.edgeReviewById = const {},
  });
  final String imagePath;
  final Uint8List pngBytes;
  final int width, height;
  final List<NailRegion> nails;
  final Duration elapsed;
  final bool handAvailable;
  final String? notice;
  final Map<int, NailEdgeReviewReason> edgeReviewById;
}
