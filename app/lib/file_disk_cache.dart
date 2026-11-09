import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'backend.dart';
import 'disk_cache_settings.dart';

/// Native worker serializes cache administration with reads across all images.
class FileDiskCache {
  const FileDiskCache({this.directory});
  final Directory? directory;
  Future<Map<String, dynamic>> configure(
    ReaderBackend backend,
    DiskCacheSettings settings, {
    bool cacheEnabled = true,
  }) async {
    if (!settings.valid) throw ArgumentError('Unsupported disk cache settings');
    Directory root;
    try {
      root =
          directory ??
          Directory(
            '${(await getApplicationCacheDirectory()).path}/file-cache-v1',
          );
    } on MissingPluginException {
      // Widget-only environments have no platform cache directory or native I/O.
      if (!settings.enabled) return {'enabled': false, 'bytes': 0};
      rethrow;
    }
    return backend.request({
      'op': 'disk_cache_configure',
      'cache_enabled': cacheEnabled,
      'directory': root.absolute.path,
      ...settings.toJson(),
    });
  }

  Future<void> clear(
    ReaderBackend backend,
    DiskCacheSettings settings, {
    bool cacheEnabled = true,
  }) async {
    await configure(backend, settings, cacheEnabled: cacheEnabled);
    await backend.request({'op': 'disk_cache_clear'});
  }
}
