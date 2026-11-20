import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../models/nail_models.dart';
import 'nail_surface.dart';

/// Direction toward the lamp in photograph coordinates (x right, y down).
/// This is a two-dimensional lighting preview, not recovered scene lighting.
const double defaultNailLightDirection = -3 * math.pi / 4;
const double defaultNailCoatAmount = 1;

/// One binding contract for photographed nails and catalog sample nails.
void configureNailShader(
  ui.FragmentShader shader, {
  required Size size,
  required Offset center,
  required double angle,
  required ui.Image photo,
  required ui.Image mask,
  required NailStyle style,
  required double gloss,
  double coatAmount = defaultNailCoatAmount,
  double lightDirection = defaultNailLightDirection,
  ui.Image? design,
  ui.Image? warp,
}) {
  final values = <double>[
    size.width,
    size.height,
    center.dx,
    center.dy,
    angle,
    photo.width.toDouble(),
    photo.height.toDouble(),
    style.color.r,
    style.color.g,
    style.color.b,
    style.accent.r,
    style.accent.g,
    style.accent.b,
    style.pattern.index.toDouble(),
    gloss,
    style.coverage,
    style.patternScale,
    style.variant,
    style.finishGloss,
    design == null ? 0 : 1,
    warp == null ? 0 : 1,
    lightDirection - angle,
    coatAmount,
  ];
  for (var i = 0; i < values.length; i++) {
    shader.setFloat(i, values[i]);
  }
  shader.setImageSampler(0, photo);
  shader.setImageSampler(1, mask);
  shader.setImageSampler(2, design ?? photo);
  shader.setImageSampler(3, warp ?? photo);
}

