import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/segmentation_geometry.dart';

void _paint(
  List<double> probabilities, {
  required int left,
  required int top,
  int width = 4,
  int height = 5,
  double probability = .96,
}) {
  for (var y = top; y < top + height; y++) {
    for (var x = left; x < left + width; x++) {
      probabilities[y * 128 + x] = probability;
    }
  }
}

HandObservation _observation(List<double> xs, String side) {
  final points = List<Offset>.filled(21, const Offset(.5, .9));
  const tips = [4, 8, 12, 16, 20];
  const joints = [3, 7, 11, 15, 19];
  for (var f = 0; f < 5; f++) {
    points[tips[f]] = Offset(xs[f], .3);
    points[joints[f]] = Offset(xs[f], .5);
  }
  return HandObservation(points, side);
}

void main() {
  group('free-pose candidate recall', () {
    test('empty model output stays empty even with a detected hand', () {
      final hand = _observation([.1, .2, .3, .4, .5], 'Left');
      expect(
        extractNails(
          List.filled(128 * 128, 0),
          128,
          128,
          1000,
          800,
          hands: [hand],
        ),
        isEmpty,
      );
    });

    test(
      'uncertain skeleton association does not delete a strong nail mask',
      () {
        final probabilities = List<double>.filled(128 * 128, 0);
        _paint(probabilities, left: 104, top: 89);
        final unassociated = extractNails(probabilities, 128, 128, 1000, 800);
        expect(unassociated, hasLength(1));
        final withHand = extractNails(
          probabilities,
          128,
          128,
          1000,
          800,
          hands: [
            _observation([.1, .2, .3, .4, .5], 'Left'),
          ],
        );
        expect(withHand, hasLength(1));
        expect(withHand.single.label, startsWith('甲面'));
        expect(withHand.single.isManual, isFalse);
        expect(
          (withHand.single.center - unassociated.single.center).distance,
          lessThan(2),
        );
      },
    );

    test(
      'visible nails on the second hand are not discarded by a five-nail cap',
      () {
        final probabilities = List<double>.filled(128 * 128, 0);
        const xs = [.06, .15, .24, .33, .42, .58, .67, .76, .85, .94];
        for (final x in xs) {
          _paint(probabilities, left: (x * 128).round() - 2, top: 42);
        }
        final nails = extractNails(
          probabilities,
          128,
          128,
          1000,
          1000,
          hands: [
            _observation(xs.sublist(0, 5), 'Left'),
            _observation(xs.sublist(5), 'Right'),
          ],
        );
        expect(nails, hasLength(10));
        expect(nails.map((n) => n.id).toSet(), hasLength(10));
        expect(nails.map((n) => n.label).toSet(), hasLength(10));
        expect(nails.every((n) => !n.isManual), isTrue);
      },
    );
  });

  test(
    'three-to-five-pixel high-confidence nails survive the recall filter',
    () {
      final probabilities = List<double>.filled(128 * 128, 0);
      _paint(probabilities, left: 15, top: 20, width: 1, height: 3);
      _paint(probabilities, left: 35, top: 20, width: 2, height: 2);
      _paint(probabilities, left: 55, top: 20, width: 1, height: 5);
      final nails = extractNails(probabilities, 128, 128, 1280, 960);
      expect(nails, hasLength(3));
      expect(nails.every((n) => n.maskRgba.any((v) => v > 0)), isTrue);
    },
  );

  test('the more confident fragment receives the shared finger identity', () {
    final probabilities = List<double>.filled(128 * 128, 0);
    _paint(
      probabilities,
      left: 21,
      top: 41,
      width: 7,
      height: 7,
      probability: .7,
    );
    _paint(probabilities, left: 22, top: 54, width: 3, height: 3);
    final nails = extractNails(
      probabilities,
      128,
      128,
      1000,
      1000,
      hands: [
        _observation([.18, .4, .6, .8, .95], 'Left'),
      ],
    );
    expect(nails, hasLength(2));
    final thumb = nails.singleWhere((n) => n.label == '拇指');
    expect(thumb.center.dy, greaterThan(410));
  });

  test(
    'degenerate joints do not force an arbitrary finger name or rotation',
    () {
      final probabilities = List<double>.filled(128 * 128, 0);
      _paint(probabilities, left: 62, top: 60, width: 3, height: 7);
      final hand = HandObservation(
        List.filled(21, const Offset(.5, .5)),
        'Left',
      );
      final nails = extractNails(
        probabilities,
        128,
        128,
        1000,
        1000,
        hands: [hand],
      );
      expect(nails, hasLength(1));
      expect(nails.single.label, startsWith('甲面'));
      expect(nails.single.angle, closeTo(0, 1e-9));
    },
  );

  group('validated-view fusion', () {
    test(
      'weak background cannot be rescued by max with a small strong patch',
      () {
        final weak = List<double>.filled(128 * 128, 0);
        final strong = List<double>.filled(128 * 128, 0);
        _paint(weak, left: 20, top: 20, width: 6, height: 5, probability: .55);
        _paint(strong, left: 22, top: 21, width: 1, height: 3);
        final merged = mergeValidatedProbabilities([weak, strong], 128, 128);
        expect(merged.where((v) => v > 0), hasLength(3));
        expect(merged[20 * 128 + 20], 0);
        expect(extractNails(merged, 128, 128, 640, 640), hasLength(1));
      },
    );

    test('large constant and non-finite maps stay empty after fusion', () {
      final views = <List<double>>[
        List.filled(128 * 128, .99),
        List.filled(128 * 128, .55),
        List.filled(128 * 128, double.nan),
      ];
      final merged = mergeValidatedProbabilities(views, 128, 128);
      expect(merged.every((v) => v == 0), isTrue);
      expect(extractNails(merged, 128, 128, 640, 640), isEmpty);
    });

    test(
      'fusion retains original accepted probabilities and checks dimensions',
      () {
        final view = List<double>.filled(128 * 128, 0);
        _paint(view, left: 30, top: 40, width: 2, height: 2, probability: .73);
        final filtered = filterNailProbabilities(view, 128, 128);
        expect(filtered[40 * 128 + 30], .73);
        expect(
          filterNailProbabilities(List.filled(9, 0), 3, 3),
          List.filled(9, 0),
        );
        expect(
          () => mergeValidatedProbabilities([view], 32, 32),
          throwsArgumentError,
        );
      },
    );

    test(
      'real 0/180 outputs reproduce the validated ensemble probability map',
      () {
        List<double> fixture(String name) {
          final data = ByteData.sublistView(
            File('test/fixtures/$name.f32').readAsBytesSync(),
          );
          expect(data.lengthInBytes, 128 * 128 * 4);
          return List.generate(
            128 * 128,
            (i) => data.getFloat32(i * 4, Endian.little),
          );
        }

        final original = fixture('recall_original');
        final rotatedRaw = fixture('recall_rotated180_raw');
        // A 180-degree inverse rotation on a square pixel grid is a reversal.
        final rotatedCanonical = rotatedRaw.reversed.toList();
        final expected = fixture('recall_ensemble_expected');
        final merged = mergeValidatedProbabilities(
          [original, rotatedCanonical],
          128,
          128,
        );
        var maxError = 0.0;
        for (var i = 0; i < merged.length; i++) {
          maxError = math.max(maxError, (merged[i] - expected[i]).abs());
        }
        expect(maxError, lessThan(1e-7));
        final nails = extractNails(merged, 128, 128, 640, 640);
        expect(nails, hasLength(5));
      },
    );
  });
}
