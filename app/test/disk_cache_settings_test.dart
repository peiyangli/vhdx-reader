import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/disk_cache_settings.dart';
import 'package:vhdx_reader/file_disk_cache.dart';
import 'package:vhdx_reader/main.dart';
import 'cache_settings_test.dart' show CacheBackend;
import 'ui_actions.dart';

class DiskBackend extends CacheBackend {
  DiskBackend() : super(plain: true);
  final diskRequests = <Map<String, dynamic>>[];
  bool failClear = false;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
    if ((value['op'] as String).startsWith('disk_cache_')) {
      diskRequests.add(Map.of(value));
      if (value['op'] == 'disk_cache_clear' && failClear) {
        throw ReaderFailure('cache', 'test deletion failure');
      }
      return {'bytes': 0, 'removed_bytes': 0};
    }
    return super.request(value);
  }
}

void main() {
  test(
    'master and disk preferences persist independently, including 128 GiB and permanent retention',
    () async {
      final root = await Directory.systemTemp.createTemp('disk-preferences-');
      addTearDown(() => root.delete(recursive: true));
      final store = CacheSettingsStore(directory: root);
      const settings = CacheSettings(
        enabled: false,
        plaintextMiB: 256,
        disk: DiskCacheSettings(enabled: true, maxGiB: 128, retentionDays: 0),
      );
      await store.save(settings);
      var loaded = await CacheSettingsStore(directory: root).load();
      expect(loaded.enabled, false);
      expect(loaded.disk.toJson(), settings.disk.toJson());
      expect(loaded.plaintextMiB, 256);
      await store.save(loaded.copyWith(plaintextPageKiB: 1024));
      loaded = await store.load();
      expect(loaded.disk.maxGiB, 128);
      expect(loaded.disk.retentionDays, 0);
      expect(CacheSettings.fromJson({}).enabled, true);
      expect(CacheSettings.fromJson({}).disk.enabled, false);
      for (final invalid in [null, '128', 128.0, -1, 256]) {
        expect(DiskCacheSettings.fromJson({'max_gib': invalid}).maxGiB, 8);
      }
      await expectLater(
        store.save(
          settings.copyWith(disk: const DiskCacheSettings(maxGiB: 256)),
        ),
        throwsArgumentError,
      );
      await expectLater(
        store.save(
          settings.copyWith(disk: const DiskCacheSettings(retentionDays: 2)),
        ),
        throwsArgumentError,
      );
      expect((await store.load()).disk.maxGiB, 128);
    },
  );

  testWidgets(
    'disk controls apply live, persist permanent policy, rollback and report cleanup failures',
    (tester) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final root = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('disk-settings-ui-'),
      ))!;
      addTearDown(() => root.delete(recursive: true));
      final backend = DiskBackend();
      var saved = const CacheSettings();
      var failSave = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'test.vhdx',
          platform: TargetPlatform.android,
          fileDiskCache: FileDiskCache(directory: root),
          saveCacheSettings: (value) async {
            if (failSave) throw const FileSystemException('test save failure');
            saved = value;
          },
        ),
      );
      await tester.pumpAndSettle();
      await openReaderSettings(tester);
      Future<void> item(String key) async {
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byKey(const Key('reader-settings-page')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        scrollable.position.jumpTo(0);
        await tester.pumpAndSettle();
        await ensureReaderSettingVisible(tester, find.byKey(Key(key)));
        await tester.tap(find.byKey(Key(key)));
        await tester.pumpAndSettle();
      }

      Future<void> choose(String name, int value) async {
        await item('file-disk-$name');
        final option = find.byKey(Key('file-disk-$name-$value'));
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
      }

      await item('file-disk-enabled');
      expect(saved.disk.enabled, true);
      await choose('capacity', 128);
      await choose('retention', 0);
      expect(saved.disk.maxGiB, 128);
      expect(saved.disk.retentionDays, 0);
      expect(find.text('永久（不按时间清理）'), findsOneWidget);
      await item('file-cache-enabled');
      expect(saved.enabled, false);
      expect(backend.diskRequests.last['cache_enabled'], false);
      expect(backend.diskRequests.last['enabled'], true);
      expect(backend.caches.length, 1);
      failSave = true;
      await choose('capacity', 64);
      expect(saved.disk.maxGiB, 128);
      expect(backend.diskRequests.last['max_gib'], 128);
      expect(find.text('无法保存缓存设置，请重试。'), findsOneWidget);
      failSave = false;
      backend.failClear = true;
      await item('clear-file-disk-cache');
      expect(find.text('无法完全清空文件磁盘缓存，请重试。'), findsOneWidget);
      backend.failClear = false;
      await item('clear-file-disk-cache');
      expect(find.text('文件磁盘缓存已清空。开启缓存时，后续读取会重新缓存。'), findsOneWidget);
      expect(backend.diskRequests.last['op'], 'disk_cache_clear');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
