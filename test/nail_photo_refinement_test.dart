import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_photo_refinement.dart';
import 'package:offline_nail_demo/services/nail_segmentation.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List photo;
  late NailSegmentationEngine engine;
  setUp(() {
    final image = img.Image(width: 128, height: 128, numChannels: 3);
    img.fill(image, color: img.ColorRgb8(100, 150, 200));
    photo = img.encodePng(image);
    engine = NailSegmentationEngine();
  });
  tearDown(() => engine.close());

  test(
    'only a disputed thumb with repeated pad texture is discarded',
    () async {
      final image = img.Image(width: 180, height: 160, numChannels: 3);
      for (final pixel in image) {
        final ridge = (6 * math.cos(pixel.x * math.pi / 2)).round();
        pixel.setRgb(152 + ridge, 119 + ridge, 95 + ridge);
      }
      final frame = _nail();
      NailRegion candidate(int id, String label) => NailRegion(
        id: id,
        label: label,
        center: frame.center,
        width: 80,
        height: 85,
        angle: 0,
        maskRgba: frame.maskRgba,
        maskWidth: frame.maskWidth,
        maskHeight: frame.maskHeight,
      );
      final disputed = candidate(1, '拇指');
      final index = candidate(2, '食指');
      final otherThumb = candidate(3, '右手·拇指');
      final result = await suppressUnsupportedPhotoNails(
        pngBytes: img.encodePng(image),
        nails: [disputed, index, otherThumb],
        initialIds: {1, 2, 3},
        singleViewIds: const {},
        reports: const [
          PhotoRefinementReport(
            nailId: 1,
            accepted: false,
            reason: 'geometry_guard',
          ),
          PhotoRefinementReport(
            nailId: 2,
            accepted: false,
            reason: 'geometry_guard',
          ),
        ],
      );
      expect(result.map((nail) => nail.id), [2, 3]);
    },
  );

  test(
    'deduplicates a recovered fragment without removing adjacent nails',
    () async {
      final known = _nail();
      NailRegion fragment(int id, Offset center) => NailRegion(
        id: id,
        label: '局部甲面',
        center: center,
        width: known.width / 4,
        height: known.height / 4,
        angle: known.angle,
        maskRgba: known.maskRgba,
        maskWidth: known.maskWidth,
        maskHeight: known.maskHeight,
      );
      final duplicate = fragment(91, known.center);
      final neighbor = fragment(92, known.center + Offset(known.width, 0));
      final result = await suppressUnsupportedPhotoNails(
        pngBytes: photo,
        nails: [known, duplicate, neighbor],
        initialIds: {known.id},
        singleViewIds: const {},
        reports: const [],
      );
      expect(result.map((nail) => nail.id), [known.id, neighbor.id]);
    },
  );

  test('accepted local boundary preserves axes and a solid interior', () async {
    final nail = _nail();
    final reports = <PhotoRefinementReport>[];
    var calls = 0;
    final result = await refinePhotoNails(
      pngBytes: photo,
      imageWidth: 128,
      imageHeight: 128,
      nails: [nail],
      coarseProbabilities: _coarse(nail),
      engine: engine,
      predictor: (tensor) async {
        calls++;
        expect(tensor.length, 3 * 128 * 128);
        // The ROI extends beyond the photograph. Edge replication must not
        // inject a black padded border into this uniformly colored image.
        expect(tensor.first, closeTo(100 / 127.5 - 1, 1e-6));
        expect(tensor[16383], closeTo(tensor.first, 1e-6));
        expect(tensor[16384], closeTo(150 / 127.5 - 1, 1e-6));
        expect(tensor.last, closeTo(200 / 127.5 - 1, 1e-6));
        return _local(nail, extendRight: 2);
      },
      onRefinement: reports.add,
    );
    expect(calls, 1);
    expect(reports.single.accepted, isTrue);
    expect(reports.single.overlap, greaterThan(.65));
    expect(reports.single.fieldWidth, lessThan(64));
    expect(reports.single.fieldHeight, lessThan(96));
    final refined = result.single;
    expect(refined.id, nail.id);
    expect(refined.label, nail.label);
    expect(refined.isManual, nail.isManual);
    expect(refined.enabled, nail.enabled);
    expect(refined.center, nail.center);
    expect(refined.angle, nail.angle);
    expect(refined.maskWidth, 128);
    expect(refined.maskHeight, 192);
    expect(_alpha(refined, nail.center), greaterThan(250));
    expect(_alpha(refined, const Offset(2, 120)), 0);
    expect(
      refined.width,
      nail.width,
      reason: 'No empty frame growth may change pattern UVs',
    );
    expect(refined.height, nail.height);
    expect(refined.maskRgba.length, 128 * 192 * 4);
    expect(
      photoNailEdgeReviews(
        nails: result,
        imageWidth: 128,
        imageHeight: 128,
        reports: reports,
      ),
      isEmpty,
    );
  });

  test(
    'overlapping but radically shifted prediction retains exact old object',
    () async {
      final nail = _nail();
      final reports = <PhotoRefinementReport>[];
      final result = await refinePhotoNails(
        pngBytes: photo,
        imageWidth: 128,
        imageHeight: 128,
        nails: [nail],
        coarseProbabilities: _coarse(nail),
        engine: engine,
        predictor: (_) async => _local(nail, shiftX: 15),
        onRefinement: reports.add,
      );
      expect(reports.single.accepted, isFalse);
      expect(reports.single.reason, 'geometry_guard');
      expect(identical(result.single, nail), isTrue);
      expect(
        photoNailEdgeReviews(
          nails: result,
          imageWidth: 128,
          imageHeight: 128,
          reports: reports,
        ),
        {nail.id: NailEdgeReviewReason.localFitMismatch},
      );
    },
  );

  test(
    'broad low-probability edge is flagged after local fit is accepted',
    () async {
      final nail = _nail();
      final reports = <PhotoRefinementReport>[];
      final result = await refinePhotoNails(
        pngBytes: photo,
        imageWidth: 128,
        imageHeight: 128,
        nails: [nail],
        coarseProbabilities: _coarse(nail),
        engine: engine,
        predictor: (_) async => _local(nail, weakBand: 5),
        onRefinement: reports.add,
      );
      expect(reports.single.accepted, isTrue);
      expect(reports.single.weakBoundary, isTrue);
      expect(
        photoNailEdgeReviews(
          nails: result,
          imageWidth: 128,
          imageHeight: 128,
          reports: reports,
        ),
        {nail.id: NailEdgeReviewReason.softBoundary},
      );
    },
  );

  test('review checks actual mask near the photo edge, not its padded box', () {
    final paddedOnly = _nail().copyWith(center: const Offset(19, 64), angle: 0);
    final clipped = paddedOnly.copyWith(center: const Offset(15, 64));
    final manual = NailRegion.manual(100, const Offset(0, 64), 128);
    final failed = PhotoRefinementReport(
      nailId: paddedOnly.id,
      accepted: false,
      reason: 'prediction_failed',
    );
    expect(
      photoNailEdgeReviews(
        nails: [paddedOnly, clipped.copyWith(enabled: false), manual],
        imageWidth: 128,
        imageHeight: 128,
        reports: [failed],
      ),
      isEmpty,
    );
    final reviews = photoNailEdgeReviews(
      nails: [clipped],
      imageWidth: 128,
      imageHeight: 128,
      reports: [
        PhotoRefinementReport(
          nailId: clipped.id,
          accepted: false,
          reason: 'geometry_guard',
        ),
      ],
    );
    expect(reviews, {clipped.id: NailEdgeReviewReason.photoEdge});
  });

  test(
    'unreliable, missing coarse seed and failed inference preserve coverage',
    () async {
      final nail = _nail();
      for (final failure in ['blank', 'coarse', 'throw', 'invalid']) {
        final reports = <PhotoRefinementReport>[];
        final result = await refinePhotoNails(
          pngBytes: photo,
          imageWidth: 128,
          imageHeight: 128,
          nails: [nail],
          coarseProbabilities: failure == 'coarse'
              ? List<double>.filled(128 * 128, 0)
              : _coarse(nail),
          engine: engine,
          predictor: (_) async {
            if (failure == 'throw') throw StateError('test predictor failed');
            if (failure == 'invalid') return [double.nan];
            if (failure == 'blank') return List<double>.filled(128 * 128, 0);
            return _local(nail);
          },
          onRefinement: reports.add,
        );
        expect(result.length, 1);
        expect(identical(result.single, nail), isTrue, reason: failure);
        expect(reports.single.accepted, isFalse, reason: failure);
      }
    },
  );

  test(
    'a failed nail does not suppress another nail or add predictions',
    () async {
      final first = _nail();
      final second = NailRegion(
        id: 12,
        label: 'second',
        center: first.center,
        width: first.width,
        height: first.height,
        angle: first.angle,
        maskRgba: first.maskRgba,
        maskWidth: first.maskWidth,
        maskHeight: first.maskHeight,
      );
      var calls = 0;
      final reports = <PhotoRefinementReport>[];
      final result = await refinePhotoNails(
        pngBytes: photo,
        imageWidth: 128,
        imageHeight: 128,
        nails: [first, second],
        coarseProbabilities: _coarse(first),
        engine: engine,
        predictor: (_) async {
          if (calls++ == 0) throw StateError('first crop fails');
          return _local(second);
        },
        onRefinement: reports.add,
      );
      expect(calls, 2);
      expect(result.map((n) => n.id), [first.id, second.id]);
      expect(identical(result.first, first), isTrue);
      expect(reports.map((r) => r.accepted), [false, true]);
    },
  );

  test('contour tuning never changes candidate selection or guards', () async {
    final nail = _nail();
    final summaries = <PhotoRefinementReport>[];
    for (final threshold in [.30, .32, .34, .38]) {
      final result = await refinePhotoNails(
        pngBytes: photo,
        imageWidth: 128,
        imageHeight: 128,
        nails: [nail],
        coarseProbabilities: _coarse(nail),
        engine: engine,
        predictor: (_) async => _local(nail, extendRight: 2),
        contourThreshold: threshold,
        onRefinement: summaries.add,
      );
      expect(result.single.center, nail.center);
      expect(result.single.angle, nail.angle);
      expect(_alpha(result.single, nail.center), 255);
    }
    expect(summaries.every((report) => report.accepted), isTrue);
    for (final report in summaries.skip(1)) {
      expect(report.overlap, summaries.first.overlap);
      expect(report.areaRatio, summaries.first.areaRatio);
      expect(report.centerShift, summaries.first.centerShift);
    }
  });

  test(
    'no candidates skip decoding and inference; malformed field is rejected',
    () async {
      var calls = 0;
      final result = await refinePhotoNails(
        pngBytes: Uint8List(0),
        imageWidth: 128,
        imageHeight: 128,
        nails: [],
        coarseProbabilities: List<double>.filled(16384, 0),
        engine: engine,
        predictor: (_) async {
          calls++;
          return [];
        },
      );
      expect(result, isEmpty);
      expect(calls, 0);
      await expectLater(
        refinePhotoNails(
          pngBytes: photo,
          imageWidth: 128,
          imageHeight: 128,
          nails: [_nail()],
          coarseProbabilities: [double.nan],
          engine: engine,
          predictor: (_) async => [],
        ),
        throwsArgumentError,
      );
    },
  );
}