/// Decodes local DIY artwork with a bounded GPU texture size.
Future<ui.Image> loadNailStyleTexture(
  String path, {
  int maxDimension = 1024,
}) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    final file = File(path);
    if (await file.length() > 32 * 1024 * 1024) {
      throw const FormatException('款式图片太大，请换一张图片重新保存。');
    }
    buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final ratio = math.min(
      1.0,
      maxDimension / math.max(descriptor.width, descriptor.height),
    );
    codec = await descriptor.instantiateCodec(
      targetWidth: math.max(1, (descriptor.width * ratio).round()),
      targetHeight: math.max(1, (descriptor.height * ratio).round()),
    );
    return (await codec.getNextFrame()).image;
  } on FormatException {
    rethrow;
  } catch (_) {
    throw const FormatException('无法读取这张款式图片，请重新导入或保存。');
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

// Sample the shared Bezier outline only once. The stored bounds lie inside
// the visible canonical nail so art hidden in the canvas corners stays hidden.
class _CanonicalSurface {
  _CanonicalSurface() {
    const edge = 128;
    final path = standardNailPath(const Size(128, 128));
    for (var y = 0; y < edge; y++) {
      var first = edge, last = -1;
      for (var x = 0; x < edge; x++) {
        if (path.contains(Offset(x + .5, y + .5))) {
          first = math.min(first, x);
          last = x;
        }
      }
      if (last >= first) {
        left[y] = (first + .5) / edge;
        right[y] = (last + .5) / edge;
        top = math.min(top, y);
        bottom = y;
      }
    }
  }
  final left = List<double>.filled(128, .5);
  final right = List<double>.filled(128, .5);
  int top = 127, bottom = 0;

  Offset uv(double u, double v) {
    final row = top + v.clamp(0.0, 1.0) * (bottom - top);
    final first = row.floor().clamp(top, bottom);
    final last = math.min(bottom, first + 1);
    final fraction = row - first;
    final l = left[first] * (1 - fraction) + left[last] * fraction;
    final r = right[first] * (1 - fraction) + right[last] * fraction;
    final curved =
        .5 + math.asin(((u - .5) * 1.52).clamp(-.76, .76)) / 1.726626;
    return Offset(l + curved * (r - l), (row + .5) / 128);
  }
}

final _canonicalSurface = _CanonicalSurface();

class NailRenderer extends ChangeNotifier {
  NailRenderer(this.photo, this.program);
  final ui.Image photo;
  final ui.FragmentProgram program;
  final Map<int, ui.Image> masks = {};
  final Map<int, ui.Image> warps = {};
  final Map<int, ui.FragmentShader> _shaders = {};
  final Map<int, (int, int, int)> _maskKeys = {};
  final Map<int, int> _maskVersions = {};
  final Map<int, Future<void>> _maskLoading = {};
  final LinkedHashMap<String, ui.Image> _designs = LinkedHashMap();
  final Map<String, Future<void>> _designLoading = {};
  final Set<String> _failedDesigns = {};
  Set<String> _activeDesigns = {};
  bool _disposed = false;

  Future<void> addMask(NailRegion region) {
    if (_disposed) return Future.value();
    if (region.maskWidth <= 0 ||
        region.maskHeight <= 0 ||
        region.maskRgba.length != region.maskWidth * region.maskHeight * 4) {
      return Future.error(const FormatException('甲面边缘数据不完整。'));
    }
    // Check content too: interactive mask editing may reuse a mutable byte list.
    var hash = 17;
    for (final byte in region.maskRgba) {
      hash = (hash * 31 + byte) & 0x1fffffff;
    }
    final key = (region.maskWidth, region.maskHeight, hash);
    if (_maskKeys[region.id] == key) {
      return _maskLoading[region.id] ?? Future.value();
    }
    final version = (_maskVersions[region.id] ?? 0) + 1;
    _maskVersions[region.id] = version;
    _maskKeys[region.id] = key;
    late final Future<void> task;
    task = _decodeMask(region, version)
        .catchError((Object error, StackTrace stack) {
          if (_maskVersions[region.id] == version) _maskKeys.remove(region.id);
          Error.throwWithStackTrace(error, stack);
        })
        .whenComplete(() {
          if (identical(_maskLoading[region.id], task)) {
            _maskLoading.remove(region.id);
          }
        });
    _maskLoading[region.id] = task;
    return task;
  }

  Future<void> _decodeMask(NailRegion region, int version) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? maskImage;
    ui.Image? warpImage;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(region.maskRgba);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: region.maskWidth,
        height: region.maskHeight,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      maskImage = (await codec.getNextFrame()).image;
      warpImage = await _createWarp(region);
      if (_disposed || _maskVersions[region.id] != version) {
        return;
      } else {
        _shaders.remove(region.id)?.dispose();
        masks.remove(region.id)?.dispose();
        warps.remove(region.id)?.dispose();
        masks[region.id] = maskImage;
        warps[region.id] = warpImage;
        maskImage = null;
        warpImage = null;
        notifyListeners();
      }
    } finally {
      maskImage?.dispose();
      warpImage?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<ui.Image> _createWarp(NailRegion region) async {
    final width = region.maskWidth, height = region.maskHeight;
    final left = List<double>.filled(height, double.nan);
    final right = List<double>.filled(height, double.nan);
    var top = height, bottom = -1;
    for (var y = 0; y < height; y++) {
      var first = width, last = -1;
      for (var x = 0; x < width; x++) {
        if (region.maskRgba[(y * width + x) * 4 + 3] >= 64) {
          first = math.min(first, x);
          last = x;
        }
      }
      if (last >= first) {
        left[y] = first - .5;
        right[y] = last + .5;
        top = math.min(top, y);
        bottom = y;
      }
    }
    final smoothedLeft = List<double>.filled(height, 0);
    final smoothedRight = List<double>.filled(height, width.toDouble());
    if (bottom >= top) {
      for (var y = 0; y < height; y++) {
        var l = 0.0, r = 0.0, weight = 0.0;
        final center = y.clamp(top, bottom);
        for (var delta = -2; delta <= 2; delta++) {
          final row = center + delta;
          if (row < top || row > bottom || !left[row].isFinite) continue;
          final amount = (3 - delta.abs()).toDouble();
          l += left[row] * amount;
          r += right[row] * amount;
          weight += amount;
        }
        if (weight == 0) {
          // Internal gaps retain the nearest outline; their alpha remains zero.
          for (var distance = 1; distance < height; distance++) {
            final row = center - distance;
            final other = center + distance;
            final match = row >= top && left[row].isFinite
                ? row
                : other <= bottom && left[other].isFinite
                ? other
                : null;
            if (match != null) {
              l = left[match];
              r = right[match];
              weight = 1;
              break;
            }
          }
        }
        if (weight > 0) {
          smoothedLeft[y] = l / weight;
          smoothedRight[y] = r / weight;
        }
      }
    }
    final rgba = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      final l = smoothedLeft[y], r = smoothedRight[y];
      final v = bottom >= top
          ? ((y - top + .5) / (bottom - top + 1)).clamp(0.0, 1.0)
          : (y + .5) / height;
      for (var x = 0; x < width; x++) {
        final u = bottom >= top
            ? ((x - l) / math.max(1.0, r - l)).clamp(0.0, 1.0)
            : (x + .5) / width;
        final index = (y * width + x) * 4;
        final mapped = _canonicalSurface.uv(u, v);
        rgba[index] = (mapped.dx * 255).round();
        rgba[index + 1] = (mapped.dy * 255).round();
        rgba[index + 3] = 255;
      }
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  Future<void> prepareStyle(NailStyle style) {
    final path = style.texturePath;
    if (path == null || _disposed) return Future.value();
    if (_designs.containsKey(path)) return Future.value();
    final pending = _designLoading[path];
    if (pending != null) return pending;
    _failedDesigns.remove(path);
    late final Future<void> task;
    task = loadNailStyleTexture(path)
        .then((image) {
          if (_disposed) {
            image.dispose();
            return;
          }
          _designs[path] = image;
          _trimDesigns();
          notifyListeners();
        })
        .catchError((Object error, StackTrace stack) {
          _failedDesigns.add(path);
          Error.throwWithStackTrace(error, stack);
        })
        .whenComplete(() {
          if (identical(_designLoading[path], task)) {
            _designLoading.remove(path);
          }
        });
    _designLoading[path] = task;
    return task;
  }

  Future<void> prepareStyles(Iterable<NailStyle> styles) async {
    // Two fingers can still reference different saved revisions of one DIY id.
    final unique = styles.toSet().toList(growable: false);
    _activeDesigns = {
      for (final style in unique)
        if (style.texturePath != null) style.texturePath!,
    };
    await Future.wait(unique.map(prepareStyle));
  }

  void _trimDesigns() {
    // Current nails are pinned. Other revisions are reloaded for undo as needed.
    while (_designs.length > 24) {
      final candidates = _designs.keys.where(
        (p) => !_activeDesigns.contains(p),
      );
      if (candidates.isEmpty) break;
      _designs.remove(candidates.first)?.dispose();
    }
  }

  ui.Image? _designFor(NailStyle style) {
    final path = style.texturePath;
    if (path == null) return null;
    final image = _designs.remove(path);
    if (image != null) {
      _designs[path] = image;
      return image;
    }
    if (!_failedDesigns.contains(path)) {
      unawaited(prepareStyle(style).catchError((Object _) {}));
    }
    return null;
  }

  void paint(
    Canvas canvas,
    Size size,
    List<NailRegion> nails,
    Map<int, NailStyle> styles,
    double gloss, {
    Map<int, double> coatAmounts = const {},
    double lightDirection = defaultNailLightDirection,
    bool original = false,
    int? selectedId,
    bool outlines = false,
  }) {
    if (_disposed) return;
    _activeDesigns = {
      for (final nail in nails.where((n) => n.enabled))
        if (styles[nail.id]?.texturePath != null) styles[nail.id]!.texturePath!,
    };
    final sx = size.width / photo.width, sy = size.height / photo.height;
    canvas.save();
    canvas.scale(sx, sy);
    canvas.drawImage(photo, Offset.zero, Paint());
    if (!original) {
      for (final nail in nails.where((n) => n.enabled)) {
        final mask = masks[nail.id];
        if (mask == null) continue;
        final style = styles[nail.id] ?? NailStyle.all.first;
        final shader = _shaders.putIfAbsent(
          nail.id,
          () => program.fragmentShader(),
        );
        configureNailShader(
          shader,
          size: Size(nail.width, nail.height),
          center: nail.center,
          angle: nail.angle,
          photo: photo,
          mask: mask,
          style: style,
          gloss: gloss,
          coatAmount: coatAmounts[nail.id] ?? defaultNailCoatAmount,
          lightDirection: lightDirection,
          design: _designFor(style),
          warp: warps[nail.id],
        );
        canvas.save();
        canvas.translate(nail.center.dx, nail.center.dy);
        canvas.rotate(nail.angle);
        canvas.translate(-nail.width / 2, -nail.height / 2);
        canvas.drawRect(
          Rect.fromLTWH(0, 0, nail.width, nail.height),
          Paint()..shader = shader,
        );
        canvas.restore();
      }
    }
    if (outlines && !original) {
      for (final nail in nails.where((n) => n.enabled)) {
        final selected = nail.id == selectedId;
        final outlineColor = selected
            ? const Color(0xFF8A4257)
            : const Color(0xBBFFFFFF);
        canvas.save();
        canvas.translate(nail.center.dx, nail.center.dy);
        canvas.rotate(nail.angle);
        final rect = Rect.fromCenter(
          center: Offset.zero,
          width: nail.width,
          height: nail.height,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect.inflate(3 / sx),
            Radius.circular(6 / sx),
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = (selected ? 2 : 1) / sx
            ..color = outlineColor,
        );
        if (selected) {
          canvas.drawCircle(
            Offset(0, -nail.height / 2 - 5 / sx),
            3 / sx,
            Paint()..color = outlineColor,
          );
        }
        canvas.restore();
      }
    }
    canvas.restore();
  }

  Future<ui.Image> export(
    List<NailRegion> nails,
    Map<int, NailStyle> styles,
    double gloss, {
    Map<int, double> coatAmounts = const {},
    double lightDirection = defaultNailLightDirection,
  }) async {
    await Future.wait(nails.where((nail) => nail.enabled).map(addMask));
    await prepareStyles(styles.values);
    if (_disposed) throw StateError('试戴画面已关闭。');
    final recorder = ui.PictureRecorder();
    paint(
      Canvas(recorder),
      Size(photo.width.toDouble(), photo.height.toDouble()),
      nails,
      styles,
      gloss,
      coatAmounts: coatAmounts,
      lightDirection: lightDirection,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(photo.width, photo.height);
    } finally {
      picture.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final shader in _shaders.values) {
      shader.dispose();
    }
    for (final mask in masks.values) {
      mask.dispose();
    }
    for (final warp in warps.values) {
      warp.dispose();
    }
    for (final image in _designs.values) {
      image.dispose();
    }
    _designs.clear();
    photo.dispose();
    super.dispose();
  }
}

class NailScene extends StatelessWidget {
  const NailScene({
    super.key,
    required this.renderer,
    required this.nails,
    required this.styles,
    required this.gloss,
    this.coatAmounts = const {},
    this.lightDirection = defaultNailLightDirection,
    this.original = false,
    this.selectedId,
    this.outlines = false,
    this.onTap,
    this.onDrag,
    this.onDragStart,
  });
  final NailRenderer renderer;
  final List<NailRegion> nails;
  final Map<int, NailStyle> styles;
  final double gloss;
  final Map<int, double> coatAmounts;
  final double lightDirection;
  final bool original, outlines;
  final int? selectedId;
  final ValueChanged<Offset>? onTap;
  final ValueChanged<Offset>? onDrag;
  final VoidCallback? onDragStart;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final natural = Size(
        renderer.photo.width.toDouble(),
        renderer.photo.height.toDouble(),
      );
      final fitted = applyBoxFit(
        BoxFit.contain,
        natural,
        box.biggest,
      ).destination;
      final scale = natural.width / fitted.width;
      return Center(
        child: SizedBox(
          width: fitted.width,
          height: fitted.height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: onTap == null
                ? null
                : (d) => onTap!(d.localPosition * scale),
            onPanUpdate: onDrag == null
                ? null
                : (d) => onDrag!(d.delta * scale),
            onPanStart: onDrag == null ? null : (_) => onDragStart?.call(),
            child: CustomPaint(
              painter: _ScenePainter(
                renderer: renderer,
                nails: nails,
                styles: styles,
                gloss: gloss,
                coatAmounts: coatAmounts,
                lightDirection: lightDirection,
                original: original,
                selectedId: selectedId,
                outlines: outlines,
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _ScenePainter extends CustomPainter {
  _ScenePainter({
    required this.renderer,
    required this.nails,
    required this.styles,
    required this.gloss,
    required this.coatAmounts,
    required this.lightDirection,
    required this.original,
    required this.selectedId,
    required this.outlines,
  }) : super(repaint: renderer);
  final NailRenderer renderer;
  final List<NailRegion> nails;
  final Map<int, NailStyle> styles;
  final double gloss;
  final Map<int, double> coatAmounts;
  final double lightDirection;
  final bool original, outlines;
  final int? selectedId;
  @override
  void paint(Canvas canvas, Size size) => renderer.paint(
    canvas,
    size,
    nails,
    styles,
    gloss,
    coatAmounts: coatAmounts,
    lightDirection: lightDirection,
    original: original,
    selectedId: selectedId,
    outlines: outlines,
  );
  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => true;
}
