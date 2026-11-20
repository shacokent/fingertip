import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline_nail_demo/main.dart' as app;
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/screens/editor_page.dart';
import 'package:offline_nail_demo/screens/home_page.dart';
import 'package:offline_nail_demo/services/nail_analysis.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';
import 'package:offline_nail_demo/services/nail_surface.dart';

const _glitterIds = [
  'lilac',
  'sparkle_champagne',
  'sparkle_silver',
  'sparkle_galaxy',
];
const _catEyeIds = [
  'magnetic_silverriver',
  'magnetic_rosetrail',
  'magnetic_sapphire',
  'magnetic_deepsea',
];
const _cases = [
  _LightCase('Left / gloss 1', -math.pi, 1),
  _LightCase('Top / gloss 1', -math.pi / 2, 1),
  _LightCase('Right / gloss 1', 0, 1),
  _LightCase('Top / gloss .15', -math.pi / 2, .15),
  _LightCase('Right / nail 180', 0, 1, angle: math.pi),
  _LightCase('NW / gloss .65', -3 * math.pi / 4, .65),
];

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native glitter and cat-eye directional material review', (
    tester,
  ) async {
    final program = await ui.FragmentProgram.fromAsset('shaders/nail.frag');
    final standardRenderer = NailRenderer(await _neutralPhoto(), program);
    final standardNail = _standardNail();
    final metrics = <Map<String, Object>>[];
    final exports = <String, String>{};
    final standardImages = <String, List<_Rendered>>{};
    try {
      for (final id in [..._glitterIds, ..._catEyeIds]) {
        final style = NailStyle.byId(id)!;
        expect(style.pattern, isIn([NailPattern.shimmer, NailPattern.catEye]));
        final rendered = <_Rendered>[];
        for (final lighting in _cases) {
          final nail = standardNail.copyWith(angle: lighting.angle);
          final picture = await _render(
            standardRenderer,
            [nail],
            style,
            lighting,
          );
          final outside = _assertOutsideMask(
            picture.pixels,
            await _pixels(standardRenderer.photo),
            160,
            220,
            [nail],
          );
          metrics.add({
            'style': id,
            'pattern': style.pattern.name,
            'light': lighting.label,
            'lampRadians': lighting.direction,
            'gloss': lighting.gloss,
            'nailAngleRadians': lighting.angle,
            'pixelHash': _hash(picture.pixels),
            'outsideMaskPixelsProtected': outside,
            ..._appearance(picture.pixels, 160, 220, nail),
          });
          rendered.add(picture);
        }
        final repeat = await _render(
          standardRenderer,
          [standardNail],
          style,
          _cases.first,
        );
        expect(
          listEquals(repeat.pixels, rendered.first.pixels),
          isTrue,
          reason: 'Material samples must not flicker or change seed, $id',
        );
        repeat.image.dispose();
        expect(
          listEquals(rendered[0].pixels, rendered[2].pixels),
          isFalse,
          reason: 'Opposite lamps must affect this material, $id',
        );
        metrics.add({
          'style': id,
          'leftRightMeanAbsoluteRgbDifference': _difference(
            rendered[0].pixels,
            rendered[2].pixels,
          ),
          'repeatIsPixelIdentical': true,
        });
        standardImages[id] = rendered;
      }
      exports['material_glitter_sheet'] = base64Encode(
        await _sheet(_glitterIds, standardImages, 'Glitter / fixed flakes'),
      );
      exports['material_cat_eye_sheet'] = base64Encode(
        await _sheet(
          _catEyeIds,
          standardImages,
          'Cat-eye / fixed magnetic design',
        ),
      );
      final previewNail = standardNail.copyWith(angle: math.pi);
      final previewStyle = NailStyle.byId('magnetic_sapphire')!;
      final preview = await _paint(
        standardRenderer,
        [previewNail],
        previewStyle,
        _cases[4],
      );
      expect(
        listEquals(preview.pixels, standardImages[previewStyle.id]![4].pixels),
        isTrue,
        reason: 'Preview paint and export share directional material settings',
      );
      preview.image.dispose();
    } finally {
      for (final row in standardImages.values) {
        for (final result in row) {
          result.image.dispose();
        }
      }
      standardRenderer.dispose();
    }

    final sample = await rootBundle.load('assets/samples/hand.jpg');
    final engine = NailAnalysisEngine();
    final AnalysisResult analysis;
    try {
      analysis = await engine.analyze(sample.buffer.asUint8List());
    } finally {
      await engine.close();
    }
    expect(analysis.nails, isNotEmpty);
    final codec = await ui.instantiateImageCodec(analysis.pngBytes);
    final photo = (await codec.getNextFrame()).image;
    codec.dispose();
    final photoRenderer = NailRenderer(photo, program);
    final photoOriginal = await _pixels(photo);
    final photoImages = <_Rendered>[];
    try {
      for (final id in ['sparkle_champagne', 'magnetic_sapphire']) {
        for (final lighting in [_cases[0], _cases[2]]) {
          final result = await _render(
            photoRenderer,
            analysis.nails,
            NailStyle.byId(id)!,
            lighting,
          );
          _assertOutsideMask(
            result.pixels,
            photoOriginal,
            analysis.width,
            analysis.height,
            analysis.nails,
          );
          photoImages.add(result);
        }
      }
      expect(listEquals(photoImages[0].pixels, photoImages[1].pixels), isFalse);
      expect(listEquals(photoImages[2].pixels, photoImages[3].pixels), isFalse);
      exports['material_photo_comparison'] = base64Encode(
        await _photoSheet(photoImages),
      );
      exports['material_photo_glitter_left'] = base64Encode(
        await _png(photoImages[0].image),
      );
      exports['material_photo_glitter_right'] = base64Encode(
        await _png(photoImages[1].image),
      );
      exports['material_photo_cat_eye_left'] = base64Encode(
        await _png(photoImages[2].image),
      );
      exports['material_photo_cat_eye_right'] = base64Encode(
        await _png(photoImages[3].image),
      );
    } finally {
      for (final result in photoImages) {
        result.image.dispose();
      }
      photoRenderer.dispose();
    }

    binding.reportData = {
      ...?binding.reportData,
      'materialMetrics': {
        'styles': [..._glitterIds, ..._catEyeIds],
        'standardCasesPerStyle': _cases.length,
        'standardRenderCount':
            (_glitterIds.length + _catEyeIds.length) * _cases.length,
        'neutralFixture': 'Owned 160x220 neutral photo and canonical nail',
        'photoFixture': 'assets/samples/hand.jpg',
        'recognizedPhotoNails': analysis.nails.length,
        'materialRepeatDeterministic': true,
        'previewExportPixelIdentical': true,
        'outsideMaskPixelsProtected': true,
        'appearanceMeasurements': metrics,
        'scope':
            'Native simulator, owned/bundled fixtures; no real camera or private photos',
        'platform': Platform.operatingSystem,
      },
      'exports': exports,
    };

    await tester.pumpWidget(const app.NailStudioApp());
    await tester.pumpAndSettle();
    unawaited(
      Navigator.of(tester.element(find.byType(HomePage))).push<void>(
        MaterialPageRoute(builder: (_) => EditorPage(analysis: analysis)),
      ),
    );
    await _until(tester, () => find.byType(NailScene).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    if (Platform.isAndroid) {
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
    }
    for (final entry in [
      ('sparkle', 'sparkle_champagne', 'material_editor_glitter'),
      ('magnetic', 'magnetic_sapphire', 'material_editor_cat_eye'),
    ]) {
      final category = find.byKey(ValueKey('inline-category-${entry.$1}'));
      await _revealHorizontal(tester, category, 'inline-style-categories');
      await tester.tap(category);
      await tester.pumpAndSettle();
      final swatch = find.byKey(ValueKey('inline-style-${entry.$2}'));
      await _revealHorizontal(tester, swatch, 'inline-style-list');
      await tester.tap(swatch);
      await _until(
        tester,
        () => tester
            .widget<NailScene>(find.byType(NailScene))
            .styles
            .values
            .every((style) => style.id == entry.$2),
      );
      await tester.pumpAndSettle();
      await binding.takeScreenshot(entry.$3);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}

class _LightCase {
  const _LightCase(this.label, this.direction, this.gloss, {this.angle = 0});
  final String label;
  final double direction, gloss, angle;
}

class _Rendered {
  const _Rendered(this.image, this.pixels);
  final ui.Image image;
  final Uint8List pixels;
}

NailRegion _standardNail() {
  const width = 128, height = 192;
  final path = standardNailPath(const Size(128, 192));
  final mask = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (!path.contains(Offset(x + .5, y + .5))) continue;
      final index = (y * width + x) * 4;
      mask[index] = mask[index + 1] = mask[index + 2] = mask[index + 3] = 255;
    }
  }
  return NailRegion(
    id: 1,
    label: 'owned material fixture',
    center: const Offset(80, 110),
    width: 90,
    height: 160,
    angle: 0,
    maskRgba: mask,
    maskWidth: width,
    maskHeight: height,
  );
}

