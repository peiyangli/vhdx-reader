import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/platform_storage.dart';
import 'package:vhdx_reader/thumbnails.dart';
import 'test_configuration.dart';

class ThumbnailTransportBackend extends ReaderBackend {
  ThumbnailTransportBackend(this.inner);
  final ReaderBackend inner;
  final transports = <String>[];
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) {
    if (value['op'] == 'media_open') {
      transports.add(value['transport'] as String? ?? 'http');
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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real video thumbnail uses a private decoder and revokes after lock',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Thumbnail integration test')),
        ),
      );
      final backend = ThumbnailTransportBackend(await NativeBackend.start());
      final directory = await Directory.systemTemp.createTemp(
        'vhdx-thumbnail-test-',
      );
      final cache = ThumbnailCache(
        directory: directory,
        onError: (error) => debugPrint('Thumbnail failure: $error'),
      );
      try {
        await backend.request({
          'op': 'open',
          'path': Platform.isIOS
              ? '${await PlatformStorage.channel.invokeMethod<String>('testFixtureDirectory')}/media-preview.vhdx'
              : Platform.isAndroid
              ? 'content://org.vhdxreader.vhdx_reader.uitest.fixtures/media-preview.vhdx'
              : fixtureSetting('VHDX_MEDIA_FIXTURE')!,
        });
        await backend.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
        final listing = await backend.request({
          'op': 'list',
          'path': '/',
          'start': 0,
          'limit': 200,
        });
        final file = Map<String, dynamic>.from(
          (listing['entries'] as List).firstWhere(
                (e) => e['name'] == 'sample.mp4',
              )
              as Map,
        );
        final scope = ThumbnailScope(
          cache,
          backend,
          'fixture',
          encrypted: true,
        );
        Thumbnail? thumb;
        var completed = false;
        final pending = cache.request(scope, '/sample.mp4', file).future.then((
          value,
        ) {
          thumb = value;
          completed = true;
        });
        for (var i = 0; i < 150 && !completed; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          completed,
          isTrue,
          reason: 'Thumbnail request must finish within its budget',
        );
        await pending;
        expect(thumb, isNotNull);
        expect(backend.transports, ['native']);
        expect(thumb!.image.width, lessThanOrEqualTo(320));
        expect(thumb!.duration.inSeconds, greaterThanOrEqualTo(30));
        thumb!.dispose();
        expect(await directory.list().toList(), isEmpty);
        scope.invalidate();
        await backend.request({'op': 'lock'});
        expect(await cache.request(scope, '/sample.mp4', file).future, isNull);
      } finally {
        cache.dispose();
        await backend.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
