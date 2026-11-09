import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/thumbnails.dart';
import 'thumbnails_test.dart' as thumbnails;
import 'bitlocker_thumbnails_test.dart' as encrypted;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  thumbnails.main();
  encrypted.main();
  testWidgets(
    'generated 8 GiB sparse video has bounded reads and following thumbnail completes',
    (tester) async {
      final fixture = Platform.environment['VHDX_THUMBNAIL_FIXTURE']!;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Generated thumbnail validation')),
        ),
      );
      for (final transport in ['http', 'native']) {
        final backend = await NativeBackend.start();
        final traces = <Map<String, dynamic>>[];
        final cache = ThumbnailCache(
          videoTransport: transport,
          onTrace: traces.add,
          onError: (error) => debugPrint('THUMB_DIAGNOSTIC $transport $error'),
        );
        try {
          await backend.request({'op': 'open', 'path': fixture});
          await backend.request({
            'op': 'unlock',
            'partition': 1,
            'mode': 'none',
          });
          final listing = await backend.request({
            'op': 'list',
            'path': '/',
            'start': 0,
            'limit': 200,
          });
          final entries = (listing['entries'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          final large = entries.firstWhere((e) => e['name'] == 'large.mp4');
          final small = entries.firstWhere((e) => e['name'] == 'small.mp4');
          // The data attribute, rather than the FILE_NAME cache, defines file size.
          final info = await backend.request({
            'op': 'file_open',
            'path': '/large.mp4',
          });
          expect(info['size'], 8 * 1024 * 1024 * 1024);
          await backend.request({'op': 'file_close', 'file': info['file']});
          final scope = ThumbnailScope(
            cache,
            backend,
            'generated-$transport',
            encrypted: true,
          );
          Thumbnail? a, b;
          var doneA = false, doneB = false;
          final clock = Stopwatch()..start();
          cache.request(scope, '/large.mp4', large).future.then((v) {
            a = v;
            doneA = true;
          });
          cache.request(scope, '/small.mp4', small).future.then((v) {
            b = v;
            doneB = true;
          });
          while ((!doneA || !doneB) &&
              clock.elapsed < const Duration(seconds: 20)) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(doneA && doneB, isTrue);
          expect(a, isNotNull);
          expect(b, isNotNull);
          a?.dispose();
          b?.dispose();
          final reads = traces.where((t) => t['phase'] == 'reads').toList();
          expect(reads.length, 2);
          for (final stats in reads) {
            expect(
              stats['file_reserved'] as int,
              lessThanOrEqualTo(32 * 1024 * 1024),
            );
            expect(
              stats['source_reserved'] as int,
              lessThanOrEqualTo(64 * 1024 * 1024),
            );
            expect((stats['trace'] as List).length, lessThanOrEqualTo(256));
          }
          debugPrint(
            'THUMBNAIL_LIMITS ${jsonEncode({'transport': transport, 'elapsed_ms': clock.elapsedMilliseconds, 'events': traces})}',
          );
          scope.invalidate();
        } finally {
          cache.dispose();
          await backend.dispose();
        }
      }
      await tester.pump(const Duration(seconds: 6));
    },
  );
}
