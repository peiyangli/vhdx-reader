import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'file_browser.dart';

/// Application-wide browsing preferences, independent of image/unlock state.
class BrowserSettings {
  const BrowserSettings({
    this.grid = false,
    this.seekSeconds = 5,
    this.sort = FileSort.name,
    this.descending = false,
    this.showSystem = false,
  });
  static const seekOptions = [3, 5, 10, 15, 30];
  final int seekSeconds;
  final bool grid;
  final FileSort sort;
  final bool descending;
  final bool showSystem;

  BrowserSettings copyWith({
    bool? grid,
    int? seekSeconds,
    FileSort? sort,
    bool? descending,
    bool? showSystem,
  }) => BrowserSettings(
    grid: grid ?? this.grid,
    seekSeconds: seekSeconds ?? this.seekSeconds,
    sort: sort ?? this.sort,
    descending: descending ?? this.descending,
    showSystem: showSystem ?? this.showSystem,
  );

  Map<String, dynamic> toJson() => {
    'grid': grid,
    'seek_seconds': seekSeconds,
    'sort': sort.name,
    'descending': descending,
    'show_system': showSystem,
  };

  factory BrowserSettings.fromJson(dynamic value) {
    if (value is! Map) return const BrowserSettings();
    return BrowserSettings(
      grid: value['grid'] == true,
      seekSeconds:
          value['seek_seconds'] is int &&
              seekOptions.contains(value['seek_seconds'])
          ? value['seek_seconds'] as int
          : 5,
      sort: FileSort.values.firstWhere(
        (sort) => sort.name == value['sort'],
        orElse: () => FileSort.name,
      ),
      descending: value['descending'] == true,
      showSystem: value['show_system'] == true,
    );
  }
}

class BrowserSettingsStore {
  BrowserSettingsStore({this.directory});
  final Directory? directory;
  Future<void> _writes = Future.value();
  Future<File> _file() async => File(
    '${(directory ?? await getApplicationSupportDirectory()).path}/browser-settings.json',
  );

  Future<BrowserSettings> load() async {
    await _writes;
    try {
      final file = await _file();
      if (!await file.exists() || await file.length() > 4096) {
        return const BrowserSettings();
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['version'] != 1) return const BrowserSettings();
      return BrowserSettings.fromJson(data['browser']);
    } on FileSystemException {
      return const BrowserSettings();
    } on FormatException {
      return const BrowserSettings();
    } on MissingPluginException {
      return const BrowserSettings();
    } on PlatformException {
      return const BrowserSettings();
    } on MissingPlatformDirectoryException {
      return const BrowserSettings();
    }
  }

  Future<void> save(BrowserSettings value) {
    // Serialize atomic replacements: rapid choices must never let an earlier
    // write finish last or leave a partially written settings file.
    final write = _writes.then((_) async {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.$pid.tmp');
      try {
        await temporary.writeAsString(
          jsonEncode({'version': 1, 'browser': value.toJson()}),
          flush: true,
        );
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    });
    _writes = write.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return write;
  }
}
