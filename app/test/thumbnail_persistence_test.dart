import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/thumbnails.dart';
import 'thumbnails_test.dart' show ImageBackend, png;

Future<Thumbnail> thumbnail() async {
  final codec = await ui.instantiateImageCodec(await png());
  try {
    return Thumbnail((await codec.getNextFrame()).image, Duration.zero);
  } finally {
    codec.dispose();
  }
}

Map<String, dynamic> entry(String name) => {
  'name': name,
  'size': 100,
  'modified_unix_ms': 1,
};
Future<void> ready(
  ThumbnailCache cache,
  ThumbnailScope scope,
  String name,
) async {
  final value = await cache
      .request(scope, '/$name', entry(name))
      .future
      .timeout(const Duration(seconds: 2));
  expect(value, isNotNull);
  value?.dispose();
}

Future<List<File>> files(Directory dir) async => (await dir.list().toList())
    .whereType<File>()
    .where((f) => f.path.endsWith('.thumb'))
    .toList();
void main() {
  testWidgets(
    'disk hit and following video bypass a blocked persistence writer',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumbnail-lanes-');
        final template = await thumbnail();
        final backend = ImageBackend(await png());
        final gate = Completer<void>(), started = Completer<void>();
        var block = false, generated = 0;
        final traces = <Map<String, dynamic>>[];
        final cache = ThumbnailCache(
          directory: dir,
          onTrace: traces.add,
          persistenceHook: (stage) async {
            if (block && stage == 'write') {
              if (!started.isCompleted) started.complete();
              await gate.future;
            }
          },
          generator: (_, _, _) async {
            generated++;
            return template.clone();
          },
        );
        var scope = ThumbnailScope(cache, backend, 'stable', encrypted: false);
        try {
          await ready(cache, scope, 'cached.mp4');
          await cache.persistenceIdle;
          scope.invalidate();
          scope = ThumbnailScope(cache, backend, 'stable', encrypted: false);
          block = true;
          await ready(cache, scope, 'first.mp4');
          await started.future;
          await ready(cache, scope, 'cached.mp4');
          await ready(cache, scope, 'next.mp4');
          expect(generated, 3);
          expect(gate.isCompleted, isFalse);
          expect(traces.where((e) => e['outcome'] == 'hit'), hasLength(1));
        } finally {
          gate.complete();
          await cache.persistenceIdle;
          cache.dispose();
          template.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'bounded tickets reuse cached images and do not pin queued pixel buffers',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumbnail-bound-');
        final template = await thumbnail();
        final gate = Completer<void>(), started = Completer<void>();
        final traces = <Map<String, dynamic>>[];
        final cache = ThumbnailCache(
          directory: dir,
          onTrace: traces.add,
          generator: (_, _, _) async => template.clone(),
          persistenceHook: (stage) async {
            if (stage == 'write') {
              if (!started.isCompleted) started.complete();
              await gate.future;
            }
          },
        );
        final scope = ThumbnailScope(
          cache,
          ImageBackend(await png()),
          'bound',
          encrypted: false,
        );
        try {
          await ready(cache, scope, '0.png');
          await started.future;
          for (var i = 1; i < 80; i++) {
            await ready(cache, scope, '$i.png');
          }
          expect(
            cache.pendingPersistenceCount,
            ThumbnailCache.persistenceCountLimit,
          );
          expect(cache.pendingPersistenceBytes, 64 * 32 * 4);
          expect(
            traces.where((e) => e['outcome'] == 'queue_full'),
            hasLength(16),
          );
          gate.complete();
          await cache.persistenceIdle;
          expect(await files(dir), hasLength(64));
          expect(cache.pendingPersistenceCount, 0);
          expect(cache.pendingPersistenceBytes, 0);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await cache.persistenceIdle;
          cache.dispose();
          template.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'memory eviction frees queued images while the active writer owns a clone',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumbnail-evict-');
        final template = await thumbnail();
        final gate = Completer<void>(), started = Completer<void>();
        final traces = <Map<String, dynamic>>[];
        final cache = ThumbnailCache(
          directory: dir,
          memoryLimit: 64 * 32 * 4,
          onTrace: traces.add,
          generator: (_, _, _) async => template.clone(),
          persistenceHook: (stage) async {
            if (stage == 'write') {
              if (!started.isCompleted) started.complete();
              await gate.future;
            }
          },
        );
        final scope = ThumbnailScope(
          cache,
          ImageBackend(await png()),
          'evict',
          encrypted: false,
        );
        try {
          await ready(cache, scope, '0.png');
          await started.future;
          for (var i = 1; i < 20; i++) {
            await ready(cache, scope, '$i.png');
          }
          expect(cache.pendingPersistenceBytes, 64 * 32 * 4);
          gate.complete();
          await cache.persistenceIdle;
          expect(await files(dir), hasLength(2));
          expect(
            traces.where((e) => e['outcome'] == 'memory_evicted'),
            hasLength(18),
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          await cache.persistenceIdle;
          cache.dispose();
          template.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
  for (final stage in ['encode', 'write', 'renamed']) {
    for (final action in [
      'clear',
      'clearDisk',
      'configure',
      'disable',
      'inactive',
      'invalidate',
      'dispose',
    ]) {
      testWidgets('$action during $stage rejects late persistent data', (
        tester,
      ) async {
        await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp(
            'thumbnail-revoke-',
          );
          final template = await thumbnail();
          final gate = Completer<void>(), started = Completer<void>();
          final cache = ThumbnailCache(
            directory: dir,
            settings: const CacheSettings(bitLockerThumbnailDisk: true),
            generator: (_, _, _) async => template.clone(),
            persistenceHook: (s) async {
              if (s == stage) {
                if (!started.isCompleted) started.complete();
                await gate.future;
              }
            },
          );
          final scope = ThumbnailScope(
            cache,
            ImageBackend(await png()),
            'private',
            encrypted: true,
          );
          var disposed = false;
          try {
            await ready(cache, scope, 'first.png');
            await started.future;
            await ready(cache, scope, 'queued.png');
            Future<void>? operation;
            switch (action) {
              case 'clear':
                operation = cache.clear();
              case 'clearDisk':
                operation = cache.clearDisk();
              case 'configure':
                operation = cache.configure(
                  const CacheSettings(bitLockerThumbnailDisk: true),
                );
              case 'disable':
                operation = cache.configure(const CacheSettings());
              case 'inactive':
                scope.setActive(false);
                scope.setActive(true);
              case 'invalidate':
                scope.invalidate();
              case 'dispose':
                cache.dispose();
                disposed = true;
            }
            gate.complete();
            await operation;
            await cache.persistenceIdle;
            expect(await dir.list().toList(), isEmpty);
            expect(cache.pendingPersistenceBytes, 0);
            expect(cache.pendingPersistenceCount, 0);
          } finally {
            if (!gate.isCompleted) gate.complete();
            await cache.persistenceIdle;
            if (!disposed) cache.dispose();
            template.dispose();
            await dir.delete(recursive: true);
          }
        });
      });
    }
  }
  testWidgets(
    'a request started before clearDisk cannot repopulate it after generation',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumbnail-late-');
        final template = await thumbnail();
        final gate = Completer<void>(), started = Completer<void>();
        final cache = ThumbnailCache(
          directory: dir,
          generator: (_, _, _) async {
            started.complete();
            await gate.future;
            return template.clone();
          },
        );
        final scope = ThumbnailScope(
          cache,
          ImageBackend(await png()),
          'late',
          encrypted: false,
        );
        try {
          final request = cache.request(scope, '/late.png', entry('late.png'));
          await started.future;
          await cache.clearDisk();
          gate.complete();
          (await request.future)?.dispose();
          await cache.persistenceIdle;
          expect(await dir.list().toList(), isEmpty);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await cache.persistenceIdle;
          cache.dispose();
          template.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
  testWidgets('write failure does not stop following persistent entries', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('thumbnail-fail-');
      final template = await thumbnail();
      var writes = 0;
      final traces = <Map<String, dynamic>>[];
      final cache = ThumbnailCache(
        directory: dir,
        onTrace: traces.add,
        generator: (_, _, _) async => template.clone(),
        persistenceHook: (stage) async {
          if (stage == 'write' && writes++ == 0) {
            throw const FileSystemException('injected write failure');
          }
        },
      );
      final scope = ThumbnailScope(
        cache,
        ImageBackend(await png()),
        'failure',
        encrypted: false,
      );
      try {
        await ready(cache, scope, 'first.png');
        await cache.persistenceIdle;
        await ready(cache, scope, 'next.png');
        await cache.persistenceIdle;
        expect(await files(dir), hasLength(1));
        expect(traces.where((e) => e['outcome'] == 'failed'), hasLength(1));
      } finally {
        await cache.persistenceIdle;
        cache.dispose();
        template.dispose();
        await dir.delete(recursive: true);
      }
    });
  });
  testWidgets(
    'cache hits update incremental eviction order and byte quota stays bounded',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumbnail-lru-');
        final template = await thumbnail();
        final pngBytes = (await template.image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        final size = jsonEncode({
          'png': base64Encode(pngBytes),
          'duration': 0,
        }).length;
        var generated = 0;
        final cache = ThumbnailCache(
          directory: dir,
          diskLimit: size * 2,
          generator: (_, _, _) async {
            generated++;
            return template.clone();
          },
        );
        final backend = ImageBackend(await png());
        var scope = ThumbnailScope(cache, backend, 'lru', encrypted: false);
        try {
          for (final name in ['a.png', 'b.png']) {
            await ready(cache, scope, name);
            await cache.persistenceIdle;
          }
          scope.invalidate();
          scope = ThumbnailScope(cache, backend, 'lru', encrypted: false);
          await ready(cache, scope, 'a.png');
          expect(generated, 2);
          await ready(cache, scope, 'c.png');
          await cache.persistenceIdle;
          expect(await files(dir), hasLength(2));
          scope.invalidate();
          scope = ThumbnailScope(cache, backend, 'lru', encrypted: false);
          await ready(cache, scope, 'a.png');
          expect(generated, 3);
          await ready(cache, scope, 'b.png');
          expect(generated, 4);
          await cache.persistenceIdle;
          final sizes = await Future.wait(
            (await files(dir)).map((f) => f.length()),
          );
          expect(sizes.fold(0, (a, b) => a + b), lessThanOrEqualTo(size * 2));
        } finally {
          await cache.persistenceIdle;
          cache.dispose();
          template.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'new disk lookups wait for clear without consuming old cache entries',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp(
          'thumbnail-clear-read-',
        );
        final template = await thumbnail();
        final gate = Completer<void>(), started = Completer<void>();
        var block = false, generated = 0, completed = false;
        final cache = ThumbnailCache(
          directory: dir,
          generator: (_, _, _) async {
            generated++;
            return template.clone();
          },
          persistenceHook: (stage) async {
            if (block && stage == 'write') {
              if (!started.isCompleted) started.complete();
              await gate.future;
            }
          },
        );
        final backend = ImageBackend(await png());
        var scope = ThumbnailScope(
          cache,
          backend,
          'clear-read',
          encrypted: false,
        );
        try {
          await ready(cache, scope, 'cached.png');
          await cache.persistenceIdle;
          scope.invalidate();
          scope = ThumbnailScope(
            cache,
            backend,
            'clear-read',
            encrypted: false,
          );
          block = true;
          await ready(cache, scope, 'writing.png');
          await started.future;
          final clearing = cache.clearDisk();
          final reading = ready(cache, scope, 'cached.png').then((_) {
            completed = true;
          });
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(completed, isFalse);
          expect(generated, 2);
          gate.complete();
          await clearing;
          await reading;
          await cache.persistenceIdle;
          expect(
            generated,
            3,
            reason: 'The explicit request after clear must regenerate',
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          await cache.persistenceIdle;
          cache.dispose();
          template.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'negative markers share the bounded writer instead of an unbounded future chain',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp(
          'thumbnail-negative-bound-',
        );
        final gate = Completer<void>(), started = Completer<void>();
        final cache = ThumbnailCache(
          directory: dir,
          generator: (_, _, _) async => null,
          persistenceHook: (stage) async {
            if (stage == 'write') {
              if (!started.isCompleted) started.complete();
              await gate.future;
            }
          },
        );
        final scope = ThumbnailScope(
          cache,
          ImageBackend(await png()),
          'negative',
          encrypted: false,
        );
        try {
          expect(
            await cache.request(scope, '/0.mp4', entry('0.mp4')).future,
            isNull,
          );
          await started.future;
          for (var i = 1; i < 80; i++) {
            expect(
              await cache.request(scope, '/$i.mp4', entry('$i.mp4')).future,
              isNull,
            );
          }
          expect(
            cache.pendingPersistenceCount,
            ThumbnailCache.persistenceCountLimit,
          );
          expect(cache.pendingPersistenceBytes, 0);
          gate.complete();
          await cache.persistenceIdle;
          expect(await files(dir), hasLength(64));
        } finally {
          if (!gate.isCompleted) gate.complete();
          await cache.persistenceIdle;
          cache.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
  testWidgets(
    'an oversized generated image is displayed without admitting an oversized writer clone',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('thumbnail-large-');
        final picture = ui.PictureRecorder();
        ui.Canvas(picture);
        final recorded = picture.endRecording();
        final image = await recorded.toImage(1025, 1025);
        recorded.dispose();
        final template = Thumbnail(image, Duration.zero);
        var writes = 0;
        final cache = ThumbnailCache(
          directory: dir,
          generator: (_, _, _) async => template.clone(),
          persistenceHook: (_) async {
            writes++;
          },
        );
        final scope = ThumbnailScope(
          cache,
          ImageBackend(await png()),
          'large',
          encrypted: false,
        );
        try {
          await ready(cache, scope, 'large.png');
          await cache.persistenceIdle;
          expect(writes, 0);
          expect(cache.pendingPersistenceBytes, 0);
          expect(await files(dir), isEmpty);
        } finally {
          cache.dispose();
          template.dispose();
          await dir.delete(recursive: true);
        }
      });
    },
  );
}
