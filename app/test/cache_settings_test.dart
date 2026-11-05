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
      return {'available': true, 'saved': saved};
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
      'ciphertext_mib': 8,
    });
    await expectLater(
      store.save(const CacheSettings(plaintextMiB: 1024)),
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
            plaintextMiB: 64,
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
        {'plaintext_mib': 64, 'ciphertext_mib': 4},
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
      await tester.scrollUntilVisible(
        find.byKey(const Key('cache-plaintext')),
        100,
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
        {'plaintext_mib': 64, 'ciphertext_mib': 1},
      ]);
      expect(tester.takeException(), isNull);
    },
  );
}
