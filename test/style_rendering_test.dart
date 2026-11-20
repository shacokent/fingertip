import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';

void main() {
  testWidgets('pattern rendering changes the design while protecting skin', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xFFD9B39B), BlendMode.src);
      final picture = recorder.endRecording();
      final photo = await picture.toImage(80, 112);
      picture.dispose();
      final program = await ui.FragmentProgram.fromAsset('shaders/nail.frag');
      final renderer = NailRenderer(photo, program);
      final nail = NailRegion.manual(
        0,
        const Offset(40, 56),
        80,
      ).copyWith(width: 54, height: 88, angle: .18);
      await renderer.addMask(nail);
      final signatures = <String>{};
      try {
        for (final pattern in NailPattern.values) {
          final style = NailStyle(
            'test-${pattern.name}',
            pattern.name,
            '',
            const Color(0xFF885666),
            pattern,
            accent: const Color(0xFFFFDFA1),
            variant: .37,
          );
          final rendered = await renderer.export([nail], {0: style}, .65);
          try {
            final data = (await rendered.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            expect(data.sublist(0, 4), [217, 179, 155, 255]);
            expect(data[(56 * 80 + 40) * 4 + 3], 255);
            signatures.add(base64Encode(data));
          } finally {
            rendered.dispose();
          }
        }
        // A shared base palette still produces distinct visual pattern types.
        expect(signatures.length, NailPattern.values.length);
      } finally {
        renderer.dispose();
      }
    });
  });
}
