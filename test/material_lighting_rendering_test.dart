import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_renderer.dart';

const _width = 160, _height = 200;
const _polish = Color(0xFF4E315B), _accent = Color(0xFFF1D4EF);

void main() {
  testWidgets('coat amount layers pigment within the same mask and export', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final fixture = await _Fixture.create();
      try {
        final style = NailStyle.all.firstWhere(
          (style) => style.pattern == NailPattern.jelly,
        );
        final original = await _pixels(fixture.renderer.photo);
        final thin = await fixture.render(style, .65, 1.23, coatAmount: 0);
        final standard = await fixture.render(style, .65, 1.23);
        final thick = await fixture.render(style, .65, 1.23, coatAmount: 2);
        const center = ((_height ~/ 2) * _width + _width ~/ 2) * 4;
        final standardDelta = _difference(standard, original, center);
        expect(_difference(thin, original, center), lessThan(standardDelta));
        expect(
          _difference(thick, original, center),
          greaterThan(standardDelta),
        );
        _outsideUnchanged(thin);
        _outsideUnchanged(thick);
        final solid = _style(NailPattern.solid);
        final solidStandard = await fixture.render(solid, .65, 1.23);
        final solidThick = await fixture.render(
          solid,
          .65,
          1.23,
          coatAmount: 2,
        );
        expect(_difference(solidStandard, solidThick, center), greaterThan(5));
        _outsideUnchanged(solidThick);

        final recorder = ui.PictureRecorder();
        fixture.renderer.paint(
          Canvas(recorder),
          const Size(160, 200),
          [fixture.nail],
          {0: style},
          .65,
          coatAmounts: const {0: 2},
          lightDirection: 1.23,
        );
        final picture = recorder.endRecording();
        final preview = await picture.toImage(_width, _height);
        picture.dispose();
        try {
          expect(await _pixels(preview), orderedEquals(thick));
        } finally {
          preview.dispose();
        }
      } finally {
        fixture.renderer.dispose();
      }
    });
  });

  testWidgets(
    'glitter facets stay in place while a lamp activates different flakes',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _Fixture.create();
        try {
          final plain = await fixture.render(_style(NailPattern.solid), 0, 0);
          final left = await fixture.render(
            _style(NailPattern.shimmer),
            0,
            math.pi,
            name: 'glitter_left',
          );
          final right = await fixture.render(
            _style(NailPattern.shimmer),
            0,
            0,
            name: 'glitter_right',
          );
          final repeated = await fixture.render(
            _style(NailPattern.shimmer),
            0,
            math.pi,
          );
          expect(repeated, orderedEquals(left));
          var supportUnion = 0,
              supportIntersection = 0,
              changing = 0,
              white = 0;
          for (var y = 30; y < 170; y++) {
            for (var x = 40; x < 120; x++) {
              final i = (y * _width + x) * 4;
              final a = _difference(left, plain, i) > 3;
              final b = _difference(right, plain, i) > 3;
              if (a || b) supportUnion++;
              if (a && b) supportIntersection++;
              if (_difference(left, right, i) > 6) changing++;
              if (right[i] > 240 && right[i + 1] > 240 && right[i + 2] > 240) {
                white++;
              }
            }
          }
          expect(supportUnion, greaterThan(300));
          expect(
            supportIntersection / supportUnion,
            greaterThan(.86),
            reason: 'The cured flake footprints must not move with the lamp',
          );
          expect(
            changing,
            greaterThan(100),
            reason:
                'Flake brightness must respond individually instead of a static dotted texture',
          );
          expect(
            white / (80 * 140),
            lessThan(.025),
            reason: 'Glitter cannot wash the whole color base white',
          );
          _outsideUnchanged(left);
          _outsideUnchanged(right);
        } finally {
          fixture.renderer.dispose();
        }
      });
    },
  );

  testWidgets(
    'magnetic light band moves across its fixed magnetic axis and retains a colored base',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _Fixture.create();
        try {
          final style = _style(NailPattern.catEye);
          final left = await fixture.render(
            style,
            0,
            math.pi,
            name: 'cat_eye_left',
          );
          final right = await fixture.render(
            style,
            0,
            0,
            name: 'cat_eye_right',
          );
          final a = _brightRegion(left), b = _brightRegion(right);
          expect(b.center.dx - a.center.dx, greaterThan(12));
          expect(
            _axisDifference(a.axis, b.axis),
            lessThan(.20),
            reason: 'Changing the lamp is not rotating the magnet pattern',
          );
          expect(a.elongation, greaterThan(2));
          expect(b.elongation, greaterThan(2));
          var darkColored = 0;
          for (var y = 45; y < 155; y++) {
            for (var x = 49; x < 111; x++) {
              final i = (y * _width + x) * 4;
              if (right[i + 2] > right[i + 1] + 3 &&
                  _brightness(right, i) < 350) {
                darkColored++;
              }
            }
          }
          expect(
            darkColored,
            greaterThan(2000),
            reason:
                'The magnetic highlight must leave a visible color/dark field',
          );
          _outsideUnchanged(left);
          _outsideUnchanged(right);
          final rotated = await fixture.render(style, 0, 0, angle: math.pi);
          final rotatedLeft = await fixture.render(
            style,
            0,
            math.pi,
            angle: math.pi,
          );
          // A rotated fixed particle field need not contain the same brightest
          // grains. Compare the lamp-induced gain, cancelling that fixed field.
          final gain = _gainCenter(right, left);
          final rotatedGain = _gainCenter(rotated, rotatedLeft);
          expect(gain.dx, greaterThan(85));
          expect(rotatedGain.dx, greaterThan(85));
          expect(rotatedGain.dx, closeTo(gain.dx, 3));
        } finally {
          fixture.renderer.dispose();
        }
      });
    },
  );

  testWidgets(
    'special materials use the selected lamp identically in preview and export',
    (tester) async {
      await tester.runAsync(() async {
        final fixture = await _Fixture.create();
        try {
          for (final kind in [
            NailPattern.shimmer,
            NailPattern.catEye,
            NailPattern.velvet,
            NailPattern.chromeFrench,
          ]) {
            final style = _style(kind),
                nail = fixture.nail.copyWith(angle: .37);
            final expected = await fixture.render(style, .86, 1.23, angle: .37);
            final recorder = ui.PictureRecorder();
            fixture.renderer.paint(
              Canvas(recorder),
              const Size(160, 200),
              [nail],
              {0: style},
              .86,
              lightDirection: 1.23,
            );
            final picture = recorder.endRecording();
            final preview = await picture.toImage(_width, _height);
            picture.dispose();
            try {
              expect(
                await _pixels(preview),
                orderedEquals(expected),
                reason: kind.name,
              );
            } finally {
              preview.dispose();
            }
          }
        } finally {
          fixture.renderer.dispose();
        }
      });
    },
  );
}

