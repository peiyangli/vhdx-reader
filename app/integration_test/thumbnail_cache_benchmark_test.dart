import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/thumbnails.dart';
import '../test/thumbnails_test.dart' show ImageBackend, png, testThumbnail;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('persistent thumbnail cache write benchmark', (tester) async {
    final directory = await Directory.systemTemp.createTemp(
      'thumbnail-benchmark-',
    );
    final bytes = await png();
    final template = await testThumbnail(bytes);
    final cache = ThumbnailCache(
      directory: directory,
      generator: (_, path, entry) async => template.clone(),
    );
    final scope = ThumbnailScope(
      cache,
      ImageBackend(bytes),
      'benchmark',
      encrypted: false,
    );
    final clock = Stopwatch()..start();
    try {
      // Seed a realistic existing cache without spending time decoding images.
      for (var i = 0; i < 100; i++) {
        final entry = {
          'name': '$i.png',
          'size': bytes.length,
          'modified_unix_ms': 1,
        };
        (await cache.request(scope, '/$i.png', entry).future)?.dispose();
      }
      for (var i = 0; i < 200; i++) {
        if ((await directory.list().toList())
                .where((f) => f.path.endsWith('.thumb'))
                .length ==
            100) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final entries = await directory.list().toList();
      expect(entries.where((f) => f.path.endsWith('.thumb')).length, 100);
      // Retain the cache until its final write/eviction can finish.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      debugPrint('CACHE_BENCHMARK_100_WRITES_MS=${clock.elapsedMilliseconds}');
    } finally {
      cache.dispose();
      template.dispose();
      await directory.delete(recursive: true);
    }
  });
}
