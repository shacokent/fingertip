import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Stores only style identifiers in the app's local documents directory.
class NailFavorites {
  NailFavorites({File? file}) : _fileOverride = file;

  static final local = NailFavorites();

  final File? _fileOverride;
  Future<void> _pending = Future.value();

  Future<File> _file() async =>
      _fileOverride ??
      File(
        '${(await getApplicationDocumentsDirectory()).path}/nail_favorites.json',
      );

  Future<Set<String>> _read(File file) async {
    if (!await file.exists()) return {};
    final value = jsonDecode(await file.readAsString());
    if (value is! List || value.any((id) => id is! String)) {
      throw const FormatException('收藏文件格式无效。');
    }
    return value.cast<String>().toSet();
  }

  Future<Set<String>> load() async {
    await _pending;
    return _read(await _file());
  }

  Future<Set<String>> setFavorite(String id, bool favorite) {
    final task = _pending.then((_) async {
      final file = await _file();
      final ids = await _read(file);
      final changed = favorite ? ids.add(id) : ids.remove(id);
      if (!changed) return ids;

      await file.parent.create(recursive: true);
      final temporary = await file.parent.createTemp('.nail-favorites-');
      try {
        final staged = File('${temporary.path}/favorites.json');
        await staged.writeAsString(jsonEncode(ids.toList()), flush: true);
        await staged.rename(file.path);
      } finally {
        // A stale staging directory must not turn a committed write into a
        // failed operation.
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          // A future launch can still read the committed file.
        }
      }
      return ids;
    });
    _pending = task.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return task;
  }
}
