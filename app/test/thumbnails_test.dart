import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/thumbnails.dart';

class ImageBackend extends ReaderBackend {
  ImageBackend(this.bytes);
  final Uint8List bytes;
  int opens = 0;
  int closes = 0;
  Completer<void>? gate;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'file_open':
        opens++;
        if (gate != null) await gate!.future;
        return {'file': opens, 'size': bytes.length};
      case 'file_read':
        final start = request['offset'] as int;
        final count = request['length'] as int;
        return {'bytes': base64Encode(bytes.sublist(start, start + count))};
      case 'file_close':
        closes++;
        return {};
      default:
        throw StateError('Unexpected request');
    }
  }

  @override
  void beginOperation() {}
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

Future<Uint8List> png() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 64, 32),
    ui.Paint()..color = const ui.Color(0xff3366aa),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(64, 32);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

Map<String, dynamic> entry(Uint8List bytes) => {
  'name': 'photo.png',
  'size': bytes.length,
  'modified_unix_ms': 1,
};

Future<void> waitForDisk(Directory directory) async {
  for (var i = 0; i < 100; i++) {
    if ((await directory.list().toList()).whereType<File>().any(
      (f) => f.path.endsWith('.thumb'),
    )) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Thumbnail was not persisted');
}

Future<Thumbnail> testThumbnail(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return Thumbnail(
      (await codec.getNextFrame()).image,
      const Duration(seconds: 3),
    );
  } finally {
    codec.dispose();
  }
}

