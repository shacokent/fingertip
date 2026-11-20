import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

import '../models/diy_models.dart';
import '../models/nail_models.dart';
import 'diy_renderer.dart';

/// User-created styles live inside the app. Imported originals are never
/// modified or removed. Each save has a distinct render path for texture caches.
class DiyLibrary {
  // Keep a public testable directory override while the stored field is private.
  // ignore: prefer_initializing_formals
  DiyLibrary({Directory? directory}) : _directory = directory;
  final Directory? _directory;
  Future<void> _pending = Future.value();

  Future<Directory> get directory async {
    final root =
        _directory ??
        Directory(
          '${(await getApplicationDocumentsDirectory()).path}/DiyNails',
        );
    await root.create(recursive: true);
    return root;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final task = _pending.then((_) => operation());
    _pending = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }

  String _unique(String prefix) =>
      '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(0xFFFFFF)}';
  bool _validId(String id) => RegExp(r'^custom_[0-9]+_[0-9]+$').hasMatch(id);
  bool _validDraft(String id) => RegExp(r'^[A-Za-z0-9_]+$').hasMatch(id);

  Future<List<Map<String, dynamic>>> _index(Directory root) async {
    final file = File('${root.path}/index.json');
    if (!await file.exists()) return [];
    final value = jsonDecode(await file.readAsString());
    if (value is! List) throw const FormatException('DIY 款式目录损坏。');
    return [
      for (final entry in value)
        if (entry is Map) Map<String, dynamic>.from(entry),
    ];
  }

  Future<void> _writeIndex(
    Directory root,
    List<Map<String, dynamic>> index,
  ) async {
    final temporary = File('${root.path}/index_${_unique('tmp')}.json');
    await temporary.writeAsString(jsonEncode(index), flush: true);
    await temporary.rename('${root.path}/index.json');
  }

  Future<List<DiySavedStyle>> load() async {
    final root = await directory;
    final records = await _index(root);
    final result = <DiySavedStyle>[];
    for (final record in records) {
      try {
        final id = record['id'] as String,
            revision = record['revision'] as String;
        if (!_validId(id) ||
            !RegExp(r'^rev_[0-9]+_[0-9]+$').hasMatch(revision)) {
          continue;
        }
        final folder = Directory('${root.path}/styles/$id/$revision');
        final raw = Map<String, dynamic>.from(
          jsonDecode(await File('${folder.path}/design.json').readAsString())
              as Map,
        );
        final design = DiyNailDesign.fromJson(raw, directory: folder.path);
        final preview = File('${folder.path}/preview.png');
        if (!await preview.exists()) continue;
        result.add(
          _entry(
            id,
            design,
            preview.path,
            DateTime.parse(record['updatedAt'] as String),
          ),
        );
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      } on TypeError {
        continue;
      }
    }
    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return List.unmodifiable(result);
  }

  DiySavedStyle _entry(
    String id,
    DiyNailDesign design,
    String texturePath,
    DateTime updatedAt,
  ) => DiySavedStyle(
    id: id,
    design: design,
    updatedAt: updatedAt,
    style: NailStyle(
      id,
      design.name,
      '我的 DIY',
      design.baseColor,
      NailPattern.solid,
      texturePath: texturePath,
      coverage: 1,
    ),
  );

  Future<DiySavedStyle> save(
    DiyNailDesign design, {
    String? existingId,
  }) => _serialize(() async {
    if (existingId != null && !_validId(existingId)) {
      throw ArgumentError('无效的自建款式。');
    }
    if (design.layers.length > 80) {
      throw const FormatException('图层较多，请合并或删除一些素材后再保存。');
    }
    final root = await directory;
    final index = await _index(root);
    final id = existingId ?? _unique('custom');
    final revision = _unique('rev');
    final styleDirectory = Directory('${root.path}/styles/$id');
    await styleDirectory.create(recursive: true);
    final staging = Directory('${styleDirectory.path}/.${revision}_pending');
    await staging.create(recursive: true);
    try {
      final images = Directory('${staging.path}/images');
      await images.create();
      final copied = <String, String>{};
      final copiedLayers = <DiyLayer>[];
      for (final layer in design.layers) {
        final path = layer.imagePath;
        if (layer.kind == DiyLayerKind.image && path != null) {
          var destination = copied[path];
          if (destination == null) {
            destination = 'images/image_${copied.length}.png';
            await File(path).copy('${staging.path}/$destination');
            copied[path] = destination;
          }
          copiedLayers.add(layer.copyWith(imagePath: destination));
        } else {
          copiedLayers.add(layer);
        }
      }
      final requestedName = design.name.trim();
      final cleanName = requestedName.isEmpty
          ? '我的美甲'
          : String.fromCharCodes(requestedName.runes.take(30));
      final persisted = design.copyWith(name: cleanName, layers: copiedLayers);
      await File(
        '${staging.path}/design.json',
      ).writeAsString(jsonEncode(persisted.toJson()), flush: true);
      final renderDesign = DiyNailDesign.fromJson(
        persisted.toJson(),
        directory: staging.path,
      );
      await File(
        '${staging.path}/preview.png',
      ).writeAsBytes(await rasterizeDiyDesign(renderDesign), flush: true);
      final committed = await staging.rename(
        '${styleDirectory.path}/$revision',
      );
      final now = DateTime.now();
      final next = [
        for (final record in index)
          if (record['id'] != id) record,
        <String, dynamic>{
          'id': id,
          'revision': revision,
          'updatedAt': now.toIso8601String(),
        },
      ];
      await _writeIndex(root, next);
      return _entry(
        id,
        DiyNailDesign.fromJson(persisted.toJson(), directory: committed.path),
        '${committed.path}/preview.png',
        now,
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  });

  Future<void> delete(String id) => _serialize(() async {
    if (!_validId(id)) throw ArgumentError('仅可删除自建款式。');
    final root = await directory;
    final records = await _index(root);
    await _writeIndex(root, [
      for (final record in records)
        if (record['id'] != id) record,
    ]);
    final owned = Directory('${root.path}/styles/$id');
    if (await owned.exists()) await owned.delete(recursive: true);
  });

  Future<String> importImage(
    String sourcePath, {
    required String draftId,
  }) async {
    if (!_validDraft(draftId)) throw ArgumentError('无效的草稿。');
    final root = await directory;
    final draft = Directory('${root.path}/drafts/$draftId');
    await draft.create(recursive: true);
    final image = await decodeDiyImage(sourcePath);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('无法读取这张图片。');
      final file = File('${draft.path}/${_unique('image')}.png');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return file.path;
    } finally {
      image.dispose();
    }
  }

  Future<void> discardDraft(String draftId) async {
    if (!_validDraft(draftId)) return;
    final folder = Directory('${(await directory).path}/drafts/$draftId');
    if (await folder.exists()) await folder.delete(recursive: true);
  }
}
