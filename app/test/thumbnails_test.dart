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
        // The null result now queues a failure-marker write. Drain it before
        // removing the temporary directory (macOS otherwise reports ENOTEMPTY).
        await cache.clear();
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
      generator: (_, path, entry) async {
        if (++attempts == 1) throw ReaderFailure('busy', 'Reader busy');
        return template.clone();
      },
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

  testWidgets('unreadable thumbnail is marked and never auto retries', (
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
    expect(attempts, 1);
    scope.invalidate();
    await tester.pump(const Duration(seconds: 30));
    expect(attempts, 1);
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
  testWidgets(
    'timed out video releases generation queue and never auto retries',
    (tester) async {
      final bytes = (await tester.runAsync(png))!;
      final template = (await tester.runAsync(() => testThumbnail(bytes)))!;
      final slow = Completer<Thumbnail?>();
      final starts = <String>[];
      final traces = <Map<String, dynamic>>[];
      final cache = ThumbnailCache(
        generationTimeout: const Duration(milliseconds: 50),
        onTrace: traces.add,
        generator: (_, path, entry) async {
          starts.add(path);
          return path == '/slow.mp4' ? slow.future : template.clone();
        },
      );
      final scope = ThumbnailScope(
        cache,
        ImageBackend(bytes),
        'large-files',
        encrypted: true,
      );
      final large = {
        ...entry(bytes),
        'name': 'slow.mp4',
        'size': 8 * 1024 * 1024 * 1024,
      };
      final first = cache.request(scope, '/slow.mp4', large);
      final next = cache.request(scope, '/next.mp4', {
        ...large,
        'name': 'next.mp4',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
      expect(await first.future, isNull);
      final image = await next.future;
      expect(image, isNotNull);
      image?.dispose();
      expect(cache.retryDelay(scope, '/slow.mp4', large), isNull);
      expect(await cache.request(scope, '/slow.mp4', large).future, isNull);
      expect(starts, ['/slow.mp4', '/next.mp4']);
      // The abandoned generator may finish late; its image must not be published.
      slow.complete(template.clone());
      await tester.pump();
      expect(await cache.request(scope, '/slow.mp4', large).future, isNull);
      expect(traces.any((t) => t['timed_out'] == true), isTrue);
      scope.invalidate();
      cache.dispose();
      template.dispose();
    },
  );

  testWidgets(
    'cancel before media_open returns revokes the task and closes late handle',
    (tester) async {
      final backend = DelayedMediaBackend();
      final errors = <Object>[];
      final cache = ThumbnailCache(onError: errors.add);
      final scope = ThumbnailScope(cache, backend, 'delayed', encrypted: true);
      final request = cache.request(scope, '/private.mp4', {
        'name': 'private.mp4',
        'size': 8 * 1024 * 1024 * 1024,
        'modified_unix_ms': 1,
      });
      await tester.pump();
      expect(backend.opened, isTrue);
      request.cancel();
      await tester.pump();
      expect(await request.future, isNull);
      expect(backend.cancelled, isTrue);
      backend.gate.complete({
        'file': 7,
        'url': 'http://unused',
        'size': 8 * 1024 * 1024 * 1024,
      });
      for (var i = 0; i < 10 && !backend.finished; i++) {
        await tester.pump();
      }
      expect(
        backend.closed,
        isTrue,
        reason: '${backend.operations.join(',')} errors=$errors',
      );
      expect(backend.finished, isTrue);
      cache.dispose();
    },
  );
  testWidgets(
    'unfinished cancelled decoders are bounded and resume when one drains',
    (tester) async {
      final bytes = (await tester.runAsync(png))!;
      final gates = List.generate(3, (_) => Completer<Thumbnail?>());
      var starts = 0;
      final cache = ThumbnailCache(
        generationTimeout: const Duration(milliseconds: 50),
        generator: (_, path, entry) => gates[starts++].future,
      );
      final scope = ThumbnailScope(
        cache,
        ImageBackend(bytes),
        'draining',
        encrypted: true,
      );
      final requests = [
        for (var i = 0; i < 3; i++)
          cache.request(scope, '/$i.mp4', {
            'name': '$i.mp4',
            'size': 1,
            'modified_unix_ms': 1,
          }),
      ];
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 60));
      expect(starts, 2);
      gates[0].complete(null);
      await tester.pump();
      expect(starts, 3);
      gates[1].complete(null);
      gates[2].complete(null);
      await tester.pump();
      for (final request in requests) {
        expect(await request.future, isNull);
      }
      cache.dispose();
    },
  );

  testWidgets(
    'unavailable video survives reopening and restart; changes and clear retry',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'thumbnail-failed-',
        );
        final backend = ImageBackend(Uint8List(0));
        var attempts = 0;
        ThumbnailCache create() => ThumbnailCache(
          directory: directory,
          generator: (_, path, entry) async {
            attempts++;
            return null;
          },
        );
        var cache = create();
        ThumbnailScope scope(String identity) =>
            ThumbnailScope(cache, backend, identity, encrypted: false);
        final file = {'name': 'broken.mp4', 'size': 100, 'modified_unix_ms': 1};
        try {
          final original = scope('same-image');
          expect(
            await cache.request(original, '/broken.mp4', file).future,
            isNull,
          );
          await waitForDisk(directory);
          final stored = (await directory.list().toList())
              .whereType<File>()
              .single;
          expect(jsonDecode(await stored.readAsString()), {
            'unavailable': true,
          });
          original.invalidate();
          expect(
            await cache
                .request(scope('same-image'), '/broken.mp4', file)
                .future,
            isNull,
          );
          expect(attempts, 1);
          cache.dispose();
          cache = create();
          final reopened = scope('same-image');
          expect(
            await cache.request(reopened, '/broken.mp4', file).future,
            isNull,
          );
          expect(attempts, 1, reason: 'Restart must not read the media again');
          // Each identity component changes the failure key without hashing content.
          for (final changed in [
            {...file, 'size': 101},
            {...file, 'modified_unix_ms': 2},
          ]) {
            expect(
              await cache.request(reopened, '/broken.mp4', changed).future,
              isNull,
            );
          }
          expect(
            await cache
                .request(scope('replaced-image'), '/broken.mp4', file)
                .future,
            isNull,
          );
          expect(attempts, 4);
          await cache.clear();
          expect(await directory.list().toList(), isEmpty);
          expect(
            await cache.request(reopened, '/broken.mp4', file).future,
            isNull,
          );
          expect(attempts, 5);
          await cache
              .clear(); // Drain queued writes before deleting the test directory.
        } finally {
          cache.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets('undecodable image is not read again after cache restart', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp(
        'thumbnail-bad-image-',
      );
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final backend = ImageBackend(bytes);
      var cache = ThumbnailCache(directory: directory);
      try {
        for (var round = 0; round < 2; round++) {
          final scope = ThumbnailScope(
            cache,
            backend,
            'bad-image',
            encrypted: false,
          );
          expect(
            await cache.request(scope, '/photo.png', entry(bytes)).future,
            isNull,
          );
          await waitForDisk(directory);
          expect(backend.opens, 1);
          expect(backend.closes, 1);
          if (round == 0) {
            cache.dispose();
            cache = ThumbnailCache(directory: directory);
          }
        }
      } finally {
        cache.dispose();
        await directory.delete(recursive: true);
      }
    });
  });

  testWidgets(
    'BitLocker failure markers obey disk opt-in and disable purges them',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'thumbnail-private-failure-',
        );
        final backend = ImageBackend(Uint8List(0));
        var attempts = 0;
        final cache = ThumbnailCache(
          directory: directory,
          generator: (_, path, entry) async {
            attempts++;
            return null;
          },
        );
        ThumbnailScope scope() =>
            ThumbnailScope(cache, backend, 'private', encrypted: true);
        final file = {'name': 'broken.mp4', 'size': 1, 'modified_unix_ms': 1};
        try {
          final first = scope();
          await cache.request(first, '/broken.mp4', file).future;
          first.invalidate();
          await cache.request(scope(), '/broken.mp4', file).future;
          expect(attempts, 1);
          expect(await directory.list().toList(), isEmpty);
          await cache.configure(
            const CacheSettings(bitLockerThumbnailDisk: true),
          );
          await cache.request(scope(), '/broken.mp4', file).future;
          await waitForDisk(directory);
          expect(attempts, 2);
          expect(
            (await directory.list().toList())
                .whereType<File>()
                .single
                .uri
                .pathSegments
                .last,
            startsWith('b-'),
          );
          await cache.configure(const CacheSettings());
          expect(await directory.list().toList(), isEmpty);
          await cache.request(scope(), '/broken.mp4', file).future;
          expect(attempts, 3);
        } finally {
          cache.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets(
    'temporary reader failure and user cancellation do not persist unavailable marks',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'thumbnail-temporary-',
        );
        final backend = ImageBackend(Uint8List(0));
        final gate = Completer<Thumbnail?>();
        final started = Completer<void>();
        var attempts = 0;
        final cache = ThumbnailCache(
          directory: directory,
          generator: (_, path, entry) async {
            attempts++;
            if (path == '/busy.mp4') throw ReaderFailure('busy', 'Reader busy');
            if (attempts == 2) {
              started.complete();
              return gate.future;
            }
            return null;
          },
        );
        final file = {'name': 'busy.mp4', 'size': 1, 'modified_unix_ms': 1};
        final scope = ThumbnailScope(
          cache,
          backend,
          'source',
          encrypted: false,
        );
        try {
          await cache.request(scope, '/busy.mp4', file).future;
          expect(cache.retryDelay(scope, '/busy.mp4', file), isNotNull);
          final request = cache.request(scope, '/cancelled.mp4', {
            ...file,
            'name': 'cancelled.mp4',
          });
          await started.future;
          request.cancel();
          expect(await request.future, isNull);
          gate.complete(null);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(await directory.list().toList(), isEmpty);
          await cache.request(scope, '/cancelled.mp4', {
            ...file,
            'name': 'cancelled.mp4',
          }).future;
          expect(
            attempts,
            3,
            reason: 'Cancellation must allow a later request',
          );
          await cache.clear();
        } finally {
          if (!gate.isCompleted) gate.complete(null);
          cache.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets(
    'timed out video persists its unavailable mark while late cleanup drains',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'thumbnail-timeout-mark-',
        );
        final gate = Completer<Thumbnail?>();
        final cache = ThumbnailCache(
          directory: directory,
          generationTimeout: const Duration(milliseconds: 30),
          generator: (_, path, entry) => gate.future,
        );
        final scope = ThumbnailScope(
          cache,
          ImageBackend(Uint8List(0)),
          'timeout',
          encrypted: false,
        );
        try {
          expect(
            await cache.request(scope, '/slow.mp4', {
              'name': 'slow.mp4',
              'size': 1,
              'modified_unix_ms': 1,
            }).future,
            isNull,
          );
          await waitForDisk(directory);
          final file = (await directory.list().toList())
              .whereType<File>()
              .single;
          expect(jsonDecode(await file.readAsString()), {'unavailable': true});
          gate.complete(null);
          await cache.clear();
          expect(await directory.list().toList(), isEmpty);
        } finally {
          if (!gate.isCompleted) gate.complete(null);
          cache.dispose();
          await directory.delete(recursive: true);
        }
      });
    },
  );

  testWidgets(
    'cancel during task creation revokes late token without opening media',
    (tester) async {
      final backend = DelayedMediaBackend()
        ..beginGate = Completer<Map<String, dynamic>>();
      final cache = ThumbnailCache();
      final scope = ThumbnailScope(
        cache,
        backend,
        'late-task',
        encrypted: true,
      );
      final request = cache.request(scope, '/video.mp4', {
        'name': 'video.mp4',
        'size': 1,
        'modified_unix_ms': 1,
      });
      await tester.pump();
      request.cancel();
      await tester.pump();
      expect(await request.future, isNull);
      backend.beginGate!.complete({'task': 1});
      await tester.pump();
      await tester.pump();
      expect(backend.opened, isFalse);
      expect(backend.cancelled, isTrue);
      expect(backend.finished, isTrue);
      cache.dispose();
    },
  );
}

class DelayedMediaBackend extends ReaderBackend {
  final gate = Completer<Map<String, dynamic>>();
  final operations = <String>[];
  Completer<Map<String, dynamic>>? beginGate;
  bool opened = false, cancelled = false, closed = false, finished = false;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
    operations.add(value['op'] as String);
    switch (value['op']) {
      case 'thumbnail_begin':
        if (beginGate != null) return beginGate!.future;
        return {'task': 1};
      case 'media_open':
        opened = true;
        expectSync(value['thumbnail_task'], 1);
        expectSync(value['transport'], 'native');
        return gate.future;
      case 'thumbnail_cancel':
        cancelled = true;
        return {};
      case 'thumbnail_finish':
        finished = true;
        return {};
      case 'media_close':
        closed = true;
        return {};
      default:
        throw StateError('Unexpected operation');
    }
  }

  @override
  void beginOperation() {}
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}
