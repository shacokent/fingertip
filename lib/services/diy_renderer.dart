import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

import '../models/diy_models.dart';
import '../models/diy_stickers.dart';
import 'nail_surface.dart';

Path diyNailPath(Size size) => standardNailPath(size);

Future<ui.Image> decodeDiyImage(String path) async {
  final data = await File(path).readAsBytes();
  final buffer = await ui.ImmutableBuffer.fromUint8List(data);
  ui.ImageDescriptor? descriptor;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final ratio =
        (1536 /
                (descriptor.width > descriptor.height
                    ? descriptor.width
                    : descriptor.height))
            .clamp(0.0, 1.0);
    final codec = await descriptor.instantiateCodec(
      targetWidth: (descriptor.width * ratio).round().clamp(1, 1536),
      targetHeight: (descriptor.height * ratio).round().clamp(1, 1536),
    );
    try {
      return (await codec.getNextFrame()).image;
    } finally {
      codec.dispose();
    }
  } finally {
    descriptor?.dispose();
    buffer.dispose();
  }
}

void paintDiyDesign(
  Canvas canvas,
  Size size,
  DiyNailDesign design,
  Map<String, ui.Image> images, {
  bool clipToNail = true,
}) {
  canvas.save();
  if (clipToNail) canvas.clipPath(diyNailPath(size));
  canvas.drawRect(Offset.zero & size, Paint()..color = design.baseColor);
  void paintLayer(DiyLayer layer) {
    canvas.save();
    canvas.translate(layer.x * size.width, layer.y * size.height);
    canvas.rotate(layer.rotation);
    canvas.scale(layer.scale);
    final bounds = Rect.fromCenter(
      center: Offset.zero,
      width: layer.width * size.width,
      height: layer.height * size.height,
    );
    switch (layer.kind) {
      case DiyLayerKind.image:
        final image = images[layer.imagePath];
        if (image != null) {
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(
              0,
              0,
              image.width.toDouble(),
              image.height.toDouble(),
            ),
            bounds,
            Paint()
              ..filterQuality = FilterQuality.high
              ..color = Colors.white.withValues(alpha: layer.opacity),
          );
        }
      case DiyLayerKind.sticker:
        final sticker = DiySticker.byId(layer.stickerId ?? '');
        if (sticker != null) {
          canvas.saveLayer(
            bounds,
            Paint()..color = Colors.white.withValues(alpha: layer.opacity),
          );
          canvas.translate(bounds.left, bounds.top);
          canvas.scale(bounds.width / 100, bounds.height / 100);
          paintDiySticker(canvas, sticker);
          canvas.restore();
        }
      case DiyLayerKind.stroke:
        if (layer.points.isNotEmpty) {
          final paint = Paint()
            ..color = layer.color.withValues(
              alpha: layer.color.a * layer.opacity,
            )
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = layer.strokeWidth * size.width
            ..blendMode = layer.erase ? BlendMode.clear : BlendMode.srcOver;
          final path = Path();
          final points = layer.points
              .map(
                (p) => Offset(
                  bounds.left + p.dx * bounds.width,
                  bounds.top + p.dy * bounds.height,
                ),
              )
              .toList();
          path.moveTo(points.first.dx, points.first.dy);
          for (var i = 1; i < points.length; i++) {
            path.lineTo(points[i].dx, points[i].dy);
          }
          if (points.length == 1) {
            canvas.drawCircle(
              points.single,
              paint.strokeWidth / 2,
              Paint()
                ..color = paint.color
                ..blendMode = paint.blendMode,
            );
          } else {
            canvas.drawPath(path, paint);
          }
        }
    }
    canvas.restore();
  }

  final layers = design.layers;
  final erasers = <int>[
    for (var i = 0; i < layers.length; i++)
      if (layers[i].kind == DiyLayerKind.stroke && layers[i].erase) i,
  ];
  var index = 0;
  while (index < layers.length) {
    if (layers[index].kind != DiyLayerKind.stroke) {
      paintLayer(layers[index++]);
      continue;
    }
    // Consecutive ink operations can share one isolated surface. Composite
    // each run at its actual place in the stack, instead of lifting all ink
    // above images/stickers. Higher erasers mask earlier ink even when an
    // image separates them, but never clear the image or the base itself.
    var end = index;
    var hasInk = false;
    while (end < layers.length && layers[end].kind == DiyLayerKind.stroke) {
      hasInk |= !layers[end].erase;
      end++;
    }
    if (hasInk) {
      canvas.saveLayer(Offset.zero & size, Paint());
      for (var i = index; i < end; i++) {
        paintLayer(layers[i]);
      }
      for (final eraser in erasers) {
        if (eraser >= end) paintLayer(layers[eraser]);
      }
      canvas.restore();
    }
    index = end;
  }
  canvas.restore();
}

Future<Uint8List> rasterizeDiyDesign(DiyNailDesign design) async {
  final images = <String, ui.Image>{};
  try {
    for (final path
        in design.layers.map((l) => l.imagePath).whereType<String>().toSet()) {
      images[path] = await decodeDiyImage(path);
    }
    final recorder = ui.PictureRecorder();
    // A rectangular texture is intentional. The photograph's real nail mask
    // clips it later; baking the sample nail shape here would clip it twice.
    paintDiyDesign(
      Canvas(recorder),
      const Size(512, 768),
      design,
      images,
      clipToNail: false,
    );
    final picture = recorder.endRecording();
    final result = await picture.toImage(512, 768);
    picture.dispose();
    try {
      return (await result.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
    } finally {
      result.dispose();
    }
  } finally {
    for (final image in images.values) {
      image.dispose();
    }
  }
}
