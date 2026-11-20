import 'dart:math' as math;
import 'dart:ui';

import 'nail_models.dart';

enum DiyLayerKind { image, sticker, stroke }

class DiyLayer {
  const DiyLayer({
    required this.id,
    required this.kind,
    this.name = '',
    this.x = .5,
    this.y = .5,
    this.width = .5,
    this.height = .35,
    this.scale = 1,
    this.rotation = 0,
    this.opacity = 1,
    this.locked = false,
    this.erase = false,
    this.imagePath,
    this.stickerId,
    this.color = const Color(0xFF7A3F4E),
    this.strokeWidth = .012,
    this.points = const [],
  });

  final String id, name;
  final DiyLayerKind kind;
  final double x, y, width, height, scale, rotation, opacity, strokeWidth;
  final bool locked, erase;
  final String? imagePath, stickerId;
  final Color color;
  final List<Offset> points;

  DiyLayer copyWith({
    String? name,
    double? x,
    double? y,
    double? width,
    double? height,
    double? scale,
    double? rotation,
    double? opacity,
    bool? locked,
    String? imagePath,
    Color? color,
  }) => DiyLayer(
    id: id,
    kind: kind,
    name: name ?? this.name,
    x: x ?? this.x,
    y: y ?? this.y,
    width: width ?? this.width,
    height: height ?? this.height,
    scale: scale ?? this.scale,
    rotation: rotation ?? this.rotation,
    opacity: opacity ?? this.opacity,
    locked: locked ?? this.locked,
    erase: erase,
    imagePath: imagePath ?? this.imagePath,
    stickerId: stickerId,
    color: color ?? this.color,
    strokeWidth: strokeWidth,
    points: points,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'scale': scale,
    'rotation': rotation,
    'opacity': opacity,
    'locked': locked,
    'imagePath': imagePath,
    'stickerId': stickerId,
    'erase': erase,
    'color': color.toARGB32(),
    'strokeWidth': strokeWidth,
    'points': [
      for (final p in points) [p.dx, p.dy],
    ],
  };

  factory DiyLayer.fromJson(Map<String, dynamic> json, {String? directory}) {
    double number(String key, double fallback, double min, double max) {
      final value = json[key];
      if (value is! num || !value.isFinite) return fallback;
      return value.toDouble().clamp(min, max);
    }

    final storedPath = json['imagePath'] as String?;
    final relative = storedPath != null && !storedPath.startsWith('/');
    final path = relative && directory != null
        ? '$directory/$storedPath'
        : storedPath;
    return DiyLayer(
      id: json['id'] as String,
      kind: DiyLayerKind.values.firstWhere(
        (v) => v.name == json['kind'],
        orElse: () => throw const FormatException('无法读取这个图层类型。'),
      ),
      name: json['name'] as String? ?? '',
      x: number('x', .5, -2, 3),
      y: number('y', .5, -2, 3),
      width: number('width', .5, .001, 5),
      height: number('height', .35, .001, 5),
      scale: number('scale', 1, .05, 8),
      rotation: number('rotation', 0, -math.pi * 20, math.pi * 20),
      opacity: number('opacity', 1, 0, 1),
      locked: json['locked'] == true,
      erase: json['erase'] == true,
      imagePath: path,
      stickerId: json['stickerId'] as String?,
      color: Color((json['color'] as num?)?.toInt() ?? 0xFF7A3F4E),
      strokeWidth: number('strokeWidth', .012, .001, .2),
      points: List.unmodifiable([
        for (final raw in json['points'] as List? ?? const [])
          if (raw is List &&
              raw.length == 2 &&
              raw[0] is num &&
              raw[1] is num &&
              (raw[0] as num).isFinite &&
              (raw[1] as num).isFinite)
            Offset((raw[0] as num).toDouble(), (raw[1] as num).toDouble()),
      ]),
    );
  }
}

class DiyNailDesign {
  const DiyNailDesign({
    this.name = '我的美甲',
    this.baseColor = const Color(0xFFFFF0E8),
    this.layers = const [],
  });

  final String name;
  final Color baseColor;
  final List<DiyLayer> layers;

  DiyNailDesign copyWith({
    String? name,
    Color? baseColor,
    List<DiyLayer>? layers,
  }) => DiyNailDesign(
    name: name ?? this.name,
    baseColor: baseColor ?? this.baseColor,
    layers: layers == null ? this.layers : List.unmodifiable(layers),
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'name': name,
    'baseColor': baseColor.toARGB32(),
    'layers': [for (final layer in layers) layer.toJson()],
  };

  factory DiyNailDesign.fromJson(
    Map<String, dynamic> json, {
    String? directory,
  }) => DiyNailDesign(
    name: json['name'] as String? ?? '我的美甲',
    baseColor: Color((json['baseColor'] as num?)?.toInt() ?? 0xFFFFF0E8),
    layers: List.unmodifiable([
      for (final raw in json['layers'] as List? ?? const [])
        DiyLayer.fromJson(
          Map<String, dynamic>.from(raw as Map),
          directory: directory,
        ),
    ]),
  );
}

class DiySavedStyle {
  const DiySavedStyle({
    required this.id,
    required this.style,
    required this.design,
    required this.updatedAt,
  });
  final String id;
  final NailStyle style;
  final DiyNailDesign design;
  final DateTime updatedAt;
  String get name => design.name;
}