Future<ui.Image> _neutralPhoto() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFC8B8AE), BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(160, 220);
  } finally {
    picture.dispose();
  }
}

Future<_Rendered> _render(
  NailRenderer renderer,
  List<NailRegion> nails,
  NailStyle style,
  _LightCase lighting,
) async {
  final image = await renderer.export(
    nails,
    {for (final nail in nails) nail.id: style},
    lighting.gloss,
    lightDirection: lighting.direction,
  );
  return _Rendered(image, await _pixels(image));
}

Future<_Rendered> _paint(
  NailRenderer renderer,
  List<NailRegion> nails,
  NailStyle style,
  _LightCase lighting,
) async {
  final recorder = ui.PictureRecorder();
  renderer.paint(
    Canvas(recorder),
    Size(renderer.photo.width.toDouble(), renderer.photo.height.toDouble()),
    nails,
    {for (final nail in nails) nail.id: style},
    lighting.gloss,
    lightDirection: lighting.direction,
  );
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(
      renderer.photo.width,
      renderer.photo.height,
    );
    return _Rendered(image, await _pixels(image));
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _pixels(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.rawRgba,
))!.buffer.asUint8List();

Future<Uint8List> _png(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.png,
))!.buffer.asUint8List();

int _assertOutsideMask(
  Uint8List rendered,
  Uint8List original,
  int width,
  int height,
  List<NailRegion> nails,
) {
  var protected = 0, changed = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final point = Offset(x + .5, y + .5);
      if (nails.any((nail) => _maskAt(nail, point) > 0)) continue;
      protected++;
      final index = (y * width + x) * 4;
      if (rendered[index] != original[index] ||
          rendered[index + 1] != original[index + 1] ||
          rendered[index + 2] != original[index + 2] ||
          rendered[index + 3] != original[index + 3]) {
        changed++;
      }
    }
  }
  expect(
    changed,
    0,
    reason: 'Material shading must not touch pixels outside its mask',
  );
  return protected;
}

