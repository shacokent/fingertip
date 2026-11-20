import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';

void main() {
  testWidgets(
    'rotated nail shader changes the nail and preserves the background',
    (tester) async {
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(const Color(0xFFDBAF96), BlendMode.src);
        final picture = recorder.endRecording();
        final photo = await picture.toImage(128, 128);
        picture.dispose();
        final program = await ui.FragmentProgram.fromAsset('shaders/nail.frag');
        final renderer = NailRenderer(photo, program);
        final nail = NailRegion.manual(
          0,
          const Offset(85, 45),
          128,
        ).copyWith(width: 26, height: 38, angle: .42);
        await renderer.addMask(nail);
        final out = await renderer.export([nail], {0: NailStyle.all[1]}, .6);
        final bytes = (await out.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        final pixels = bytes.buffer.asUint8List();
        final outside = (10 * 128 + 10) * 4;
        expect(pixels.sublist(outside, outside + 4), [219, 175, 150, 255]);
        final inside = (45 * 128 + 85) * 4;
        expect(pixels[inside + 1], lessThan(130));
        expect(pixels[inside + 3], 255);
        out.dispose();
        renderer.dispose();
      });
    },
  );
}
