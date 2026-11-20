import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/segmentation_geometry.dart';

void _rectangle(
  List<double> probabilities,
  int width, {
  required int left,
  required int top,
  required int columns,
  required int rows,
  double probability = .95,
}) {
  for (var y = top; y < top + rows; y++) {
    for (var x = left; x < left + columns; x++) {
      probabilities[y * width + x] = probability;
    }
  }
}

HandObservation _hand({List<double> fingerXs = const [.15, .3, .5, .7, .88]}) {
  final points = List<Offset>.filled(21, const Offset(.5, .9));
  const tips = [4, 8, 12, 16, 20];
  const joints = [3, 7, 11, 15, 19];
  for (var finger = 0; finger < 5; finger++) {
    points[tips[finger]] = Offset(fingerXs[finger], .3);
    points[joints[finger]] = Offset(fingerXs[finger], .5);
  }
  return HandObservation(points, 'Left');
}

void main() {
  group('connected components', () {
    test('empty and background-only predictions do not invent nails', () {
      expect(connectedComponents(const [], 0, 0), isEmpty);
      expect(extractNails(List.filled(64 * 64, 0), 64, 64, 640, 480), isEmpty);
      expect(
        extractNails(List.filled(64 * 64, .49), 64, 64, 640, 480),
        isEmpty,
      );
    });

    test('diagonal pixels form one eight-connected component', () {
      final probabilities = List<double>.filled(25, 0);
      probabilities[0] = probabilities[6] = probabilities[12] = .9;
      final components = connectedComponents(probabilities, 5, 5);
      expect(components, hasLength(1));
      expect(components.single, unorderedEquals([0, 6, 12]));
    });

    test('row boundaries do not wrap into adjacent components', () {
      final probabilities = List<double>.filled(15, 0);
      probabilities[4] = probabilities[5] = .9;
      expect(
        connectedComponents(probabilities, 5, 3, minArea: 1),
        hasLength(2),
      );
    });

    test('NaN and infinities cannot become foreground or connect regions', () {
      final probabilities = <double>[
        .9,
        double.nan,
        .9,
        double.infinity,
        double.negativeInfinity,
        double.nan,
        .9,
        double.infinity,
        .9,
      ];
      final components = connectedComponents(probabilities, 3, 3, minArea: 1);
      expect(components, hasLength(4));
      expect(components.every((component) => component.length == 1), isTrue);
      expect(extractNails(probabilities, 3, 3, 300, 300), isEmpty);
    });

    test('mismatched probability dimensions fail explicitly', () {
      expect(() => connectedComponents(const [.9], 2, 2), throwsArgumentError);
    });
  });

  group('candidate geometry', () {
    test(
      'a plausible component produces finite geometry and an alpha mask',
      () {
        final probabilities = List<double>.filled(32 * 32, 0);
        _rectangle(probabilities, 32, left: 10, top: 8, columns: 3, rows: 7);
        final nails = extractNails(probabilities, 32, 32, 640, 480);
        expect(nails, hasLength(1));
        final nail = nails.single;
        expect(nail.center.dx.isFinite && nail.center.dy.isFinite, isTrue);
        expect(nail.width.isFinite && nail.height.isFinite, isTrue);
        expect(nail.width, greaterThan(0));
        expect(nail.height, greaterThan(0));
        expect(nail.angle.isFinite, isTrue);
        expect(nail.isManual, isFalse);
        expect(nail.maskRgba, hasLength(nail.maskWidth * nail.maskHeight * 4));
        expect(nail.maskRgba.any((value) => value > 0), isTrue);
        expect(nail.maskRgba.any((value) => value == 0), isTrue);
        for (var i = 0; i < nail.maskRgba.length; i += 4) {
          // White alpha masks use premultiplied RGBA consistently.
          expect(nail.maskRgba[i], nail.maskRgba[i + 3]);
          expect(nail.maskRgba[i + 1], nail.maskRgba[i + 3]);
          expect(nail.maskRgba[i + 2], nail.maskRgba[i + 3]);
        }
      },
    );

    test(
      'tiny noise, low-confidence components and oversized areas are rejected',
      () {
        final probabilities = List<double>.filled(100 * 100, 0);
        _rectangle(probabilities, 100, left: 10, top: 10, columns: 1, rows: 2);
        _rectangle(
          probabilities,
          100,
          left: 30,
          top: 30,
          columns: 5,
          rows: 5,
          probability: .54,
        );
        expect(extractNails(probabilities, 100, 100, 640, 480), isEmpty);
        expect(extractNails(List.filled(400, .99), 20, 20, 640, 480), isEmpty);
      },
    );

    test('components are assigned to their closest fingers once each', () {
      final probabilities = List<double>.filled(100 * 100, 0);
      for (final left in [13, 28, 48, 68, 86]) {
        _rectangle(
          probabilities,
          100,
          left: left,
          top: 33,
          columns: 5,
          rows: 4,
        );
      }
      final nails = extractNails(
        probabilities,
        100,
        100,
        1000,
        800,
        hands: [_hand()],
      );
      expect(nails, hasLength(5));
      expect(nails.map((nail) => nail.label), ['拇指', '食指', '中指', '无名指', '小指']);
      expect(nails.map((nail) => nail.id).toSet(), hasLength(5));
      expect(nails.map((nail) => nail.label).toSet(), hasLength(5));
    });

    test(
      'a second fragment is retained without taking its neighbour identity',
      () {
        final probabilities = List<double>.filled(100 * 100, 0);
        _rectangle(probabilities, 100, left: 16, top: 32, columns: 5, rows: 5);
        _rectangle(probabilities, 100, left: 17, top: 41, columns: 3, rows: 3);
        final nails = extractNails(
          probabilities,
          100,
          100,
          1000,
          1000,
          hands: [
            _hand(fingerXs: [.18, .28, .5, .7, .88]),
          ],
        );
        expect(nails, hasLength(2));
        expect(nails.where((n) => n.label == '拇指'), hasLength(1));
        expect(nails.where((n) => n.label.startsWith('甲面')), hasLength(1));
      },
    );

    test('foreground far from fingertips stays an unassigned candidate', () {
      final probabilities = List<double>.filled(100 * 100, 0);
      _rectangle(probabilities, 100, left: 85, top: 85, columns: 5, rows: 5);
      final nails = extractNails(
        probabilities,
        100,
        100,
        1000,
        1000,
        hands: [_hand()],
      );
      expect(nails, hasLength(1));
      expect(nails.single.label, startsWith('甲面'));
    });

    test('hit testing uses the rotated local rectangle', () {
      final nail = NailRegion.manual(
        1,
        const Offset(100, 100),
        640,
      ).copyWith(width: 20, height: 80, angle: math.pi / 2);
      expect(nail.contains(const Offset(130, 100)), isTrue);
      expect(nail.contains(const Offset(100, 115)), isFalse);
      expect(nail.toLocal(nail.center), Offset.zero);
    });
  });

  test('full-image model fixture retains five nails and filters fabric', () {
    final bytes = File(
      'test/fixtures/upstream_hand_probabilities.f32',
    ).readAsBytesSync();
    expect(bytes.length, 128 * 128 * 4);
    final data = ByteData.sublistView(bytes);
    final probabilities = List<double>.generate(
      128 * 128,
      (index) => data.getFloat32(index * 4, Endian.little),
    );
    // This is a real stored output, not a synthetic five-region template.
    // Two weak components at the top of the source image are fabric.
    expect(connectedComponents(probabilities, 128, 128), hasLength(7));
    final nails = extractNails(probabilities, 128, 128, 640, 640);
    expect(nails, hasLength(5));
    expect(nails.every((nail) => nail.center.dy > 128), isTrue);
    const expectedCenters = [
      Offset(124.57, 339.93),
      Offset(183.65, 246.03),
      Offset(274.14, 201.80),
      Offset(366.86, 217.30),
      Offset(550.75, 354.81),
    ];
    for (var index = 0; index < nails.length; index++) {
      // Rotated bounds can shift from the probability centroid slightly.
      expect(
        (nails[index].center - expectedCenters[index]).distance,
        lessThan(15),
      );
      expect(nails[index].maskRgba.any((value) => value > 0), isTrue);
    }
  });
}