NailRegion _nail() {
  const w = 40, h = 60;
  final rgba = Uint8List(w * h * 4);
  for (var y = 4; y < h - 4; y++) {
    for (var x = 4; x < w - 4; x++) {
      for (var c = 0; c < 4; c++) {
        rgba[(y * w + x) * 4 + c] = 255;
      }
    }
  }
  return NailRegion(
    id: 7,
    label: '原甲面',
    center: const Offset(58, 64),
    width: 40,
    height: 60,
    angle: .4,
    maskRgba: rgba,
    maskWidth: w,
    maskHeight: h,
    isManual: false,
  );
}

List<double> _coarse(NailRegion nail) => List<double>.generate(16384, (i) {
  final p = nail.toLocal(Offset(i % 128 + .5, i ~/ 128 + .5));
  return p.dx.abs() <= 16 && p.dy.abs() <= 26 ? .96 : 0;
});

List<double> _local(
  NailRegion nail, {
  double extendRight = 0,
  double shiftX = 0,
  double weakBand = 0,
}) {
  final side = (3 * math.max(nail.width, nail.height)).ceil();
  final left = (nail.center.dx - side / 2).floor();
  final top = (nail.center.dy - side / 2).floor();
  return List<double>.generate(16384, (i) {
    final point = Offset(
      left + (i % 128 + .5) * side / 128,
      top + (i ~/ 128 + .5) * side / 128,
    );
    final p = nail.toLocal(point) - Offset(shiftX, 0);
    final distanceFromEdge = math.min(
      math.min(p.dx + 16, 16 + extendRight - p.dx),
      26 - p.dy.abs(),
    );
    if (distanceFromEdge < 0) return .02;
    return distanceFromEdge < weakBand ? .58 : .96;
  });
}

double _alpha(NailRegion nail, Offset point) {
  final p = nail.toLocal(point);
  final x = ((p.dx / nail.width + .5) * nail.maskWidth).floor();
  final y = ((p.dy / nail.height + .5) * nail.maskHeight).floor();
  if (x < 0 || y < 0 || x >= nail.maskWidth || y >= nail.maskHeight) return 0;
  return nail.maskRgba[(y * nail.maskWidth + x) * 4 + 3].toDouble();
}
