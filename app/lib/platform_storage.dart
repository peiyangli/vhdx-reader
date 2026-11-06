import 'dart:io';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

/// Android SAF and iOS scoped documents stay opaque. Only a descriptor crosses Flutter;
/// image content is never copied into Dart, a platform channel, or a cache file.
class PlatformStorage {
  static const channel = MethodChannel('org.vhdxreader/storage');
  static final _names = <String, String>{};
  static bool isDocument(String path) =>
      path.startsWith('content://') || path.startsWith('vhdx-document://');
  static String displayName(String path) {
    if (_names.containsKey(path)) return _names[path]!;
    final name = path.split(RegExp(r'[/\\]')).last;
    return isDocument(path) ? Uri.decodeComponent(name) : name;
  }

  static void rememberName(String path, String name) => _names[path] = name;

  static Future<String?> bookmarkRecent(String path) async {
    if (!Platform.isIOS && !Platform.isMacOS) return null;
    return channel.invokeMethod<String>('bookmarkRecent', {'uri': path});
  }

  static Future<String> restoreRecent(String path, String? bookmark) async {
    if (!Platform.isIOS && !Platform.isMacOS) return path;
    final item = await channel.invokeMapMethod<String, dynamic>(
      'restoreRecent',
      {'uri': path, 'bookmark': ?bookmark},
    );
    final restored = item!['uri'] as String;
    rememberName(restored, item['name'] as String);
    return restored;
  }

  static Future<bool> beginPlayback() async =>
      (await channel.invokeMethod<bool>('beginPlayback'))!;
  static Future<void> endPlayback() => channel.invokeMethod('endPlayback');

  static Future<String> nativeDirectory() async =>
      (await channel.invokeMethod<String>('nativeDirectory'))!;

  static Future<List<String>> chooseImages() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return (await openFiles(
        acceptedTypeGroups: [
          const XTypeGroup(label: 'VHDX 磁盘镜像', extensions: ['vhdx']),
        ],
      )).map((file) => file.path).toList();
    }
    return _remember(await channel.invokeListMethod<dynamic>('chooseImages'));
  }

  static List<String> _remember(List<dynamic>? documents) =>
      (documents ?? []).map((dynamic item) {
        final uri = item['uri'] as String;
        _names[uri] = item['name'] as String;
        return uri;
      }).toList();
  static Future<String?> chooseCredential() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return (await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: '解锁信息', extensions: ['txt']),
        ],
      ))?.path;
    }
    final paths = _remember(
      await channel.invokeListMethod<dynamic>('chooseCredential'),
    );
    return paths.isEmpty ? null : paths.first;
  }

  static Future<String?> createExport(String name) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return (await getSaveLocation(
        suggestedName: name,
        confirmButtonText: '导出到这里',
      ))?.path;
    }
    final paths = _remember(
      await channel.invokeListMethod<dynamic>('createExport', {'name': name}),
    );
    return paths.isEmpty ? null : paths.first;
  }

  static Future<Map<String, dynamic>> open(
    String uri, {
    bool write = false,
  }) async => Map<String, dynamic>.from(
    (await channel.invokeMapMethod<String, dynamic>('openDescriptor', {
      'uri': uri,
      'write': write,
    }))!,
  );
  static Future<void> close(int handle) =>
      channel.invokeMethod('closeDescriptor', {'handle': handle});
  static Future<void> removeExport(String uri) =>
      channel.invokeMethod('removeExport', {'uri': uri});
}