void main() {
  test(
    'old settings keep BitLocker disk thumbnails off; opt-in survives replacement',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'thumbnail-preferences-',
      );
      try {
        final store = CacheSettingsStore(directory: directory);
        expect((await store.load()).bitLockerThumbnailDisk, isFalse);
        await store.save(
          const CacheSettings(
            bitLockerThumbnailDisk: true,
          ).copyWith(plaintextMiB: 64),
        );
        expect((await store.load()).bitLockerThumbnailDisk, isTrue);
        expect((await store.load()).plaintextMiB, 64);
        expect(
          CacheSettings.fromJson({'plaintext_mib': 32}).bitLockerThumbnailDisk,
          isFalse,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
  testWidgets(
    'encrypted thumbnails stay in memory by default and lock revokes hits',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = await png();
        final directory = await Directory.systemTemp.createTemp(
          'thumbnail-private-',
        );
        final cache = ThumbnailCache(directory: directory);
        final backend = ImageBackend(bytes);
        final scope = ThumbnailScope(
          cache,
          backend,
          'source:partition1',
          encrypted: true,
        );
        try {
          final value = await cache
              .request(scope, '/photo.png', entry(bytes))
              .future;
          expect(value?.image.width, 64);
          value?.dispose();
          final hit = await cache
              .request(scope, '/photo.png', entry(bytes))
              .future;
          expect(hit, isNotNull);
          hit?.dispose();
          expect(backend.opens, 1);
          expect(backend.closes, 1);
          expect(await directory.list().toList(), isEmpty);
          scope.invalidate();
          expect(
            await cache.request(scope, '/photo.png', entry(bytes)).future,
            isNull,
          );
          expect(backend.opens, 1);
        } finally {
          cache.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'explicit disk opt-in reuses only an unlocked scope and disabling purges it',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = await png();
        final directory = await Directory.systemTemp.createTemp(
          'thumbnail-opt-in-',
        );
        final cache = ThumbnailCache(
          directory: directory,
          settings: const CacheSettings(bitLockerThumbnailDisk: true),
        );
        final backend = ImageBackend(bytes);
        final scope = ThumbnailScope(
          cache,
          backend,
          'source:partition1',
          encrypted: true,
        );
        try {
          (await cache.request(scope, '/photo.png', entry(bytes)).future)
              ?.dispose();
          await waitForDisk(directory);
          expect((await directory.list().toList()).length, 1);
          scope.invalidate();
          expect(
            await cache.request(scope, '/photo.png', entry(bytes)).future,
            isNull,
          );
          final reopened = ThumbnailScope(
            cache,
            backend,
            'source:partition1',
            encrypted: true,
          );
          (await cache.request(reopened, '/photo.png', entry(bytes)).future)
              ?.dispose();
          expect(
            backend.opens,
            1,
            reason: 'Persisted thumbnail should avoid source reads',
          );
          reopened.invalidate();
          await cache.configure(const CacheSettings());
          expect(await directory.list().toList(), isEmpty);
          final changed = ThumbnailScope(
            cache,
            backend,
            'source:partition2',
            encrypted: true,
          );
          (await cache.request(changed, '/photo.png', entry(bytes)).future)
              ?.dispose();
          expect(
            backend.opens,
            2,
            reason: 'Different partition must not reuse content',
          );
        } finally {
          cache.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'lock during file open drops late results and releases file handles',
    (tester) async {
      await tester.runAsync(() async {
        final bytes = await png();
        final cache = ThumbnailCache();
        final backend = ImageBackend(bytes)..gate = Completer<void>();
        final scope = ThumbnailScope(cache, backend, 'source', encrypted: true);
        final request = cache.request(scope, '/photo.png', entry(bytes));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        scope.invalidate();
        backend.gate!.complete();
        expect(await request.future, isNull);
        expect(backend.closes, 1);
        cache.dispose();
      });
    },
  );
  testWidgets('cached video bypasses a blocked video decoder', (tester) async {
    await tester.runAsync(() async {
      final bytes = await png();
      final directory = await Directory.systemTemp.createTemp(
        'thumbnail-priority-',
      );
      final blocked = Completer<Thumbnail?>();
      final started = Completer<void>();
      var generated = 0;
      final cache = ThumbnailCache(
        directory: directory,
        settings: const CacheSettings(bitLockerThumbnailDisk: true),
        generator: (scope, path, entry) async {
          generated++;
          if (path == '/slow.mp4') {
            started.complete();
            return blocked.future;
          }
          return testThumbnail(bytes);
        },
      );
      final backend = ImageBackend(bytes);
      final file = {...entry(bytes), 'name': 'cached.mp4'};
      final warm = ThumbnailScope(
        cache,
        backend,
        'same-source',
        encrypted: true,
      );
      ThumbnailRequest? slow;
      try {
        (await cache.request(warm, '/cached.mp4', file).future)?.dispose();
        await waitForDisk(directory);
        warm.invalidate();
        final reopened = ThumbnailScope(
          cache,
          backend,
          'same-source',
          encrypted: true,
        );
        slow = cache.request(reopened, '/slow.mp4', {
          ...file,
          'name': 'slow.mp4',
        });
        await started.future;
        final value = await cache
            .request(reopened, '/cached.mp4', file)
            .future
            .timeout(const Duration(seconds: 1));
        expect(value, isNotNull);
        value?.dispose();
        expect(generated, 2, reason: 'Cached video must not be regenerated');
      } finally {
        blocked.complete(null);
        await slow?.future;
        cache.dispose();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets('visible thumbnail retries a transient failure without refresh', (
    tester,
  ) async {
    final bytes = (await tester.runAsync(png))!;
    final template = (await tester.runAsync(() => testThumbnail(bytes)))!;
    var attempts = 0;
    final cache = ThumbnailCache(
      generator: (_, path, entry) async =>
          ++attempts == 1 ? null : template.clone(),
    );
    final scope = ThumbnailScope(
      cache,
      ImageBackend(bytes),
      'retry',
      encrypted: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: FileThumbnail(
          entry: entry(bytes),
          path: '/photo.png',
          size: const Size(64, 32),
          scope: scope,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(attempts, 1);
    expect(find.byType(RawImage), findsNothing);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(attempts, 2);
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    scope.invalidate();
    cache.dispose();
    template.dispose();
  });

  testWidgets('broken media retries are bounded and stop on lock', (
    tester,
  ) async {
    final bytes = (await tester.runAsync(png))!;
    var attempts = 0;
    final cache = ThumbnailCache(
      generator: (_, path, entry) async {
        attempts++;
        return null;
      },
    );
    final scope = ThumbnailScope(
      cache,
      ImageBackend(bytes),
      'broken',
      encrypted: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: FileThumbnail(
          entry: entry(bytes),
          path: '/photo.png',
          size: const Size(64, 32),
          scope: scope,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1100)),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3100)),
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 30));
    expect(attempts, 3);
    scope.invalidate();
    await tester.pump(const Duration(seconds: 30));
    expect(attempts, 3);
    await tester.pumpWidget(const SizedBox.shrink());
    cache.dispose();
  });

  testWidgets('metadata-equivalent rebuild preserves in-flight thumbnail', (
    tester,
  ) async {
    final bytes = (await tester.runAsync(png))!;
    final template = (await tester.runAsync(() => testThumbnail(bytes)))!;
    final gate = Completer<void>();
    var attempts = 0;
    final cache = ThumbnailCache(
      generator: (_, path, entry) async {
        attempts++;
        await gate.future;
        return template.clone();
      },
    );
    final scope = ThumbnailScope(
      cache,
      ImageBackend(bytes),
      'rebuild',
      encrypted: true,
    );
    Widget tile() => MaterialApp(
      home: FileThumbnail(
        entry: entry(bytes),
        path: '/photo.png',
        size: const Size(64, 32),
        scope: scope,
      ),
    );
    await tester.pumpWidget(tile());
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(tile());
    await tester.pump(const Duration(milliseconds: 100));
    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(attempts, 1);
    expect(find.byType(RawImage), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    scope.invalidate();
    cache.dispose();
    template.dispose();
  });
}
