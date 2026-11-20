import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';

const _style = NailStyle(
  'direction-test',
  '灯光测试',
  '',
  Color(0xFF65253B),
  NailPattern.solid,
  coverage: 1,
);

void main() {
  testWidgets('opposite lamps move highlights on built-in and DIY polish', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('nail_lamp_');
      final renderer = await _renderer();
      final nail = _nail();
      final texture = await _photo(32, 48, const Color(0xFF65253B));
      final texturePath = '${folder.path}/design.png';
      try {
        await File(texturePath).writeAsBytes(
          (await texture.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
        texture.dispose();
        final custom = NailStyle(
          'custom-direction',
          '自建款式灯光测试',
          '',
          Colors.transparent,
          NailPattern.solid,
          coverage: 1,
          texturePath: texturePath,
        );
        for (final style in [_style, custom]) {
          final left = await _export(renderer, nail, style, 1, math.pi);
          final right = await _export(renderer, nail, style, 1, 0);
          var leftGain = 0, rightGain = 0;
          for (var y = 30; y < 130; y++) {
            for (var x = 42; x < 118; x++) {
              final index = (y * 160 + x) * 4;
              final delta =
                  _brightness(left, index) - _brightness(right, index);
              if (x < 72) leftGain += delta;
              if (x > 88) rightGain -= delta;
            }
          }
          expect(leftGain, greaterThan(2000), reason: style.id);
          expect(rightGain, greaterThan(2000), reason: style.id);
          for (final pixels in [left, right]) {
            expect(pixels.sublist(0, 4), [217, 179, 155, 255]);
            expect(
              pixels.sublist((80 * 160 + 20) * 4, (80 * 160 + 20) * 4 + 4),
              [217, 179, 155, 255],
            );
          }
          final matteLeft = await _export(renderer, nail, style, 0, math.pi);
          final matteRight = await _export(renderer, nail, style, 0, 0);
          expect(
            matteLeft,
            orderedEquals(matteRight),
            reason: 'Direction only modulates the selected gloss, ${style.id}',
          );
        }
      } finally {
        renderer.dispose();
        await folder.delete(recursive: true);
      }
    });
  });

  testWidgets('one photograph lamp stays on the same side of rotated nails', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final renderer = await _renderer();
      try {
        final centroids = <double>[];
        for (final angle in [0.0, math.pi]) {
          final nail = _nail().copyWith(angle: angle);
          final matte = await _export(renderer, nail, _style, 0, 0);
          final glossy = await _export(renderer, nail, _style, 1, 0);
          var total = 0.0, weightedX = 0.0;
          for (var y = 28; y < 132; y++) {
            for (var x = 44; x < 116; x++) {
              final index = (y * 160 + x) * 4;
              final gain = math.max(
                0,
                _brightness(glossy, index) - _brightness(matte, index),
              );
              total += gain;
              weightedX += (x + .5) * gain;
            }
          }
          expect(total, greaterThan(2000));
          centroids.add(weightedX / total);
        }
        expect(centroids[0], greaterThan(85));
        expect(centroids[1], greaterThan(85));
        expect(centroids[0], closeTo(centroids[1], 1));
      } finally {
        renderer.dispose();
      }
    });
  });

  testWidgets('export uses the same selected lamp as preview painting', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final renderer = await _renderer();
      final nail = _nail().copyWith(angle: .37);
      try {
        final exported = await _export(renderer, nail, _style, .86, 1.23);
        final recorder = ui.PictureRecorder();
        renderer.paint(
          Canvas(recorder),
          const Size(160, 160),
          [nail],
          {nail.id: _style},
          .86,
          lightDirection: 1.23,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(160, 160);
        picture.dispose();
        try {
          expect(await _pixels(image), orderedEquals(exported));
        } finally {
          image.dispose();
        }
        final defaultLamp = await _export(
          renderer,
          nail,
          _style,
          .86,
          defaultNailLightDirection,
        );
        expect(defaultLamp, isNot(orderedEquals(exported)));
      } finally {
        renderer.dispose();
      }
    });
  });
}

int _brightness(Uint8List pixels, int offset) =>
    pixels[offset] + pixels[offset + 1] + pixels[offset + 2];

NailRegion _nail() => NailRegion.manual(
  0,
  const Offset(80, 80),
  160,
).copyWith(width: 76, height: 112);

Future<NailRenderer> _renderer() async => NailRenderer(
  await _photo(160, 160, const Color(0xFFD9B39B)),
  await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
);

Future<ui.Image> _photo(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _export(
  NailRenderer renderer,
  NailRegion nail,
  NailStyle style,
  double gloss,
  double direction,
) async {
  final image = await renderer.export(
    [nail],
    {nail.id: style},
    gloss,
    lightDirection: direction,
  );
  try {
    return await _pixels(image);
  } finally {
    image.dispose();
  }
}

Future<Uint8List> _pixels(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.rawRgba,
))!.buffer.asUint8List();
