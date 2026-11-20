import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/diy_models.dart';
import '../services/diy_renderer.dart';

class DiyCanvas extends StatefulWidget {
  const DiyCanvas({
    super.key,
    required this.design,
    this.selectedLayerId,
    required this.onSelect,
    required this.onLayerChanged,
    required this.onGestureStart,
    required this.onStroke,
    this.drawing = false,
    this.eraser = false,
    this.brushColor = const Color(0xFF7A3F4E),
    this.brushWidth = .012,
  });
  final DiyNailDesign design;
  final String? selectedLayerId;
  final ValueChanged<String?> onSelect;
  final ValueChanged<DiyLayer> onLayerChanged;
  final VoidCallback onGestureStart;
  final ValueChanged<DiyLayer> onStroke;
  final bool drawing, eraser;
  final Color brushColor;
  final double brushWidth;

  @override
  State<DiyCanvas> createState() => _DiyCanvasState();
}

class _DiyCanvasState extends State<DiyCanvas> {
  final _images = <String, ui.Image>{};
  final _loading = <String>{};
  DiyLayer? _gestureLayer;
  Offset? _gesturePoint;
  final _stroke = <Offset>[];
  Size _size = Size.zero;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  @override
  void didUpdateWidget(covariant DiyCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    _loadImages();
  }

  void _loadImages() {
    final paths = widget.design.layers
        .map((layer) => layer.imagePath)
        .whereType<String>()
        .toSet();
    for (final obsolete
        in _images.keys.where((path) => !paths.contains(path)).toList()) {
      _images.remove(obsolete)?.dispose();
    }
    for (final path in paths) {
      if (_images.containsKey(path) || !_loading.add(path)) continue;
      decodeDiyImage(path)
          .then((image) {
            if (!mounted ||
                !widget.design.layers.any((layer) => layer.imagePath == path)) {
              image.dispose();
              return;
            }
            setState(() => _images[path] = image);
          })
          .catchError((Object _) {
            /* The studio reports failed image imports. */
          })
          .whenComplete(() => _loading.remove(path));
    }
  }

  Offset _normal(Offset point) => Offset(
    (point.dx / _size.width).clamp(0, 1),
    (point.dy / _size.height).clamp(0, 1),
  );
  DiyLayer? _hit(Offset point) {
    for (final layer in widget.design.layers.reversed) {
      if (layer.erase) continue;
      final delta =
          point - Offset(layer.x * _size.width, layer.y * _size.height);
      final c = math.cos(layer.rotation), s = math.sin(layer.rotation);
      final local =
          Offset(c * delta.dx + s * delta.dy, -s * delta.dx + c * delta.dy) /
          layer.scale;
      if (local.dx.abs() < layer.width * _size.width / 2 + 5 &&
          local.dy.abs() < layer.height * _size.height / 2 + 5) {
        return layer;
      }
    }
    return null;
  }

  void _start(ScaleStartDetails details) {
    if (widget.drawing) {
      setState(() {
        _stroke.clear();
        _stroke.add(_normal(details.localFocalPoint));
      });
      return;
    }
    final hit = _hit(details.localFocalPoint);
    final selected = widget.design.layers
        .where((l) => l.id == widget.selectedLayerId)
        .firstOrNull;
    _gestureLayer = hit ?? selected;
    widget.onSelect(_gestureLayer?.id);
    if (_gestureLayer == null) return;
    _gesturePoint = details.localFocalPoint;
    widget.onGestureStart();
  }

  void _update(ScaleUpdateDetails details) {
    if (widget.drawing) {
      setState(() => _stroke.add(_normal(details.localFocalPoint)));
      return;
    }
    final layer = _gestureLayer, origin = _gesturePoint;
    if (layer == null || origin == null) return;
    final delta = details.localFocalPoint - origin;
    widget.onLayerChanged(
      layer.copyWith(
        x: layer.locked
            ? layer.x
            : (layer.x + delta.dx / _size.width).clamp(-1, 2),
        y: layer.locked
            ? layer.y
            : (layer.y + delta.dy / _size.height).clamp(-1, 2),
        scale: (layer.scale * details.scale).clamp(.1, 5),
        rotation: layer.rotation + details.rotation,
      ),
    );
  }

