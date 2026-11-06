import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class CacheSettings {
  const CacheSettings({
    this.plaintextMiB = 16,
    this.ciphertextMiB = 1,
    this.thumbnailDisk = true,
    this.bitLockerThumbnailDisk = false,
  });
  final bool thumbnailDisk;
  final bool bitLockerThumbnailDisk;
  CacheSettings copyWith({
    int? plaintextMiB,
    int? ciphertextMiB,
    bool? thumbnailDisk,
    bool? bitLockerThumbnailDisk,
  }) => CacheSettings(
    plaintextMiB: plaintextMiB ?? this.plaintextMiB,
    ciphertextMiB: ciphertextMiB ?? this.ciphertextMiB,
    thumbnailDisk: thumbnailDisk ?? this.thumbnailDisk,
    bitLockerThumbnailDisk:
        bitLockerThumbnailDisk ?? this.bitLockerThumbnailDisk,
  );
  static const plaintextOptions = [16, 32, 64, 128, 256];
  static const ciphertextOptions = [1, 2, 4, 8, 16];
  final int plaintextMiB;
  final int ciphertextMiB;
  bool get valid =>
      plaintextOptions.contains(plaintextMiB) &&
      ciphertextOptions.contains(ciphertextMiB);

  Map<String, dynamic> toJson() => {
    'plaintext_mib': plaintextMiB,
    'ciphertext_mib': ciphertextMiB,
  };

  factory CacheSettings.fromJson(dynamic value) {
    if (value is! Map) return const CacheSettings();
    return CacheSettings(
      thumbnailDisk: value['thumbnail_disk'] != false,
      bitLockerThumbnailDisk: value['bitlocker_thumbnail_disk'] == true,
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

/// Only preferences are persisted here, never image contents or credentials.
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
        jsonEncode({
          'version': 1,
          'cache': {
            ...value.toJson(),
            'thumbnail_disk': value.thumbnailDisk,
            'bitlocker_thumbnail_disk': value.bitLockerThumbnailDisk,
          },
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
