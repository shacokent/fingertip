import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/nail_models.dart';
import '../services/nail_renderer.dart';
import '../services/nail_surface.dart';

/// A neutral sample nail rendered by the exact shader used on the photograph.
class NailStyleSwatch extends StatefulWidget {
  const NailStyleSwatch({
    super.key,
    required this.style,
    this.width = 44,
    this.height = 58,
  });

  final NailStyle style;
  final double width;
  final double height;

  @override
  State<NailStyleSwatch> createState() => _NailStyleSwatchState();
}

class _NailStyleSwatchState extends State<NailStyleSwatch> {
  _SwatchResources? _resources;
  ui.FragmentShader? _shader;
  ui.Image? _design;
  int _designGeneration = 0;
  bool _designError = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadDesign();
  }

  @override
  void didUpdateWidget(covariant NailStyleSwatch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.style.texturePath != widget.style.texturePath) _loadDesign();
  }

  Future<void> _loadDesign() async {
    final generation = ++_designGeneration;
    _design?.dispose();
    _design = null;
    _designError = false;
    final path = widget.style.texturePath;
    if (path == null) return;
    try {
      final image = await loadNailStyleTexture(path, maxDimension: 384);
      if (!mounted || generation != _designGeneration) {
        image.dispose();
        return;
      }
      setState(() => _design = image);
    } catch (_) {
      if (mounted && generation == _designGeneration) {
        setState(() => _designError = true);
      }
    }
  }

  Future<void> _load() async {
    try {
      final resources = await _SwatchResources.acquire();
      if (!mounted) return;
      final shader = resources.program.fragmentShader();
      setState(() {
        _resources = resources;
        _shader = shader;
      });
    } catch (_) {
      // A static placeholder also works before shaders are available in tests.
      // No progress animation or repeated rebuild is needed for a small sample.
    }
  }

  @override
  void dispose() {
    _shader?.dispose();
    _designGeneration++;
    _design?.dispose();
    _SwatchResources.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: _designError
        ? const Icon(Icons.broken_image_outlined, size: 20)
        : _shader == null || _resources == null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.style.color,
                borderRadius: BorderRadius.circular(widget.width * .5),
              ),
            ),
          )
        : CustomPaint(
            painter: _SwatchPainter(
              resources: _resources!,
              shader: _shader!,
              style: widget.style,
              design: _design,
            ),
          ),
  );
}

class _SwatchResources {
  _SwatchResources(this.program, this.photo, this.mask);

  final ui.FragmentProgram program;
  final ui.Image photo;
  final ui.Image mask;
  static _SwatchResources? _ready;
  static Future<_SwatchResources>? _loading;
  static int _owners = 0;

  static Future<_SwatchResources> acquire() {
    _owners++;
    final ready = _ready;
    if (ready != null) return Future.value(ready);
    final pending = _loading;
    if (pending != null) return pending;
    late final Future<_SwatchResources> task;
    task = _create()
        .then((resources) {
          _ready = resources;
          if (_owners == 0) {
            // Let existing awaiters finish before releasing this completed
            // load. A newly mounted swatch can acquire it in the same turn.
            Future<void>.delayed(Duration.zero, () {
              if (_owners == 0 && identical(_ready, resources)) {
                _ready = null;
                resources._dispose();
              }
            });
          }
          return resources;
        })
        .whenComplete(() {
          if (identical(_loading, task)) _loading = null;
        });
    _loading = task;
    return task;
  }

  static void release() {
    assert(_owners > 0);
    _owners--;
    if (_owners != 0) return;
    final ready = _ready;
    _ready = null;
    ready?._dispose();
  }

  static Future<_SwatchResources> _create() async {
    final program = await ui.FragmentProgram.fromAsset('shaders/nail.frag');
    ui.Image? photo;
    try {
      final photoRecorder = ui.PictureRecorder();
      final canvas = Canvas(photoRecorder);
      const bounds = Rect.fromLTWH(0, 0, 96, 144);
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [Color(0xFFAD9B8D), Color(0xFFD1C2B4), Color(0xFFB5A090)],
            stops: [0, .4, 1],
          ).createShader(bounds),
      );
      final photoPicture = photoRecorder.endRecording();
      try {
        photo = await photoPicture.toImage(96, 144);
      } finally {
        photoPicture.dispose();
      }
      final maskRecorder = ui.PictureRecorder();
      Canvas(maskRecorder).drawPath(
        standardNailPath(const Size(96, 144)),
        Paint()..color = Colors.white,
      );
      final maskPicture = maskRecorder.endRecording();
      try {
        final mask = await maskPicture.toImage(96, 144);
        return _SwatchResources(program, photo, mask);
      } finally {
        maskPicture.dispose();
      }
    } catch (_) {
      photo?.dispose();
      rethrow;
    }
  }

  void _dispose() {
    photo.dispose();
    mask.dispose();
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter({
    required this.resources,
    required this.shader,
    required this.style,
    required this.design,
  });

  final _SwatchResources resources;
  final ui.FragmentShader shader;
  final NailStyle style;
  final ui.Image? design;

  @override
  void paint(Canvas canvas, Size size) {
    const natural = Size(96, 144);
    configureNailShader(
      shader,
      size: natural,
      center: const Offset(48, 72),
      angle: 0,
      photo: resources.photo,
      mask: resources.mask,
      style: style,
      gloss: .65,
      design: design,
    );
    canvas.save();
    canvas.scale(size.width / natural.width, size.height / natural.height);
    canvas.save();
    canvas.clipPath(standardNailPath(natural));
    canvas.drawImage(resources.photo, Offset.zero, Paint());
    canvas.restore();
    canvas.drawRect(Offset.zero & natural, Paint()..shader = shader);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SwatchPainter oldDelegate) =>
      style != oldDelegate.style ||
      design != oldDelegate.design ||
      shader != oldDelegate.shader ||
      resources != oldDelegate.resources;
}
