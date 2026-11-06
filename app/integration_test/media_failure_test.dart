import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/media_preview.dart';
import 'test_configuration.dart';
import 'media_test.dart' show waitFor;

String androidFixture(String name) =>
    'content://org.vhdxreader.vhdx_reader.uitest.fixtures/$name';

Future<MediaPreviewSource> openPreview(
  WidgetTester tester,
  ReaderBackend backend,
  String path,
) async {
  MediaPreviewSource? opened;
  Object? openError;
  // VideoController initializes in a post-frame callback. Keep pumping while
  // opening, as the real preview screen does.
  MediaPreviewSource.open(backend, path).then<void>(
    (value) {
      opened = value;
    },
    onError: (Object error) {
      openError = error;
    },
  );
  await waitFor(tester, () => opened != null || openError != null);
  expect(openError, isNull);
  final source = opened!;
  addTearDown(source.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaPreview(source: source, active: true, onExit: () {}),
    ),
  );
  await source.setVolume(0);
  return source;
}

Future<void> closePreview(
  WidgetTester tester,
  MediaPreviewSource source,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  source.dispose();
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'decoder diagnostics do not obscure playback; real failures remain visible',
    (tester) async {
      final backend = await NativeBackend.start();
      addTearDown(backend.dispose);
      await backend.request({
        'op': 'open',
        'path': Platform.isAndroid
            ? androidFixture('media-preview.vhdx')
            : fixtureSetting('VHDX_MEDIA_FIXTURE')!,
      });
      await backend.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
      for (var attempt = 0; attempt < 2; attempt++) {
        final source = await openPreview(tester, backend, '/sample.mp4');
        await waitFor(tester, () => source.position.inMilliseconds > 500);
        final native = source.player.platform as NativePlayer;
        // Inject the public-stream event produced by decoder error logs without
        // requiring a device-specific codec failure.
        // ignore: invalid_use_of_protected_member
        native.errorController.add(
          'Recoverable decoder initialization failure',
        );
        final before = source.position;
        await waitFor(
          tester,
          () => source.position > before + const Duration(milliseconds: 300),
        );
        expect(source.error, isNull);
        expect(find.textContaining('无法播放'), findsNothing);
        await source.toggle();
        await waitFor(tester, () => !source.playing);
        // ignore: invalid_use_of_protected_member
        native.errorController.add(
          'Recoverable decoder diagnostic while paused',
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(source.error, isNull);
        expect(find.textContaining('无法播放'), findsNothing);
        // Normal EOF must not turn earlier decoder diagnostics into failure.
        await source.seek(source.duration - const Duration(milliseconds: 300));
        await source.toggle();
        await waitFor(tester, () => source.player.state.completed);
        await tester.pump(const Duration(milliseconds: 300));
        expect(source.error, isNull);
        await closePreview(tester, source);

        final broken = await openPreview(tester, backend, '/broken.mp4');
        await waitFor(tester, () => broken.error != null);
        expect(find.textContaining('无法播放此文件'), findsOneWidget);
        expect(broken.buffering, isFalse);
        expect(broken.playing, isFalse);
        await closePreview(tester, broken);
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('BitLocker AVI and MKV decode without a false failure overlay', (
    tester,
  ) async {
    String sample(String name) => Platform.isAndroid
        ? androidFixture(name)
        : '${fixtureSetting('VHDX_SAMPLE_DIR')!}${Platform.pathSeparator}$name';
    final backend = await NativeBackend.start();
    addTearDown(backend.dispose);
    await backend.request({'op': 'open', 'path': sample('bitlockervhdx.vhdx')});
    await backend.request({
      'op': 'unlock',
      'partition': 1,
      'mode': 'password',
      'credential_file': sample('password.txt'),
    });
    for (final path in ['/video/avi.avi', '/video/mkv.mkv']) {
      final source = await openPreview(tester, backend, path);
      final diagnostics = <String>[];
      final subscription = source.player.stream.error.listen(diagnostics.add);
      addTearDown(subscription.cancel);
      await waitFor(tester, () => source.position.inMilliseconds > 1000);
      await source.controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 15),
      );
      expect(source.player.state.width, greaterThan(0));
      expect(source.player.state.height, greaterThan(0));
      expect(source.error, isNull, reason: path);
      expect(find.textContaining('无法播放'), findsNothing);
      debugPrint(
        'BitLocker $path: decoded ${source.player.state.width}x${source.player.state.height}; decoder diagnostics: $diagnostics',
      );
      await source.toggle();
      await waitFor(tester, () => !source.playing);
      expect(source.error, isNull);
      await subscription.cancel();
      await closePreview(tester, source);
    }
    expect(tester.takeException(), isNull);
  });
}