double _maskAt(NailRegion nail, Offset photoPoint) {
  final local = nail.toLocal(photoPoint);
  final u = local.dx / nail.width + .5, v = local.dy / nail.height + .5;
  if (u < 0 || v < 0 || u >= 1 || v >= 1) return 0;
  final sx = u * nail.maskWidth - .5, sy = v * nail.maskHeight - .5;
  final ix = sx.floor(), iy = sy.floor(), fx = sx - ix, fy = sy - iy;
  var alpha = 0.0;
  for (var dy = 0; dy < 2; dy++) {
    for (var dx = 0; dx < 2; dx++) {
      final x = (ix + dx).clamp(0, nail.maskWidth - 1);
      final y = (iy + dy).clamp(0, nail.maskHeight - 1);
      alpha +=
          nail.maskRgba[(y * nail.maskWidth + x) * 4 + 3] *
          (dx == 0 ? 1 - fx : fx) *
          (dy == 0 ? 1 - fy : fy);
    }
  }
  return alpha;
}

Map<String, Object> _appearance(
  Uint8List pixels,
  int width,
  int height,
  NailRegion nail,
) {
  var count = 0, white = 0, sum = 0.0, peak = 0.0;
  final values = <double>[];
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (_maskAt(nail, Offset(x + .5, y + .5)) < 247) continue;
      final i = (y * width + x) * 4;
      final luma =
          .2126 * pixels[i] + .7152 * pixels[i + 1] + .0722 * pixels[i + 2];
      count++;
      sum += luma;
      peak = math.max(peak, luma);
      values.add(luma);
      if (pixels[i] >= 245 && pixels[i + 1] >= 245 && pixels[i + 2] >= 245) {
        white++;
      }
    }
  }
  values.sort();
  return {
    'interiorPixels': count,
    'meanLuminance': sum / count,
    'peakLuminance': peak,
    'p95Luminance': values[(values.length * .95).floor()],
    'nearWhiteInteriorFraction': white / count,
  };
}

