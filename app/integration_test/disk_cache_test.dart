import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/disk_cache_settings.dart';
import 'package:vhdx_reader/file_disk_cache.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/media_preview.dart';
import '../test/ui_actions.dart';
import 'media_test.dart' show waitFor;
import 'test_configuration.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real video disk cache survives reader reopen; master and clear work from settings',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'file-disk-integration-',
      );
      final directory = Directory('${temporary.path}/file-cache-v1');
      final store = CacheSettingsStore(
        directory: Directory('${temporary.path}/preferences'),
      );
      await store.save(
        const CacheSettings(
          disk: DiskCacheSettings(enabled: true, maxGiB: 128, retentionDays: 0),
        ),
      );
      int firstHits = 0;
      NativeBackend? active;
      try {
        for (var round = 0; round < 2; round++) {
          final backend = await NativeBackend.start();
          active = backend;
          await tester.pumpWidget(
            ReaderApp(
              backend: backend,
              initialImage: fixtureSetting('VHDX_MEDIA_FIXTURE'),
              cacheSettings: await store.load(),
              saveCacheSettings: store.save,
              fileDiskCache: FileDiskCache(directory: directory),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('sample.mp4'));
          await waitFor(
            tester,
            () => find.byType(MediaPreview).evaluate().isNotEmpty,
          );
          final source = tester
              .widget<MediaPreview>(find.byType(MediaPreview))
              .source;
          await source.setVolume(0);
          await waitFor(tester, () => source.position.inMilliseconds > 500);
          expect(source.error, isNull);
          final status = await backend.request({'op': 'disk_cache_status'});
          expect(status['enabled'], true);
          expect(status['limit_bytes'], 128 * 1024 * 1024 * 1024);
          expect(status['bytes'] as int, greaterThan(0));
          if (round == 0) {
            firstHits = status['hits'] as int;
          } else {
            expect(status['hits'] as int, greaterThan(firstHits));
          }
          await tester.dragFrom(
            tester.getCenter(find.byKey(const Key('media-surface'))),
            const Offset(0, 220),
          );
          await waitFor(
            tester,
            () => find.byType(MediaPreview).evaluate().isEmpty,
          );
          await source.closed;
          if (round == 1) {
            await openReaderSettings(tester);
            await ensureReaderSettingVisible(
              tester,
              find.byKey(const Key('file-cache-enabled')),
            );
            await tester.tap(find.byKey(const Key('file-cache-enabled')));
            await tester.pumpAndSettle();
            await waitFor(
              tester,
              () => !tester
                  .widget<SwitchListTile>(
                    find.byKey(const Key('file-cache-enabled')),
                  )
                  .value,
            );
            expect(
              (await backend.request({
                'op': 'disk_cache_status',
              }))['cache_enabled'],
              false,
            );
            expect((await store.load()).enabled, false);
            await ensureReaderSettingVisible(
              tester,
              find.byKey(const Key('clear-file-disk-cache')),
            );
            await tester.tap(find.byKey(const Key('clear-file-disk-cache')));
            await tester.pumpAndSettle();
            await waitFor(
              tester,
              () =>
                  find.text('文件磁盘缓存已清空。开启缓存时，后续读取会重新缓存。').evaluate().isNotEmpty,
            );
            expect(
              (await backend.request({'op': 'disk_cache_status'}))['bytes'],
              0,
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await backend.dispose();
          active = null;
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await active?.dispose();
        final cleanup = await NativeBackend.start();
        await cleanup.request({
          'op': 'disk_cache_configure',
          'directory': '${temporary.path}/unused',
          'cache_enabled': true,
          'enabled': false,
          'max_gib': 8,
          'retention_days': 7,
        });
        await cleanup.dispose();
        await temporary.delete(recursive: true);
      }
    },
  );
}
