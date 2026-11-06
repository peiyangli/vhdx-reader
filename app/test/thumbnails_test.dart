import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
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
}
