import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'platform_storage.dart';

String imageIdentity(String path) {
  if (PlatformStorage.isDocument(path)) return path;
  final absolute = File(path).absolute.uri.normalizePath().toFilePath();
  return Platform.isWindows ? absolute.toLowerCase() : absolute;
}

class RecentImage {
  const RecentImage({
    required this.path,
    required this.name,
    required this.openedAt,
    this.bookmark,
  });
  final String path;
  final String name;
  final DateTime openedAt;
  final String? bookmark;
  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'opened_at': openedAt.toUtc().toIso8601String(),
    if (bookmark != null) 'bookmark': bookmark,
  };
}

/// Stores only successfully opened image locations, never credentials or content.
class RecentImagesStore extends ChangeNotifier {
  RecentImagesStore({this.directory, this.limit = 20}) : persistent = true;
  RecentImagesStore.memory({this.limit = 20})
    : directory = null,
      persistent = false;
  final Directory? directory;
  final bool persistent;
  final int limit;
  final _items = <RecentImage>[];
  List<RecentImage> get items => List.unmodifiable(_items);
  Future<void> _writes = Future.value();
  Future<File> _file() async => File(
    '${(directory ?? await getApplicationSupportDirectory()).path}/recent-images.json',
  );

  Future<void> load() async {
    if (!persistent) return;
    try {
      final file = await _file();
      if (!await file.exists() || await file.length() > 2 * 1024 * 1024) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['version'] != 1 || data['images'] is! List) {
        return;
      }
      final loaded = <RecentImage>[];
      final seen = <String>{};
      for (final value in data['images'] as List) {
        if (value is! Map) continue;
        final path = value['path'],
            name = value['name'],
            at = value['opened_at'],
            bookmark = value['bookmark'];
        if (path is! String ||
            path.isEmpty ||
            path.length > 32768 ||
            path.contains('\x00') ||
            name is! String ||
            name.isEmpty ||
            name.length > 4096 ||
            at is! String) {
          continue;
        }
        final date = DateTime.tryParse(at);
        if (date == null || !seen.add(imageIdentity(path))) continue;
        loaded.add(
          RecentImage(
            path: path,
            name: name,
            openedAt: date,
            bookmark: bookmark is String && bookmark.length <= 65536
                ? bookmark
                : null,
          ),
        );
        if (loaded.length == limit) break;
      }
      _items
        ..clear()
        ..addAll(loaded);
      for (final item in loaded) {
        PlatformStorage.rememberName(item.path, item.name);
      }
      notifyListeners();
    } catch (_) {
      /* A missing/corrupt history never prevents opening an image. */
    }
  }

  Future<void> record(String path, String name) {
    final identity = imageIdentity(path);
    final previous = _items
        .where((item) => imageIdentity(item.path) == identity)
        .firstOrNull;
    _items.removeWhere((item) => imageIdentity(item.path) == identity);
    _items.insert(
      0,
      RecentImage(
        path: path,
        name: name,
        openedAt: DateTime.now(),
        bookmark: previous?.bookmark,
      ),
    );
    if (_items.length > limit) _items.removeRange(limit, _items.length);
    return _changed();
  }

  Future<void> attachBookmark(String path, String bookmark) {
    final index = _items.indexWhere(
      (item) => imageIdentity(item.path) == imageIdentity(path),
    );
    // A late platform response must not resurrect a removed/cleared entry.
    if (index < 0) return Future.value();
    final old = _items[index];
    _items[index] = RecentImage(
      path: old.path,
      name: old.name,
      openedAt: old.openedAt,
      bookmark: bookmark,
    );
    return _changed();
  }

  Future<void> remove(String path) {
    _items.removeWhere(
      (item) => imageIdentity(item.path) == imageIdentity(path),
    );
    return _changed();
  }

  Future<void> clear() {
    _items.clear();
    return _changed();
  }

  Future<void> _changed() {
    notifyListeners();
    if (!persistent) return Future.value();
    final text = jsonEncode({
      'version': 1,
      'images': _items.map((e) => e.toJson()).toList(),
    });
    final write = _writes.then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.$pid.tmp');
      try {
        await temporary.writeAsString(text, flush: true);
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}
