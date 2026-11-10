import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/preview.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/thumbnails.dart';
import 'test_configuration.dart';

class FixtureBackend extends ReaderBackend {
  FixtureBackend(this.inner, this.root);
  final ReaderBackend inner;
  final String root;
  final mediaPaths = <String>[];
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) {
    if (value['op'] == 'media_open') mediaPaths.add(value['path'] as String);
    if (value['op'] == 'vault_status') {
      return Future.value({'available': false, 'saved': false});
    }
    if (value['op'] == 'unlock') {
      value = {...value, 'credential_file': '$root/password.txt'}
        ..remove('secret');
    }
    return inner.request(value);
  }

  @override
  void beginOperation() => inner.beginOperation();
  @override
  void cancel() => inner.cancel();
  @override
  Future<void> dispose() => inner.dispose();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('BitLocker videos appear without refreshing and survive reopening', (
    tester,
  ) async {
    final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
    final directory = await Directory.systemTemp.createTemp(
      'bitlocker-thumbs-',
    );
    final fileCache = await Directory.systemTemp.createTemp(
      'thumbnail-file-cache-',
    );
    final backend = FixtureBackend(await NativeBackend.start(), root);
    final traces = <Map<String, dynamic>>[];
    String? sourceRevision;
    var cache = ThumbnailCache(
      directory: directory,
      onTrace: traces.add,
      settings: const CacheSettings(bitLockerThumbnailDisk: true),
      onError: (e) => debugPrint('THUMB ERROR: $e'),
    );
    ThumbnailScope? scope;
    var generatedBeforeReopen = 0;
    try {
      final configured = await backend.request({
        'op': 'disk_cache_configure',
        'cache_enabled': true,
        'enabled': true,
        'directory': fileCache.path,
        'max_gib': 1,
        'retention_days': 0,
      });
      expect(configured['enabled'], isTrue);
      for (var pass = 0; pass < 2; pass++) {
        final opened = await backend.request({
          'op': 'open',
          'path': '$root/bitlockervhdx.vhdx',
        });
        expect(opened['source_revision'], isA<String>());
        sourceRevision ??= opened['source_revision'] as String;
        expect(
          opened['source_revision'],
          sourceRevision,
          reason: 'An unchanged image must keep its namespace across reopen',
        );
        await backend.request({
          'op': 'unlock',
          'partition': 1,
          'mode': 'password',
          'credential_file': '$root/password.txt',
        });
        final listing = await backend.request({
          'op': 'list',
          'path': '/video',
          'start': 0,
          'limit': 200,
        });
        final entries = (listing['entries'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((e) => isVideo(e['name'] as String))
            .toList();
        // The pinned Windows mpv build lacks RV10 (this RMVB fixture's codec).
        // It must retain the video fallback without delaying decodable files.
        final expected = entries.where((e) => e['name'] != 'rmvb.rmvb').length;
        scope = ThumbnailScope(
          cache,
          backend,
          jsonEncode([
            '$root/bitlockervhdx.vhdx',
            opened['source_revision'],
            1,
          ]),
          encrypted: true,
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final e in entries)
                    FileThumbnail(
                      key: ValueKey('$pass-${e['name']}'),
                      entry: e,
                      path: '/video/${e['name']}',
                      size: const Size(80, 60),
                      scope: scope,
                    ),
                ],
              ),
            ),
          ),
        );
        final clock = Stopwatch()..start();
        var last = -1;
        while (clock.elapsed < const Duration(seconds: 15)) {
          // Let the app request its own frames: no manual refresh or test pumping.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final count = find.byType(RawImage).evaluate().length;
          if (count != last) {
            debugPrint(
              'PASS $pass ${clock.elapsedMilliseconds}ms: $count/$expected visible',
            );
            last = count;
          }
          if (count == expected) break;
        }
        expect(find.byType(RawImage), findsNWidgets(expected));
        debugPrint('PASS $pass completed in ${clock.elapsedMilliseconds}ms');
        if (pass == 0) {
          for (final entry in entries.where((e) => e['name'] != 'rmvb.rmvb')) {
            expect(
              backend.mediaPaths
                  .where((p) => p == '/video/${entry['name']}')
                  .length,
              1,
              reason: 'A supported video must open on the first attempt',
            );
          }
          await Future<void>.delayed(const Duration(seconds: 5));
          expect(
            backend.mediaPaths.where((p) => p == '/video/rmvb.rmvb').length,
            1,
            reason:
                'A confirmed unsupported codec must not repeatedly start decoders',
          );
        }
        if (pass == 1) {
          final lookups = traces.where((e) => e['phase'] == 'lookup').toList();
          expect(
            lookups.where((e) => e['outcome'] == 'hit'),
            hasLength(expected),
          );
          expect(
            lookups.where((e) => e['outcome'] == 'unavailable'),
            hasLength(1),
          );
          expect(traces.where((e) => e['phase'] == 'generation'), isEmpty);
          debugPrint('REOPEN_CACHE hits=$expected unavailable=1 regenerated=0');
          expect(
            backend.mediaPaths.length,
            generatedBeforeReopen,
            reason:
                'Reopened cache must skip successful and unsupported videos',
          );
        }
        generatedBeforeReopen = backend.mediaPaths.length;
        await cache.persistenceIdle;
        for (var i = 0; i < 100; i++) {
          if ((await directory.list().toList())
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.thumb'))
                  .length ==
              entries.length) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          (await directory.list().toList())
              .whereType<File>()
              .where((f) => f.path.endsWith('.thumb'))
              .length,
          entries.length,
        );
        final records = await Future.wait(
          (await directory.list().toList()).whereType<File>().map(
            (file) async => jsonDecode(await file.readAsString()) as Map,
          ),
        );
        expect(
          records.where((record) => record['unavailable'] == true).length,
          1,
        );
        if (pass == 1) expect(clock.elapsedMilliseconds, lessThan(2000));
        await tester.pumpWidget(const SizedBox.shrink());
        scope.invalidate();
        await backend.request({'op': 'lock'});
        cache.dispose();
        traces.clear();
        cache = ThumbnailCache(
          directory: directory,
          onTrace: traces.add,
          settings: const CacheSettings(bitLockerThumbnailDisk: true),
        );
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      scope?.invalidate();
      cache.dispose();
      await cache.persistenceIdle;
      await backend.dispose();
      await directory.delete(recursive: true);
      await fileCache.delete(recursive: true);
    }
  });
  testWidgets('full Windows browser displays BitLocker thumbnails while idle', (
    tester,
  ) async {
    final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
    final backend = FixtureBackend(await NativeBackend.start(), root);
    await tester.pumpWidget(
      ReaderApp(backend: backend, initialImage: '$root/bitlockervhdx.vhdx'),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('unlock-secret')), 'fixture');
    await tester.tap(find.byKey(const Key('unlock-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('video'));
    await tester.pumpAndSettle();
    final clock = Stopwatch()..start();
    var last = -1;
    while (clock.elapsed < const Duration(seconds: 15)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final count = find
          .descendant(
            of: find.byType(FileThumbnail),
            matching: find.byType(RawImage),
          )
          .evaluate()
          .length;
      if (count != last) {
        final scopes = tester
            .widgetList<FileThumbnail>(find.byType(FileThumbnail))
            .map((w) => w.scope?.available)
            .toList();
        debugPrint(
          'BROWSER ${clock.elapsedMilliseconds}ms: $count thumbnails, scopes $scopes',
        );
        last = count;
      }
      if (count == 5) break;
    }
    expect(
      find.descendant(
        of: find.byType(FileThumbnail),
        matching: find.byType(RawImage),
      ),
      findsNWidgets(5),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('thumb-rmvb.rmvb')),
        matching: find.byType(RawImage),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
