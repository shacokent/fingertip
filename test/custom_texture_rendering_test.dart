import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';
import 'package:offline_nail_demo/services/nail_surface.dart';

Future<ui.Image> _photo(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(const Color(0xFFD9B39B), BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Future<String> _design(
  Directory directory, {
  bool transparent = false,
  Color color = const Color(0xFF3366CC),
  String? name,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (transparent) {
    canvas.drawCircle(
      const Offset(32, 28.8),
      10,
      Paint()..color = const Color(0xFFEA2233),
    );
  } else {
    canvas.drawColor(color, BlendMode.src);
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 96);
  picture.dispose();
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final path =
        '${directory.path}/${name ?? (transparent ? 'clear' : 'blue')}.png';
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    return path;
  } finally {
    image.dispose();
  }
}

void main() {
  testWidgets('art hidden outside the canonical nail stays hidden in try-on', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('nail_corners_');
      final renderer = NailRenderer(
        await _photo(64, 96),
        await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
      );
      try {
        final canonical = standardNailPath(const Size(64, 96));
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(const Color(0xFF2255DD), BlendMode.src);
        for (var y = 0; y < 96; y++) {
          for (var x = 0; x < 64; x++) {
            final point = Offset(x + .5, y + .5);
            final outside = [
              point,
              point + const Offset(2, 0),
              point + const Offset(-2, 0),
              point + const Offset(0, 2),
              point + const Offset(0, -2),
            ].every((p) => !canonical.contains(p));
            if (outside) {
              canvas.drawRect(
                Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1),
                Paint()..color = const Color(0xFFEE1133),
              );
            }
          }
        }
        final picture = recorder.endRecording();
        final texture = await picture.toImage(64, 96);
        picture.dispose();
        final path = '${directory.path}/outside-corners.png';
        try {
          await File(path).writeAsBytes(
            (await texture.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List(),
          );
        } finally {
          texture.dispose();
        }
        final mask = Uint8List(64 * 96 * 4);
        for (var y = 0; y < 96; y++) {
          final left = 22 - (14 * y / 95).round();
          for (var x = left; x < 64 - left; x++) {
            final index = (y * 64 + x) * 4;
            mask[index] = mask[index + 1] = mask[index + 2] = mask[index + 3] =
                255;
          }
        }
        final nail = NailRegion(
          id: 9,
          label: '自定义甲面',
          center: const Offset(32, 48),
          width: 64,
          height: 96,
          angle: 0,
          maskRgba: mask,
        );
        final style = NailStyle(
          'custom_corners',
          '蓝甲片外红角',
          '',
          Colors.transparent,
          NailPattern.solid,
          coverage: 1,
          texturePath: path,
        );
        final output = await renderer.export([nail], {9: style}, 0);
        try {
          final pixels = (await output.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          for (final y in [4, 20, 75, 90]) {
            final left = 22 - (14 * y / 95).round();
            for (final x in [left + 2, 32, 61 - left]) {
              final index = (y * 64 + x) * 4;
              expect(pixels[index + 2], greaterThan(pixels[index] + 60));
            }
          }
          expect(pixels.sublist(0, 4), [217, 179, 155, 255]);
        } finally {
          output.dispose();
        }
      } finally {
        renderer.dispose();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('custom color stripes follow the row width of a tapered nail', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('nail_warp_');
      final renderer = NailRenderer(
        await _photo(64, 96),
        await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
      );
      try {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          const Rect.fromLTWH(0, 0, 64 / 3, 96),
          Paint()..color = const Color(0xFFDD2244),
        );
        canvas.drawRect(
          const Rect.fromLTWH(64 / 3, 0, 64 / 3, 96),
          Paint()..color = const Color(0xFF229944),
        );
        canvas.drawRect(
          const Rect.fromLTWH(128 / 3, 0, 64 / 3 + 1, 96),
          Paint()..color = const Color(0xFF2255DD),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(64, 96);
        picture.dispose();
        final path = '${directory.path}/stripes.png';
        try {
          await File(path).writeAsBytes(
            (await image.toByteData(
              format: ui.ImageByteFormat.png,
            ))!.buffer.asUint8List(),
          );
        } finally {
          image.dispose();
        }
        final mask = Uint8List(64 * 96 * 4);
        for (var y = 0; y < 96; y++) {
          final left = 22 - (14 * y / 95).round();
          for (var x = left; x < 64 - left; x++) {
            final index = (y * 64 + x) * 4;
            mask[index] = mask[index + 1] = mask[index + 2] = mask[index + 3] =
                255;
          }
        }
        final nail = NailRegion(
          id: 8,
          label: '梯形甲面',
          center: const Offset(32, 48),
          width: 64,
          height: 96,
          angle: 0,
          maskRgba: mask,
        );
        final style = NailStyle(
          'custom_tapered',
          '三色条纹',
          '',
          Colors.transparent,
          NailPattern.solid,
          texturePath: path,
          coverage: 1,
        );
        final result = await renderer.export([nail], {8: style}, 0);
        try {
          final pixels = (await result.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          for (final y in [20, 75]) {
            final left = 22 - (14 * y / 95).round();
            final right = 63 - left;
            final redX = left + ((right - left) * .2).round();
            final blueX = right - ((right - left) * .2).round();
            final red = (y * 64 + redX) * 4;
            final green = (y * 64 + 32) * 4;
            final blue = (y * 64 + blueX) * 4;
            expect(pixels[red], greaterThan(pixels[red + 1] + 60));
            expect(pixels[green + 1], greaterThan(pixels[green] + 40));
            expect(pixels[blue + 2], greaterThan(pixels[blue] + 60));
            final skin = y * 64 * 4;
            expect(pixels.sublist(skin, skin + 4), [217, 179, 155, 255]);
          }
        } finally {
          result.dispose();
        }
      } finally {
        renderer.dispose();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('a flattened translucent base coat keeps its single alpha', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('nail_half_');
      final program = await ui.FragmentProgram.fromAsset('shaders/nail.frag');
      final renderer = NailRenderer(await _photo(64, 96), program);
      ui.Image? design;
      ui.FragmentShader? shader;
      try {
        final nail = NailRegion.manual(
          1,
          const Offset(32, 48),
          64,
        ).copyWith(width: 64, height: 96);
        await renderer.addMask(nail);
        final style = NailStyle(
          'custom_translucent',
          '半透明底色',
          '',
          const Color(0x803366CC),
          NailPattern.solid,
          coverage: 1,
          texturePath: await _design(
            directory,
            color: const Color(0x803366CC),
            name: 'half-alpha',
          ),
        );
        design = await loadNailStyleTexture(style.texturePath!);
        shader = program.fragmentShader();
        configureNailShader(
          shader,
          size: const Size(64, 96),
          center: const Offset(32, 48),
          angle: 0,
          photo: renderer.photo,
          mask: renderer.masks[1]!,
          style: style,
          gloss: 0,
          design: design,
        );
        final recorder = ui.PictureRecorder();
        Canvas(
          recorder,
        ).drawRect(const Rect.fromLTWH(0, 0, 64, 96), Paint()..shader = shader);
        final picture = recorder.endRecording();
        final layer = await picture.toImage(64, 96);
        picture.dispose();
        try {
          final foreground = (await layer.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final center = (48 * 64 + 32) * 4;
          final alpha = foreground[center + 3];
          expect(alpha, inInclusiveRange(127, 129));
          final exported = await renderer.export([nail], {1: style}, 0);
          try {
            final result = (await exported.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            const background = [217, 179, 155];
            for (var channel = 0; channel < 3; channel++) {
              final expected =
                  foreground[center + channel] +
                  background[channel] * (1 - alpha / 255);
              expect(result[center + channel], closeTo(expected, 2));
            }
          } finally {
            exported.dispose();
          }
        } finally {
          layer.dispose();
        }
      } finally {
        shader?.dispose();
        design?.dispose();
        renderer.dispose();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets(
    'two saved revisions of one DIY id can coexist on different nails',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'nail_revisions_',
        );
        final renderer = NailRenderer(
          await _photo(128, 96),
          await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
        );
        try {
          final first = NailRegion.manual(
            1,
            const Offset(32, 48),
            128,
          ).copyWith(width: 30, height: 56);
          final second = NailRegion.manual(
            2,
            const Offset(96, 48),
            128,
          ).copyWith(width: 30, height: 56);
          await Future.wait([
            renderer.addMask(first),
            renderer.addMask(second),
          ]);
          final blue = NailStyle(
            'custom_one_id',
            '旧版',
            '',
            Colors.white,
            NailPattern.solid,
            texturePath: await _design(directory),
          );
          final red = NailStyle(
            'custom_one_id',
            '新版',
            '',
            Colors.white,
            NailPattern.solid,
            texturePath: await _design(
              directory,
              color: const Color(0xFFDD3344),
              name: 'red-revision',
            ),
          );
          final out = await renderer.export(
            [first, second],
            {1: blue, 2: red},
            .6,
          );
          try {
            final pixels = (await out.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final firstPixel = (48 * 128 + 32) * 4;
            final secondPixel = (48 * 128 + 96) * 4;
            expect(
              pixels[firstPixel + 2],
              greaterThan(pixels[firstPixel] + 60),
            );
            expect(
              pixels[secondPixel],
              greaterThan(pixels[secondPixel + 2] + 60),
            );
          } finally {
            out.dispose();
          }
        } finally {
          renderer.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('custom image is shaded inside the rotated nail, not on skin', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('nail_texture_');
      final renderer = NailRenderer(
        await _photo(128, 128),
        await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
      );
      try {
        final nail = NailRegion.manual(
          1,
          const Offset(85, 45),
          128,
        ).copyWith(width: 26, height: 38, angle: .42);
        await renderer.addMask(nail);
        final style = NailStyle(
          'custom_blue',
          '自选蓝图',
          '',
          Colors.white,
          NailPattern.solid,
          texturePath: await _design(directory),
        );
        expect(style.isCustom, isTrue);
        final out = await renderer.export([nail], {1: style}, .6);
        try {
          final pixels = (await out.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          final inside = (45 * 128 + 85) * 4;
          expect(pixels[inside + 2], greaterThan(pixels[inside] + 60));
          expect(pixels.sublist(0, 4), [217, 179, 155, 255]);
          expect(pixels[inside + 3], 255);
        } finally {
          out.dispose();
        }
      } finally {
        renderer.dispose();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('transparent DIY regions reveal the original nail', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('nail_clear_');
      final renderer = NailRenderer(
        await _photo(64, 96),
        await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
      );
      try {
        final nail = NailRegion.manual(
          1,
          const Offset(32, 48),
          64,
        ).copyWith(width: 50, height: 80);
        await renderer.addMask(nail);
        final style = NailStyle(
          'custom_clear',
          '透明红花',
          '',
          Colors.transparent,
          NailPattern.solid,
          coverage: 1,
          texturePath: await _design(directory, transparent: true),
        );
        for (final amount in [0.0, defaultNailCoatAmount, 2.0]) {
          final out = await renderer.export(
            [nail],
            {1: style},
            .6,
            coatAmounts: {1: amount},
          );
          try {
            final pixels = (await out.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final clear = (70 * 64 + 32) * 4;
            expect(pixels.sublist(clear, clear + 4), [217, 179, 155, 255]);
            final red = (32 * 64 + 32) * 4;
            expect(pixels[red], greaterThan(pixels[red + 2] + 65));
          } finally {
            out.dispose();
          }
        }
      } finally {
        renderer.dispose();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('editing a mask with the same nail id replaces cached coverage', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final renderer = NailRenderer(
        await _photo(64, 96),
        await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
      );
      try {
        final nail = NailRegion.manual(
          7,
          const Offset(32, 48),
          64,
        ).copyWith(width: 40, height: 60);
        final style = NailStyle.byId('wine')!;
        await renderer.addMask(nail);
        final painted = await renderer.export([nail], {7: style}, .6);
        final before = (await painted.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        painted.dispose();
        final center = (48 * 64 + 32) * 4;
        expect(before[center + 1], lessThan(100));

        // Deliberately reuse the mutable bytes: an id-only/identity-only cache
        // would incorrectly leave the old opaque nail visible.
        nail.maskRgba.fillRange(0, nail.maskRgba.length, 0);
        await renderer.addMask(nail.copyWith(maskRgba: nail.maskRgba));
        final cleared = await renderer.export([nail], {7: style}, .6);
        try {
          final after = (await cleared.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          expect(after.sublist(center, center + 4), [217, 179, 155, 255]);
        } finally {
          cleared.dispose();
        }
      } finally {
        renderer.dispose();
      }
    });
  });
}
