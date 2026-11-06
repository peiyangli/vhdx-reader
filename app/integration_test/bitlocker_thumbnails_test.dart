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
    final backend = FixtureBackend(await NativeBackend.start(), root);
    var cache = ThumbnailCache(
      directory: directory,
      settings: const CacheSettings(bitLockerThumbnailDisk: true),
      onError: (e) => debugPrint('THUMB ERROR: $e'),
    );
    ThumbnailScope? scope;
    var generatedBeforeReopen = 0;
    try {
      for (var pass = 0; pass < 2; pass++) {
        final opened = await backend.request({
          'op': 'open',
          'path': '$root/bitlockervhdx.vhdx',
        });
        debugPrint('SOURCE REVISION: ${opened['source_revision']}');
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
        if (pass == 1) {
          expect(
            backend.mediaPaths.where((p) => p != '/video/rmvb.rmvb').length,
            generatedBeforeReopen,
            reason: 'Reopened cache must not start any decoder',
          );
        }
        generatedBeforeReopen = backend.mediaPaths
            .where((p) => p != '/video/rmvb.rmvb')
            .length;
        for (var i = 0; i < 100; i++) {
          if ((await directory.list().toList())
                  .whereType<File>()
                  .where((f) => f.path.endsWith('.thumb'))
                  .length ==
              expected) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          (await directory.list().toList())
              .whereType<File>()
              .where((f) => f.path.endsWith('.thumb'))
              .length,
          expected,
        );
        if (pass == 1) expect(clock.elapsedMilliseconds, lessThan(2000));
        await tester.pumpWidget(const SizedBox.shrink());
        scope.invalidate();
        await backend.request({'op': 'lock'});
        cache.dispose();
        cache = ThumbnailCache(
          directory: directory,
          settings: const CacheSettings(bitLockerThumbnailDisk: true),
        );
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      scope?.invalidate();
      cache.dispose();
      await backend.dispose();
      await directory.delete(recursive: true);
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
