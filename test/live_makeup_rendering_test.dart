import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/services/photo_makeup.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const eye = [
    Offset(.29, .40),
    Offset(.33, .38),
    Offset(.40, .38),
    Offset(.45, .40),
    Offset(.40, .42),
    Offset(.33, .42),
  ];
  final regions = <String, List<Offset>>{
    'outline': const [
      Offset(.22, .27),
      Offset(.36, .17),
      Offset(.64, .17),
      Offset(.78, .27),
      Offset(.78, .55),
      Offset(.69, .73),
      Offset(.50, .86),
      Offset(.31, .73),
      Offset(.22, .55),
    ],
    'eyeA': eye,
    'eyeB': eye.map((p) => p + const Offset(.25, 0)).toList(),
    'outerLips': const [
      Offset(.39, .65),
      Offset(.46, .60),
      Offset(.54, .61),
      Offset(.60, .60),
      Offset(.67, .65),
      Offset(.60, .71),
      Offset(.54, .72),
      Offset(.46, .71),
    ],
    'innerLips': const [
      Offset(.45, .66),
      Offset(.49, .64),
      Offset(.58, .64),
      Offset(.62, .66),
      Offset(.58, .69),
      Offset(.49, .69),
    ],
  };

  Future<Uint8List> layer(
    MakeupFaceGeometry geometry,
    MakeupDesign design, {
    bool mirrored = false,
  }) async {
    final recorder = ui.PictureRecorder();
    paintLiveMakeup(
      Canvas(recorder),
      const Rect.fromLTWH(0, 0, 200, 200),
      geometry,
      design,
      mirrored: mirrored,
    );
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(200, 200);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
      } finally {
        image.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  int alpha(Uint8List pixels, int x, int y) => pixels[(y * 200 + x) * 4 + 3];

  MakeupFaceGeometry measured(
    Map<String, List<Offset>> points, {
    required Map<String, double> skin,
  }) => makeupFaceGeometryFromNative({
    'faceCount': 1,
    'width': 200,
    'height': 200,
    'makeupRegions': {
      for (final entry in points.entries)
        entry.key: [
          for (final p in entry.value) [p.dx, p.dy],
        ],
    },
    'skinSample': skin,
  })!;

  test(
    'low light adapts only selected pigment and rolled mouth stays clear',
    () async {
      final shade = const MakeupDesign().setLayer(
        MakeupPart.lipstick,
        const MakeupLayer(color: Color(0xffb75265), amount: .72),
      );
      final neutral = measured(
        regions,
        skin: {'r': .73, 'g': .61, 'b': .53, 'confidence': .96},
      );
      final dark = measured(
        regions,
        skin: {'r': .35, 'g': .25, 'b': .20, 'confidence': .96},
      );
      final normalPaint = await layer(neutral, shade);
      final darkPaint = await layer(dark, shade);
      const lip = (124 * 200 + 107) * 4;
      expect(darkPaint[lip], lessThan(normalPaint[lip]));
      expect(darkPaint[lip + 3], normalPaint[lip + 3]);
      expect(alpha(darkPaint, 108, 132), 0);
      expect(alpha(darkPaint, 45, 98), 0);
      const angle = .28;
      Offset rotate(Offset p) {
        final d = p - const Offset(.5, .5);
        return const Offset(.5, .5) +
            Offset(
              d.dx * math.cos(angle) - d.dy * math.sin(angle),
              d.dx * math.sin(angle) + d.dy * math.cos(angle),
            );
      }

      final rolled = MakeupFaceGeometry(
        regions.map(
          (key, points) => MapEntry(key, points.map(rotate).toList()),
        ),
      );
      final matte = await layer(rolled, shade);
      final glossy = await layer(
        rolled,
        shade.setLayer(
          MakeupPart.lipstick,
          shade.layer(MakeupPart.lipstick).copyWith(style: 4),
        ),
      );
      final sparkling = await layer(
        rolled,
        shade.setLayer(
          MakeupPart.lipstick,
          shade.layer(MakeupPart.lipstick).copyWith(style: 5),
        ),
      );
      final mouth = rotate(const Offset(.54, .66)) * 200;
      expect(alpha(glossy, mouth.dx.round(), mouth.dy.round()), 0);
      expect(alpha(sparkling, mouth.dx.round(), mouth.dy.round()), 0);
      expect(glossy, isNot(orderedEquals(matte)));
      expect(sparkling, isNot(orderedEquals(glossy)));
    },
  );

  test(
    'default live preview is clear and selected pigment tracks lips and mirror',
    () async {
      final geometry = MakeupFaceGeometry(regions);
      final clear = await layer(geometry, const MakeupDesign());
      expect(clear.every((value) => value == 0), isTrue);
      const tint = MakeupLayer(color: Color(0xffb63856), amount: .7);
      final design = const MakeupDesign().setLayer(MakeupPart.lipstick, tint);
      final full = await layer(geometry, design);
      final light = await layer(
        geometry,
        design.setLayer(MakeupPart.lipstick, tint.copyWith(amount: .25)),
      );
      expect(alpha(full, 107, 124), greaterThan(alpha(light, 107, 124)));
      expect(alpha(light, 107, 124), greaterThan(0));
      expect(
        alpha(full, 108, 132),
        0,
        reason: 'Measured mouth gap is excluded.',
      );
      expect(
        alpha(full, 35, 60),
        0,
        reason: 'No pigment outside selected region.',
      );
      final mirror = await layer(geometry, design, mirrored: true);
      expect(alpha(mirror, 92, 124), closeTo(alpha(full, 107, 124), 3));
      final shifted = MakeupFaceGeometry(
        regions.map(
          (name, points) => MapEntry(
            name,
            points.map((p) => p + const Offset(.12, 0)).toList(),
          ),
        ),
      );
      final moved = await layer(shifted, design);
      expect(alpha(moved, 131, 124), closeTo(alpha(full, 107, 124), 3));
    },
  );

  test(
    'face tracking eases jitter and discards old geometry across a long gap',
    () {
      final first = MakeupFaceGeometry(regions);
      final moved = MakeupFaceGeometry(
        regions.map(
          (name, points) => MapEntry(
            name,
            points.map((p) => p + const Offset(.01, 0)).toList(),
          ),
        ),
      );
      final filtered = first.smoothToward(moved, elapsedSeconds: .033);
      final point = filtered.region('eyeA').first.dx;
      expect(point, inExclusiveRange(.29, .30));
      expect(first.smoothToward(moved, elapsedSeconds: .4), same(moved));
      expect(makeupFaceGeometryFromNative({'faceCount': 2}), isNull);
    },
  );
}
