import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/playback_buffer_settings.dart';
import 'cache_settings_test.dart' show CacheBackend;
import 'ui_actions.dart';

void main() {
  test(
    'playback preferences persist independently; invalid and legacy data recover',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'playback-preferences-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = CacheSettingsStore(directory: directory);
      const settings = CacheSettings(
        plaintextMiB: 256,
        ciphertextMiB: 4,
        playback: PlaybackBufferSettings(
          forwardMiB: 128,
          readAheadSeconds: 60,
          resumeSeconds: 5,
        ),
      );
      await store.save(settings);
      final restored = await CacheSettingsStore(directory: directory).load();
      expect(restored.playback.toJson(), settings.playback.toJson());
      expect(restored.toJson(), {
        'plaintext_mib': 256,
        'plaintext_page_kib': 64,
        'ciphertext_mib': 4,
      });
      await store.save(
        restored.copyWith(thumbnailDisk: false, plaintextMiB: 64),
      );
      expect(
        (await store.load()).playback.toJson(),
        settings.playback.toJson(),
      );
      expect((await store.load()).thumbnailDisk, false);
      for (final invalid in [
        const PlaybackBufferSettings(forwardMiB: 1024),
        const PlaybackBufferSettings(readAheadSeconds: -1),
        const PlaybackBufferSettings(resumeSeconds: 0),
      ]) {
        await expectLater(
          store.save(settings.copyWith(playback: invalid)),
          throwsArgumentError,
        );
        expect(
          (await store.load()).playback.toJson(),
          settings.playback.toJson(),
        );
      }
      final file = File('${directory.path}/read-cache-settings.json');
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'cache': {
            'plaintext_mib': 256,
            'plaintext_page_kib': 64,
            'ciphertext_mib': 8,
          },
        }),
      );
      expect(
        (await store.load()).playback.toJson(),
        const PlaybackBufferSettings().toJson(),
      );
      expect((await store.load()).plaintextMiB, 256);
      for (final invalid in [null, '64', 64.0, -1, 999]) {
        expect(
          PlaybackBufferSettings.fromJson({
            'forward_mib': invalid,
            'read_ahead_seconds': invalid,
            'resume_seconds': invalid,
          }).toJson(),
          const PlaybackBufferSettings().toJson(),
        );
      }
      await file.writeAsString('{broken');
      expect(
        (await store.load()).playback.toJson(),
        const PlaybackBufferSettings().toJson(),
      );
    },
  );

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets(
      '$platform edits all playback options, preserves volumes and handles save failure',
      (tester) async {
        tester.view.physicalSize = const Size(800, 360);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var saved = const CacheSettings(plaintextMiB: 256);
        var failSave = false;
        final backend = CacheBackend(plain: true);
        await tester.pumpWidget(
          ReaderApp(
            backend: backend,
            initialImage: 'playback.vhdx',
            platform: platform,
            cacheSettings: saved,
            saveCacheSettings: (value) async {
              if (failSave) throw const FileSystemException('test failure');
              saved = value;
            },
          ),
        );
        await tester.pumpAndSettle();
        await openReaderSettings(tester);
        Future<void> choose(String name, int value) async {
          final item = find.byKey(Key('playback-$name'));
          // Return to the top so options earlier in the list can be located too.
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
          await ensureReaderSettingVisible(tester, item);
          await tester.tap(item);
          await tester.pumpAndSettle();
          final option = find.byKey(Key('playback-$name-$value'));
          await tester.ensureVisible(option);
          await tester.tap(option);
          await tester.pumpAndSettle();
        }

        await choose('buffer-mib', 128);
        await choose('read-ahead-seconds', 60);
        await choose('resume-seconds', 5);
        expect(
          saved.playback.toJson(),
          const PlaybackBufferSettings(
            forwardMiB: 128,
            readAheadSeconds: 60,
            resumeSeconds: 5,
          ).toJson(),
        );
        expect(saved.plaintextMiB, 256);
        expect(backend.caches, [
          {'plaintext_mib': 256, 'plaintext_page_kib': 64, 'ciphertext_mib': 1},
        ]);
        failSave = true;
        await choose('buffer-mib', 256);
        expect(saved.playback.forwardMiB, 128);
        expect(find.text('无法保存缓存设置，请重试。'), findsOneWidget);
        expect(find.text('128 MiB / 视频'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          ReaderApp(
            backend: CacheBackend(plain: true),
            initialImage: 'restored.vhdx',
            platform: platform,
            cacheSettings: saved,
          ),
        );
        await tester.pumpAndSettle();
        await openReaderSettings(tester);
        await ensureReaderSettingVisible(
          tester,
          find.byKey(const Key('playback-buffer-mib')),
        );
        expect(find.text('128 MiB / 视频'), findsOneWidget);
        await ensureReaderSettingVisible(
          tester,
          find.byKey(const Key('playback-read-ahead-seconds')),
        );
        expect(find.text('60 秒'), findsOneWidget);
        await ensureReaderSettingVisible(
          tester,
          find.byKey(const Key('playback-resume-seconds')),
        );
        expect(find.text('5 秒'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
