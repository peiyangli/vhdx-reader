import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/main.dart';
import 'reader_test.dart' show FakeBackend;
import 'ui_actions.dart';

class CacheBackend extends FakeBackend {
  CacheBackend({this.plain = false, this.saved = false}) {
    reject = false;
  }
  final bool plain;
  final bool saved;
  final caches = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    if (request['op'] == 'open' && plain) {
      return {
        'partitions': [
          {'index': 1, 'kind': 'Ntfs'},
        ],
      };
    }
    if (request['op'] == 'vault_status') {
      return {
        'available': true,
        'saved': saved,
        'authentication_required': true,
      };
    }
    if (request['op'] == 'unlock' || request['op'] == 'unlock_saved') {
      caches.add(Map<String, dynamic>.from(request['cache'] as Map));
    }
    return super.request(request);
  }
}

void main() {
  test('preferences persist replacements and reject malformed sizes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'vhdx-cache-settings-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final store = CacheSettingsStore(directory: directory);
    expect((await store.load()).toJson(), const CacheSettings().toJson());
    await store.save(const CacheSettings(plaintextMiB: 64, ciphertextMiB: 4));
    expect(
      (await CacheSettingsStore(directory: directory).load()).plaintextMiB,
      64,
    );
    await store.save(const CacheSettings(plaintextMiB: 128, ciphertextMiB: 8));
    expect((await store.load()).toJson(), {
      'plaintext_mib': 128,
      'plaintext_page_kib': 64,
      'ciphertext_mib': 8,
    });
    await expectLater(
      store.save(const CacheSettings(plaintextMiB: 32768)),
      throwsArgumentError,
    );
    expect((await store.load()).plaintextMiB, 128);
    final file = File('${directory.path}/read-cache-settings.json');
    await file.writeAsString('{broken');
    expect((await store.load()).plaintextMiB, 16);
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        'cache': {'plaintext_mib': 64.0, 'ciphertext_mib': -1},
      }),
    );
    expect((await store.load()).toJson(), const CacheSettings().toJson());
    expect(directory.listSync().length, 1);
  });

  test(
    'large capacities and page sizes persist independently with legacy defaults',
    () async {
      final directory = await Directory.systemTemp.createTemp('cache-layout-');
      addTearDown(() => directory.delete(recursive: true));
      final store = CacheSettingsStore(directory: directory);
      for (final mib in [1024, 4096, 8192, 16384]) {
        for (final kib in CacheSettings.plaintextPageOptions) {
          final settings = CacheSettings(
            plaintextMiB: mib,
            plaintextPageKiB: kib,
          );
          await store.save(settings);
          final loaded = await CacheSettingsStore(directory: directory).load();
          expect(loaded.toJson(), settings.toJson());
          expect(loaded.plaintextPageCount, mib * 1024 ~/ kib);
        }
      }
      for (final page in [0, 96, 8192]) {
        await expectLater(
          store.save(CacheSettings(plaintextPageKiB: page)),
          throwsArgumentError,
        );
      }
      final file = File('${directory.path}/read-cache-settings.json');
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'cache': {'plaintext_mib': 256, 'ciphertext_mib': 4},
        }),
      );
      expect((await store.load()).plaintextPageKiB, 64);
      expect((await store.load()).plaintextMiB, 256);
      for (final bad in [0, 96, 8192, 1024.0, '1024']) {
        final value = CacheSettings.fromJson({
          'plaintext_mib': 8192,
          'plaintext_page_kib': bad,
        });
        expect(value.plaintextMiB, 8192);
        expect(value.plaintextPageKiB, 64);
      }
    },
  );

  testWidgets(
    'large capacity and page controls show counts, defer unlock and retain failed changes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final first = CacheBackend(plain: true);
      final second = CacheBackend(plain: true);
      var saved = const CacheSettings();
      var failSave = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: first,
          initialImage: 'one.vhdx',
          platform: TargetPlatform.android,
          createBackend: () async => second,
          pickImages: () async => ['two.vhdx'],
          saveCacheSettings: (value) async {
            if (failSave) throw const FileSystemException('test failure');
            saved = value;
          },
        ),
      );
      await tester.pumpAndSettle();
      await openReaderSettings(tester);
      Future<void> choose(String kind, int value) async {
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
        final item = find.byKey(Key('cache-$kind'));
        await ensureReaderSettingVisible(tester, item);
        await tester.tap(item);
        await tester.pumpAndSettle();
        final option = find.byKey(Key('cache-$kind-$value'));
        await tester.ensureVisible(option);
        await tester.tap(option);
        await tester.pumpAndSettle();
      }

      await choose('plaintext', 16384);
      expect(saved.plaintextMiB, 16384);
      expect(find.text('16 GiB / 卷'), findsOneWidget);
      await choose('plaintext-page', 1024);
      expect(saved.plaintextPageKiB, 1024);
      expect(find.text('1 MiB / 块 · 最多 16384 块'), findsOneWidget);
      expect(first.caches, [const CacheSettings().toJson()]);
      failSave = true;
      await choose('plaintext-page', 4096);
      expect(saved.plaintextPageKiB, 1024);
      expect(find.text('1 MiB / 块 · 最多 16384 块'), findsOneWidget);
      expect(find.text('无法保存缓存设置，请重试。'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-back')));
      await tester.pumpAndSettle();
      await browserAction(tester, 'open-image');
      expect(second.caches, [saved.toJson()]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final mode in ['plain', 'manual', 'saved']) {
    testWidgets('$mode unlock receives the configured cache budgets', (
      tester,
    ) async {
      final backend = CacheBackend(
        plain: mode == 'plain',
        saved: mode == 'saved',
      );
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'cache.vhdx',
          cacheSettings: const CacheSettings(
            plaintextMiB: 16384,
            plaintextPageKiB: 1024,
            ciphertextMiB: 4,
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (mode == 'manual') {
        await tester.enterText(find.byKey(const Key('unlock-secret')), 'fake');
        await tester.ensureVisible(find.byKey(const Key('unlock-button')));
        await tester.tap(find.byKey(const Key('unlock-button')));
        await tester.pumpAndSettle();
      }
      expect(backend.caches, [
        {
          'plaintext_mib': 16384,
          'plaintext_page_kib': 1024,
          'ciphertext_mib': 4,
        },
      ]);
    });
  }

  testWidgets(
    'settings save without reopening a volume; failures keep prior value',
    (tester) async {
      tester.view.physicalSize = const Size(800, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final first = CacheBackend(plain: true);
      final second = CacheBackend(plain: true);
      CacheSettings? stored;
      bool failSave = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: first,
          initialImage: 'first.vhdx',
          platform: TargetPlatform.android,
          createBackend: () async => second,
          pickImages: () async => ['second.vhdx'],
          saveCacheSettings: (value) async {
            if (failSave) throw const FileSystemException('test failure');
            stored = value;
          },
        ),
      );
      await tester.pumpAndSettle();
      await openReaderSettings(tester);
      await ensureReaderSettingVisible(
        tester,
        find.byKey(const Key('cache-plaintext')),
      );
      await tester.tap(find.byKey(const Key('cache-plaintext')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cache-plaintext-64')));
      await tester.tap(find.byKey(const Key('cache-plaintext-64')));
      await tester.pumpAndSettle();
      expect(stored!.plaintextMiB, 64);
      expect(first.caches, [const CacheSettings().toJson()]);
      expect(find.text('64 MiB / 卷'), findsOneWidget);
      failSave = true;
      await tester.tap(find.byKey(const Key('cache-plaintext')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cache-plaintext-128')));
      await tester.tap(find.byKey(const Key('cache-plaintext-128')));
      await tester.pumpAndSettle();
      expect(find.text('无法保存缓存设置，请重试。'), findsOneWidget);
      expect(find.text('64 MiB / 卷'), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-back')));
      await tester.pumpAndSettle();
      await browserAction(tester, 'open-image');
      expect(second.caches, [
        {'plaintext_mib': 64, 'plaintext_page_kib': 64, 'ciphertext_mib': 1},
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
