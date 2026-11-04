import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/platform_storage.dart';
import 'package:vhdx_reader/range_reader.dart';
import 'package:vhdx_reader/media_preview.dart';
import 'package:pdfrx/pdfrx.dart';

String fixture(String name) =>
    'content://org.vhdxreader.vhdx_reader.fixtures/$name';
Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  fail('Timed out waiting for Android reader');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android Keystore remembers a password file, reopens without it and forgets',
    (tester) async {
      var backend = await NativeBackend.start();
      addTearDown(() => backend.dispose());
      await backend.request({
        'op': 'open',
        'path': fixture('bitlockervhdx.vhdx'),
      });
      final status = await backend.request({
        'op': 'vault_status',
        'partition': 1,
      });
      expect(status['available'], true);
      expect(
        status['saved'],
        false,
        reason: 'The test fixture must not already have a saved credential.',
      );
      final id = status['id'] as String;
      addTearDown(() async {
        await backend.request({'op': 'vault_remove', 'id': id});
      });
      final unlocked = await backend.request({
        'op': 'unlock',
        'partition': 1,
        'mode': 'password',
        'credential_file': fixture('password.txt'),
        'remember': true,
        'label': 'Android vault regression',
      });
      expect(unlocked['remembered'], true);
      await backend.dispose();
      backend = await NativeBackend.start();
      await backend.request({
        'op': 'open',
        'path': fixture('bitlockervhdx.vhdx'),
      });
      await backend.request({'op': 'unlock_saved', 'partition': 1});
      expect(
        (await backend.request({
          'op': 'read',
          'path': '/hello.txt',
          'offset': 0,
          'length': 16,
        }))['size'],
        5,
      );
      await backend.request({'op': 'lock'});
      await expectLater(
        backend.request({
          'op': 'unlock',
          'partition': 1,
          'mode': 'password',
          'secret': 'wrong-test-value',
          'remember': true,
        }),
        throwsA(isA<ReaderFailure>()),
      );
      await backend.request({'op': 'unlock_saved', 'partition': 1});
      await backend.request({'op': 'vault_remove', 'id': id});
      await backend.request({'op': 'lock'});
      await expectLater(
        backend.request({'op': 'unlock_saved', 'partition': 1}),
        throwsA(
          isA<ReaderFailure>().having((e) => e.code, 'code', 'vault_missing'),
        ),
      );
    },
  );
  testWidgets(
    'Android SAF descriptors: independent images, BitLocker, pipe rejection, PDF and video',
    (tester) async {
      final a = await NativeBackend.start();
      final b = await NativeBackend.start();
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await a.request({'op': 'open', 'path': fixture('basicvhdx.vhdx')});
      await a.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
      expect(
        await PlatformStorage.channel.invokeMethod<int>('debugDescriptorCount'),
        0,
      );
      final text = await a.request({
        'op': 'read',
        'path': '/can.txt',
        'offset': 0,
        'length': 64,
      });
      expect(text['size'], 7);
      await b.request({'op': 'open', 'path': fixture('bitlockervhdx.vhdx')});
      await expectLater(
        b.request({
          'op': 'unlock',
          'partition': 1,
          'mode': 'password',
          'secret': 'wrong-test-password',
        }),
        throwsA(isA<ReaderFailure>()),
      );
      await b.request({
        'op': 'unlock',
        'partition': 1,
        'mode': 'password',
        'credential_file': fixture('password.txt'),
      });
      final hello = await b.request({
        'op': 'read',
        'path': '/hello.txt',
        'offset': 0,
        'length': 64,
      });
      expect(hello['size'], 5);
      await a.request({'op': 'close'});
      expect(
        (await b.request({
          'op': 'read',
          'path': '/hello.txt',
          'offset': 0,
          'length': 64,
        }))['size'],
        5,
      );
      await expectLater(
        a.request({'op': 'open', 'path': fixture('pipe.vhdx')}),
        throwsA(isA<ReaderFailure>()),
      );
      expect(
        await PlatformStorage.channel.invokeMethod<int>('debugDescriptorCount'),
        0,
      );
      await a.request({'op': 'open', 'path': fixture('pdf-preview.vhdx')});
      await a.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
      final reader = await BackendRangeReader.open(a, '/guide.pdf');
      await pdfrxFlutterInitialize();
      final doc = await PdfDocument.openCustom(
        read: reader.read,
        fileSize: reader.size,
        sourceName: 'android-pdf',
        maxSizeToCacheOnMemory: 0,
      );
      expect(doc.pages.length, 2);
      final rendered = await doc.pages.first.render(width: 320, height: 420);
      expect(rendered, isNotNull);
      rendered!.dispose();
      await doc.dispose();
      await reader.close();
      await a.request({'op': 'close'});
      await tester.pumpWidget(
        ReaderApp(
          backend: a,
          initialImage: fixture('media-preview.vhdx'),
          pickImages: () async => [fixture('basicvhdx.vhdx')],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('sample.mp4'));
      await waitFor(
        tester,
        () => find.byType(MediaPreview).evaluate().isNotEmpty,
      );
      final source = tester
          .widget<MediaPreview>(find.byType(MediaPreview))
          .source;
      await source.setVolume(0);
      await waitFor(
        tester,
        () =>
            source.duration.inSeconds >= 30 &&
            source.position.inMilliseconds > 500,
      );
      expect(source.error, isNull);
      expect(
        await (source.player.platform as NativePlayer).getProperty(
          'cache-on-disk',
        ),
        'no',
      );
      await source.seek(const Duration(seconds: 26));
      await waitFor(tester, () => source.position.inSeconds >= 25);
      expect((await source.statistics())['ranges'] as int, greaterThan(1));
      await tester.tap(find.byTooltip('添加镜像（可多选）'));
      await waitFor(
        tester,
        () => find.text('can.txt').evaluate().isNotEmpty && !source.playing,
      );
      await tester.tap(find.text('can.txt'));
      await tester.pumpAndSettle();
      expect(
        find.text(utf8.decode(base64Decode(text['bytes'] as String))),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        await PlatformStorage.channel.invokeMethod<int>('debugDescriptorCount'),
        0,
      );
    },
  );
}