double _difference(Uint8List first, Uint8List second) {
  var sum = 0;
  for (var i = 0; i < first.length; i += 4) {
    sum +=
        (first[i] - second[i]).abs() +
        (first[i + 1] - second[i + 1]).abs() +
        (first[i + 2] - second[i + 2]).abs();
  }
  return sum / (first.length / 4 * 3);
}

String _hash(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Future<Uint8List> _sheet(
  List<String> ids,
  Map<String, List<_Rendered>> images,
  String title,
) async {
  const cellWidth = 180.0, rowHeight = 252.0, header = 66.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFF8F5F3), BlendMode.src);
  _label(canvas, title, const Offset(12, 8), 18);
  for (var c = 0; c < _cases.length; c++) {
    _label(canvas, _cases[c].label, Offset(c * cellWidth + 10, 38), 12);
  }
  for (var row = 0; row < ids.length; row++) {
    final y = header + row * rowHeight;
    _label(canvas, NailStyle.byId(ids[row])!.name, Offset(10, y), 14);
    for (var col = 0; col < _cases.length; col++) {
      canvas.drawImage(
        images[ids[row]]![col].image,
        Offset(col * cellWidth + 10, y + 22),
        Paint(),
      );
    }
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(
    (_cases.length * cellWidth).round(),
    (header + ids.length * rowHeight).round(),
  );
  picture.dispose();
  try {
    return await _png(image);
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _photoSheet(List<_Rendered> images) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(const Color(0xFFF8F5F3), BlendMode.src);
  const labels = [
    'Glitter / lamp left',
    'Glitter / lamp right',
    'Cat-eye / lamp left',
    'Cat-eye / lamp right',
  ];
  for (var i = 0; i < images.length; i++) {
    final origin = Offset((i % 2) * 420.0, (i ~/ 2) * 448.0);
    _label(canvas, labels[i], origin + const Offset(10, 8), 15);
    canvas.drawImageRect(
      images[i].image,
      const Rect.fromLTWH(0, 0, 640, 640),
      (origin + const Offset(10, 34)) & const Size(400, 400),
      Paint()..filterQuality = FilterQuality.high,
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(840, 896);
  picture.dispose();
  try {
    return await _png(image);
  } finally {
    image.dispose();
  }
}

void _label(Canvas canvas, String value, Offset offset, double size) {
  final painter = TextPainter(
    text: TextSpan(
      text: value,
      style: TextStyle(fontSize: size, color: const Color(0xFF493E42)),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  painter.paint(canvas, offset);
  painter.dispose();
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  expect(condition(), isTrue, reason: 'Material UI action did not complete');
}

Future<void> _revealHorizontal(
  WidgetTester tester,
  Finder target,
  String listKey,
) async {
  await tester.scrollUntilVisible(
    target,
    160,
    scrollable: find.descendant(
      of: find.byKey(ValueKey(listKey)),
      matching: find.byType(Scrollable),
    ),
    maxScrolls: 20,
  );
  await tester.pumpAndSettle();
}