  void _end(ScaleEndDetails details) {
    if (widget.drawing && _stroke.isNotEmpty) {
      final points = List<Offset>.of(_stroke);
      final xs = points.map((p) => p.dx), ys = points.map((p) => p.dy);
      final left = xs.reduce(math.min), top = ys.reduce(math.min);
      final width = math.max(.004, xs.reduce(math.max) - left),
          height = math.max(.004, ys.reduce(math.max) - top);
      widget.onStroke(
        DiyLayer(
          id: 'stroke_${DateTime.now().microsecondsSinceEpoch}',
          kind: DiyLayerKind.stroke,
          name: widget.eraser ? '橡皮擦' : '手绘笔迹',
          x: left + width / 2,
          y: top + height / 2,
          width: width,
          height: height,
          color: widget.brushColor,
          strokeWidth: widget.brushWidth,
          erase: widget.eraser,
          points: List.unmodifiable(
            points.map(
              (p) => Offset((p.dx - left) / width, (p.dy - top) / height),
            ),
          ),
        ),
      );
      setState(_stroke.clear);
    }
    _gestureLayer = null;
    _gesturePoint = null;
  }

  @override
  void dispose() {
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _size = box.biggest;
      return GestureDetector(
        key: const ValueKey('diy-design-canvas'),
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          if (!widget.drawing) {
            widget.onSelect(_hit(d.localPosition)?.id);
          } else {
            final point = _normal(d.localPosition);
            widget.onStroke(
              DiyLayer(
                id: 'stroke_${DateTime.now().microsecondsSinceEpoch}',
                kind: DiyLayerKind.stroke,
                name: widget.eraser ? '橡皮擦' : '手绘笔迹',
                x: point.dx,
                y: point.dy,
                width: .004,
                height: .004,
                color: widget.brushColor,
                strokeWidth: widget.brushWidth,
                erase: widget.eraser,
                points: const [Offset(.5, .5)],
              ),
            );
          }
        },
        onScaleStart: _start,
        onScaleUpdate: _update,
        onScaleEnd: _end,
        child: CustomPaint(
          painter: _DiyPainter(
            widget.design,
            Map.of(_images),
            widget.selectedLayerId,
            List.of(_stroke),
            widget.brushColor,
            widget.brushWidth,
            widget.eraser,
          ),
        ),
      );
    },
  );
}

class _DiyPainter extends CustomPainter {
  _DiyPainter(
    this.design,
    this.images,
    this.selected,
    this.stroke,
    this.brush,
    this.width,
    this.eraser,
  );
  final DiyNailDesign design;
  final Map<String, ui.Image> images;
  final String? selected;
  final List<Offset> stroke;
  final Color brush;
  final double width;
  final bool eraser;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.save();
    canvas.clipPath(diyNailPath(size));
    const tile = 12.0;
    for (var y = 0.0; y < size.height; y += tile) {
      for (var x = 0.0; x < size.width; x += tile) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, tile, tile),
          Paint()
            ..color = ((x / tile).floor() + (y / tile).floor()).isEven
                ? const Color(0xFFFFFFFF)
                : const Color(0xFFE6E1DF),
        );
      }
    }
    canvas.restore();
    var visible = design;
    if (stroke.isNotEmpty) {
      visible = design.copyWith(
        layers: [
          ...design.layers,
          DiyLayer(
            id: 'live',
            kind: DiyLayerKind.stroke,
            x: .5,
            y: .5,
            width: 1,
            height: 1,
            points: stroke,
            color: brush,
            strokeWidth: width,
            erase: eraser,
          ),
        ],
      );
    }
    paintDiyDesign(canvas, size, visible, images);
    canvas.drawPath(
      diyNailPath(size),
      Paint()
        ..color = const Color(0xFFAA8290)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final layer = design.layers.where((l) => l.id == selected).firstOrNull;
    if (layer != null && !layer.erase) {
      canvas.save();
      canvas.translate(layer.x * size.width, layer.y * size.height);
      canvas.rotate(layer.rotation);
      canvas.scale(layer.scale);
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset.zero,
          width: layer.width * size.width,
          height: layer.height * size.height,
        ),
        Paint()
          ..color = const Color(0xFF7A3F4E)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1 / layer.scale,
      );
      canvas.restore();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DiyPainter oldDelegate) =>
      design != oldDelegate.design ||
      selected != oldDelegate.selected ||
      !listEquals(stroke, oldDelegate.stroke) ||
      images != oldDelegate.images ||
      images.length != oldDelegate.images.length;
}