NailStyle _style(NailPattern pattern) => NailStyle(
  'material-${pattern.name}',
  pattern.name,
  '',
  _polish,
  pattern,
  accent: _accent,
  coverage: 1,
  variant: .4,
);

class _Fixture {
  _Fixture(this.renderer, this.nail);
  final NailRenderer renderer;
  final NailRegion nail;

  static Future<_Fixture> create() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawColor(const Color(0xFFD9B39B), BlendMode.src);
    final picture = recorder.endRecording();
    final photo = await picture.toImage(_width, _height);
    picture.dispose();
    final renderer = NailRenderer(
      photo,
      await ui.FragmentProgram.fromAsset('shaders/nail.frag'),
    );
    final nail = NailRegion.manual(
      0,
      const Offset(80, 100),
      160,
    ).copyWith(width: 98, height: 158);
    await renderer.addMask(nail);
    return _Fixture(renderer, nail);
  }

  Future<Uint8List> render(
    NailStyle style,
    double gloss,
    double direction, {
    double angle = 0,
    double coatAmount = defaultNailCoatAmount,
    String? name,
  }) async {
    final region = nail.copyWith(angle: angle);
    final image = await renderer.export(
      [region],
      {0: style},
      gloss,
      coatAmounts: {0: coatAmount},
      lightDirection: direction,
    );
    try {
      final folder = Platform.environment['NAIL_MATERIAL_OUTPUT'];
      if (folder != null && name != null) {
        await Directory(folder).create(recursive: true);
        await File('$folder/$name.png').writeAsBytes(
          (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!.buffer.asUint8List(),
        );
      }
      return await _pixels(image);
    } finally {
      image.dispose();
    }
  }
}

({Offset center, double axis, double elongation}) _brightRegion(
  Uint8List pixels,
) {
  final brightness = <int>[];
  for (var y = 35; y < 165; y++) {
    for (var x = 42; x < 118; x++) {
      brightness.add(_brightness(pixels, (y * _width + x) * 4));
    }
  }
  brightness.sort();
  final threshold = brightness[(brightness.length * .86).floor()];
  final points = <Offset>[];
  for (var y = 35; y < 165; y++) {
    for (var x = 42; x < 118; x++) {
      if (_brightness(pixels, (y * _width + x) * 4) >= threshold) {
        points.add(Offset(x + .5, y + .5));
      }
    }
  }
  final center = points.reduce((a, b) => a + b) / points.length.toDouble();
  var xx = 0.0, yy = 0.0, xy = 0.0;
  for (final point in points) {
    final delta = point - center;
    xx += delta.dx * delta.dx;
    yy += delta.dy * delta.dy;
    xy += delta.dx * delta.dy;
  }
  final spread = math.sqrt((xx - yy) * (xx - yy) + 4 * xy * xy);
  return (
    center: center,
    axis: .5 * math.atan2(2 * xy, xx - yy),
    elongation: (xx + yy + spread) / math.max(1, xx + yy - spread),
  );
}

double _axisDifference(double a, double b) {
  final difference = (a - b).abs() % math.pi;
  return math.min(difference, math.pi - difference);
}

Offset _gainCenter(Uint8List lit, Uint8List opposite) {
  var total = 0.0;
  var weighted = Offset.zero;
  for (var y = 30; y < 170; y++) {
    for (var x = 38; x < 122; x++) {
      final i = (y * _width + x) * 4;
      final gain = math
          .max(0, _brightness(lit, i) - _brightness(opposite, i))
          .toDouble();
      total += gain;
      weighted += Offset(x + .5, y + .5) * gain;
    }
  }
  expect(total, greaterThan(1000));
  return weighted / total;
}

int _brightness(Uint8List pixels, int offset) =>
    pixels[offset] + pixels[offset + 1] + pixels[offset + 2];
int _difference(Uint8List a, Uint8List b, int offset) =>
    (a[offset] - b[offset]).abs() +
    (a[offset + 1] - b[offset + 1]).abs() +
    (a[offset + 2] - b[offset + 2]).abs();
void _outsideUnchanged(Uint8List pixels) {
  for (final point in [
    const Offset(0, 0),
    const Offset(15, 100),
    const Offset(145, 100),
    const Offset(80, 10),
    const Offset(80, 190),
  ]) {
    final index = (point.dy.toInt() * _width + point.dx.toInt()) * 4;
    expect(pixels.sublist(index, index + 4), [217, 179, 155, 255]);
  }
}

Future<Uint8List> _pixels(ui.Image image) async => (await image.toByteData(
  format: ui.ImageByteFormat.rawRgba,
))!.buffer.asUint8List();
