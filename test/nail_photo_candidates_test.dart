import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:offline_nail_demo/models/nail_models.dart';
import 'package:offline_nail_demo/services/nail_photo_candidates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'photo views need corroboration and do not duplicate a known nail',
    () async {
      final photo = img.encodePng(img.Image(width: 200, height: 200));
      const side = 128;
      final blank = List<double>.filled(side * side, 0);
      final candidate = List<double>.of(blank);
      for (var y = 43; y < 63; y++) {
        for (var x = 44; x < 60; x++) {
          candidate[y * side + x] = .95;
        }
      }

      Future<List<NailRegion>> run({
        required int supportingViews,
        List<NailRegion> known = const [],
      }) async {
        var calls = 0;
        final regions = await recoverNailsFromPhotoViews(
          pngBytes: Uint8List.fromList(photo),
          imageWidth: 200,
          imageHeight: 200,
          nails: known,
          hands: const [],
          predictView: (_, _) async =>
              calls++ < supportingViews ? candidate : blank,
        );
        expect(calls, 12);
        return regions;
      }

      expect(await run(supportingViews: 1), isEmpty);
      final recovered = (await run(supportingViews: 2)).single;
      expect(recovered.center.dx, closeTo(49, 1));
      expect(recovered.center.dy, closeTo(50, 1));
      expect(recovered.isManual, isFalse);
      final known = NailRegion.manual(7, recovered.center, 200);
      final retained = (await run(supportingViews: 2, known: [known])).single;
      expect(retained.id, known.id);
      expect(retained.label, known.label);
      expect(retained.center, known.center);
      expect(retained.width, known.width);
      expect(retained.height, known.height);
      expect(retained.maskRgba, known.maskRgba);
    },
  );
}
