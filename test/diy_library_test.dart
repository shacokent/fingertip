import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offline_nail_demo/models/diy_models.dart';
import 'package:offline_nail_demo/models/diy_stickers.dart';
import 'package:offline_nail_demo/services/diy_library.dart';
import 'package:offline_nail_demo/services/diy_renderer.dart';

void main() {
  test(
    'material library has varied editable motifs and normalized serialization',
    () {
      expect(DiySticker.all, hasLength(82));
      final previous = DiySticker.all.take(72);
      expect(
        previous.every((s) => s.id == '${s.motif.name}_${s.variant}'),
        isTrue,
      );
      final seasonal = DiySticker.all.skip(72);
      expect(seasonal.map((s) => s.motif).toSet(), hasLength(10));
      expect(seasonal.map((s) => s.category).toSet(), {
        '花卉枝叶',
        '星月闪光',
        '纹理叠层',
        '海洋甜趣',
      });
      expect(DiySticker.byId('ice_lattice')!.motif, DiyMotif.iceLattice);
      expect(
        DiySticker.all.map((s) => s.id).toSet().length,
        DiySticker.all.length,
      );
      expect(DiySticker.all.map((s) => s.motif).toSet().length, 46);
      expect(DiySticker.categories.length, 6);
      const layer = DiyLayer(
        id: 'test',
        kind: DiyLayerKind.image,
        imagePath: 'images/test.png',
        locked: true,
        scale: 1.8,
        rotation: .3,
      );
      final design = DiyNailDesign(layers: [layer]);
      final restored = DiyNailDesign.fromJson(
        jsonDecode(jsonEncode(design.toJson())) as Map<String, dynamic>,
        directory: '/app/revision',
      );
      expect(restored.layers.single.imagePath, '/app/revision/images/test.png');
      expect(restored.layers.single.locked, isTrue);
      expect(restored.layers.single.scale, 1.8);
      expect(
        () => DiyLayer.fromJson({'id': 'broken', 'kind': 'unknown'}),
        throwsFormatException,
      );
    },
  );

  testWidgets(
    'import save revise relocate and delete never change the source image',
    (tester) async {
      await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp('diy-library-');
        try {
          final original = File('${root.path}/original.png');
          await original.writeAsBytes(await _solidPng(const Color(0xFF327FA5)));
          final originalBytes = await original.readAsBytes();
          final directory = Directory('${root.path}/library');
          final library = DiyLibrary(directory: directory);
          final imported = await library.importImage(
            original.path,
            draftId: 'test_draft',
          );
          expect(imported, isNot(original.path));
          final saved = await library.save(
            DiyNailDesign(
              name: '测试蓝蝶',
              baseColor: const Color(0xFFFFE6CC),
              layers: [
                DiyLayer(
                  id: 'image',
                  kind: DiyLayerKind.image,
                  imagePath: imported,
                  width: .4,
                  height: .4,
                ),
                const DiyLayer(
                  id: 'butterfly',
                  kind: DiyLayerKind.sticker,
                  stickerId: 'butterfly_0',
                ),
                const DiyLayer(
                  id: 'ice',
                  kind: DiyLayerKind.sticker,
                  stickerId: 'ice_lattice',
                  x: .72,
                  y: .29,
                  width: .20,
                  height: .20,
                ),
              ],
            ),
          );
          expect(saved.style.isCustom, isTrue);
          expect(await File(saved.style.texturePath!).exists(), isTrue);
          final image = await decodeDiyImage(saved.style.texturePath!);
          final rgba = (await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          ))!.buffer.asUint8List();
          // The rectangular export keeps the full base to avoid clipping twice.
          expect(rgba.sublist(0, 4), [255, 230, 204, 255]);
          image.dispose();
          await library.discardDraft('test_draft');
          expect(await File(imported).exists(), isFalse);
          expect(
            await File(saved.design.layers.first.imagePath!).exists(),
            isTrue,
          );
          final revised = await library.save(
            saved.design.copyWith(name: '修改后的蓝蝶'),
            existingId: saved.id,
          );
          expect(revised.id, saved.id);
          expect(revised.style.texturePath, isNot(saved.style.texturePath));
          expect(await File(saved.style.texturePath!).exists(), isTrue);
          expect((await library.load()).single.name, '修改后的蓝蝶');

          final moved = await directory.rename('${root.path}/moved-container');
          final relocatedLibrary = DiyLibrary(directory: moved);
          final reloaded = (await relocatedLibrary.load()).single;
          expect(reloaded.style.texturePath, startsWith(moved.path));
          expect(
            reloaded.design.layers
                .where((layer) => layer.kind == DiyLayerKind.sticker)
                .map((layer) => layer.stickerId),
            orderedEquals(['butterfly_0', 'ice_lattice']),
          );
          expect(
            await File(reloaded.design.layers.first.imagePath!).exists(),
            isTrue,
          );
          final document = await File(
            '${File(reloaded.style.texturePath!).parent.path}/design.json',
          ).readAsString();
          expect(document, isNot(contains(directory.path)));

          await expectLater(
            relocatedLibrary.delete('../original.png'),
            throwsArgumentError,
          );
          await expectLater(
            relocatedLibrary.delete('rose'),
            throwsArgumentError,
          );
          await relocatedLibrary.delete(reloaded.id);
          expect(await relocatedLibrary.load(), isEmpty);
          expect(await original.readAsBytes(), orderedEquals(originalBytes));
        } finally {
          await root.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('failed image save preserves the current saved revision', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('diy-failure-');
      try {
        final library = DiyLibrary(directory: root);
        final saved = await library.save(const DiyNailDesign(name: '原有款式'));
        await expectLater(
          library.save(
            saved.design.copyWith(
              layers: [
                const DiyLayer(
                  id: 'missing',
                  kind: DiyLayerKind.image,
                  imagePath: '/missing/not-an-image.png',
                ),
              ],
            ),
            existingId: saved.id,
          ),
          throwsA(isA<FileSystemException>()),
        );
        final loaded = (await library.load()).single;
        expect(loaded.name, '原有款式');
        expect(loaded.style.texturePath, saved.style.texturePath);
        expect(await File(loaded.style.texturePath!).exists(), isTrue);
        final good = await library.save(const DiyNailDesign(name: '仍可读取的款式'));
        final document = File(
          '${File(loaded.style.texturePath!).parent.path}/design.json',
        );
        await document.writeAsString(
          jsonEncode({
            'layers': [
              {'id': 'broken', 'kind': 'unknown'},
            ],
          }),
        );
        final index = File('${root.path}/index.json');
        final entries = jsonDecode(await index.readAsString()) as List;
        await index.writeAsString(jsonEncode([...entries, 42]));
        expect((await library.load()).single.id, good.id);
      } finally {
        await root.delete(recursive: true);
      }
    });
  });

  testWidgets(
    'drawing eraser removes ink but keeps the base and other artwork',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = await rasterizeDiyDesign(
          const DiyNailDesign(
            baseColor: Color(0xFFFFFFFF),
            layers: [
              DiyLayer(
                id: 'pen',
                kind: DiyLayerKind.stroke,
                width: 1,
                height: 1,
                color: Color(0xFFCC2244),
                strokeWidth: .09,
                points: [Offset(.15, .5), Offset(.85, .5)],
              ),
              DiyLayer(
                id: 'eraser',
                kind: DiyLayerKind.stroke,
                width: 1,
                height: 1,
                erase: true,
                strokeWidth: .18,
                points: [Offset(.5, .5)],
              ),
            ],
          ),
        );
        final codec = await ui.instantiateImageCodec(bytes);
        final image = (await codec.getNextFrame()).image;
        final rgba = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final middle = (384 * 512 + 256) * 4;
        expect(rgba.sublist(middle, middle + 4), [255, 255, 255, 255]);
        final pen = (384 * 512 + 110) * 4;
        expect(rgba[pen + 1], lessThan(80));
        image.dispose();
        codec.dispose();
        final transparentBytes = await rasterizeDiyDesign(
          const DiyNailDesign(
            baseColor: Color(0xFFFFFFFF),
            layers: [
              DiyLayer(
                id: 'transparent',
                kind: DiyLayerKind.stroke,
                width: 1,
                height: 1,
                color: Color(0x00CC2244),
                strokeWidth: .2,
                points: [Offset(.2, .5), Offset(.8, .5)],
              ),
            ],
          ),
        );
        final transparentCodec = await ui.instantiateImageCodec(
          transparentBytes,
        );
        final transparentImage = (await transparentCodec.getNextFrame()).image;
        final transparentRgba = (await transparentImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        expect(transparentRgba.sublist(middle, middle + 4), [
          255,
          255,
          255,
          255,
        ]);
        transparentImage.dispose();
        transparentCodec.dispose();
      });
    },
  );
}

Future<Uint8List> _solidPng(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 48);
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}
