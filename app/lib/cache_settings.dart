import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class CacheSettings {
  const CacheSettings({this.plaintextMiB = 16, this.ciphertextMiB = 1});
  static const plaintextOptions = [16, 32, 64, 128, 256];
  static const ciphertextOptions = [1, 2, 4, 8, 16];
  final int plaintextMiB;
  final int ciphertextMiB;
  bool get valid =>
      plaintextOptions.contains(plaintextMiB) &&
      ciphertextOptions.contains(ciphertextMiB);

  Map<String, int> toJson() => {
    'plaintext_mib': plaintextMiB,
    'ciphertext_mib': ciphertextMiB,
  };

  factory CacheSettings.fromJson(dynamic value) {
    if (value is! Map) return const CacheSettings();
    return CacheSettings(
      plaintextMiB:
          value['plaintext_mib'] is int &&
              plaintextOptions.contains(value['plaintext_mib'])
          ? value['plaintext_mib'] as int
          : 16,
      ciphertextMiB:
          value['ciphertext_mib'] is int &&
              ciphertextOptions.contains(value['ciphertext_mib'])
          ? value['ciphertext_mib'] as int
          : 1,
    );
  }
}

/// Only numeric preferences are persisted, never image contents or credentials.
class CacheSettingsStore {
  const CacheSettingsStore({this.directory});
  final Directory? directory;
  Future<File> _file() async {
    final root = directory ?? await getApplicationSupportDirectory();
    return File(
      '${root.path}${Platform.pathSeparator}read-cache-settings.json',
    );
  }

  Future<CacheSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists() || await file.length() > 4096) {
        return const CacheSettings();
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['version'] != 1) return const CacheSettings();
      return CacheSettings.fromJson(data['cache']);
    } on FileSystemException {
      return const CacheSettings();
    } on FormatException {
      return const CacheSettings();
    } on MissingPluginException {
      return const CacheSettings();
    } on PlatformException {
      return const CacheSettings();
    } on MissingPlatformDirectoryException {
      return const CacheSettings();
    }
  }

  Future<void> save(CacheSettings value) async {
    if (!value.valid) throw ArgumentError('Unsupported cache size');
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File(
      '${file.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        jsonEncode({'version': 1, 'cache': value.toJson()}),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
