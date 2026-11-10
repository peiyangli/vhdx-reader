import '../test/ui_actions.dart';
import 'test_configuration.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/playback_buffer_settings.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/media_preview.dart';
import 'package:vhdx_reader/preview.dart';
import 'package:vhdx_reader/screen_layout.dart';

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 250; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  fail('Timed out waiting for video state');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real H264/AAC fullscreen playback seeks; controls toggle; swipe exit revokes',
    (tester) async {
      final fixture = fixtureSetting('VHDX_MEDIA_FIXTURE');
      expect(fixture, isNotNull);
      final settingsDirectory = await Directory.systemTemp.createTemp(
        'playback-settings-',
      );
      addTearDown(() => settingsDirectory.delete(recursive: true));
      final settingsStore = CacheSettingsStore(directory: settingsDirectory);
      await settingsStore.save(
        const CacheSettings(
          playback: PlaybackBufferSettings(
            forwardMiB: 32,
            readAheadSeconds: 15,
            resumeSeconds: 1,
          ),
        ),
      );
      final backend = await NativeBackend.start();
      final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          cacheSettings: await settingsStore.load(),
          initialImage: fixture,
          pickImages: () async => [
            '$root${Platform.pathSeparator}basicvhdx.vhdx',
          ],
        ),
      );
      await tester.pumpAndSettle();
      await browserAction(tester, 'sort-name');
      await browserAction(tester, 'order-ascending');
      await tester.tap(find.text('sample.mp4'));
      await waitFor(
        tester,
        () => find.byType(MediaPreview).evaluate().isNotEmpty,
      );
      var source = tester
          .widget<MediaPreview>(find.byType(MediaPreview))
          .source;
      // Keep automated tests quiet; the fixture contains a real AAC tone track.
      await source.setVolume(0);
      await waitFor(
        tester,
        () =>
            source.position.inMilliseconds > 500 &&
            source.duration.inSeconds >= 30,
      );
      expect(source.error, isNull);
      final native = source.player.platform as NativePlayer;
      expect(await native.getProperty('cache-on-disk'), 'no');
      expect(
        int.parse(await native.getProperty('demuxer-max-bytes')),
        32 * 1024 * 1024,
      );
      expect(double.parse(await native.getProperty('cache-secs')), 15);
      expect(double.parse(await native.getProperty('cache-pause-wait')), 1);
      expect(await native.getProperty('cache-pause-initial'), 'yes');
      if (Platform.isIOS) {
        expect(source.audioOutputAvailable, isFalse);
        expect(await native.getProperty('current-ao'), 'null');
      }
      expect(source.player.state.width, 640);
      final stats = await source.statistics();
      expect(stats['transport'], 'native');
      expect(stats['bytes'] as int, greaterThan(0));
      // The larger packet cache can hold this entire small fixture. A seek
      // may therefore be served without a new underlying byte-range request.
      await source.seek(const Duration(seconds: 16));
      await waitFor(
        tester,
        () => source.position.inMilliseconds > 17000 && !source.buffering,
      );
      expect(source.error, isNull);
      await tester.tap(find.byKey(const Key('media-play')));
      await waitFor(tester, () => !source.playing);
      final seek = tester.getRect(find.byKey(const Key('media-seek')));
      await tester.tapAt(Offset(seek.left + seek.width * 0.84, seek.center.dy));
      await waitFor(tester, () => source.position.inSeconds >= 25);
      final screenshotPath = fixtureSetting('VHDX_MEDIA_SCREENSHOT');
      if (screenshotPath != null) {
        final png = await source.player.screenshot(format: 'image/png');
        expect(png, isNotNull);
        await File(screenshotPath).writeAsBytes(png!);
      }
      expect(
        find.byKey(const Key('disk-navigation')).hitTestable(),
        findsNothing,
      );
      expect(find.byKey(const Key('media-fullscreen')), findsNothing);
      expect(find.byKey(const Key('media-volume')), findsNothing);
      final surface = find.byKey(const Key('media-surface'));
      await tester.tapAt(tester.getCenter(surface));
      // A single tap waits for the double-tap zoom recognition window.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-play')).hitTestable(), findsNothing);
      await tester.tapAt(tester.getCenter(surface));
      // A single tap waits for the double-tap zoom recognition window.
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-play')).hitTestable(), findsOneWidget);
      await source.player.setRate(1.25);
      final hold = await tester.startGesture(tester.getCenter(surface));
      await tester.pump(const Duration(milliseconds: 650));
      await waitFor(
        tester,
        () => source.player.state.rate == 2 && source.playing,
      );
      await hold.up();
      await waitFor(
        tester,
        () => source.player.state.rate == 1.25 && !source.playing,
      );
      await source.player.setRate(1);
      await source.seek(const Duration(seconds: 5));
      await source.toggle();
      await waitFor(tester, () => source.playing);
      final pull = await tester.startGesture(tester.getCenter(surface));
      await pull.moveBy(const Offset(0, 24));
      await pull.moveBy(const Offset(0, 45));
      await waitFor(tester, () => !source.playing);
      await tester.pump();
      expect(
        tester
            .widget<Opacity>(find.byKey(const Key('video-dismiss-opacity')))
            .opacity,
        lessThan(1),
      );
      expect(
        tester
            .widget<Transform>(find.byKey(const Key('video-dismiss-frame')))
            .transform
            .getTranslation()
            .y,
        greaterThan(0),
      );
      await pull.cancel();
      await tester.pumpAndSettle();
      await waitFor(tester, () => source.playing);
      if (Platform.isIOS) {
        final original = await ScreenDirection.load();
        addTearDown(() => original.save());
        for (final direction in [
          ScreenDirection.landscape,
          ScreenDirection.portrait,
        ]) {
          await direction.save();
          await waitFor(
            tester,
            () =>
                (tester.view.physicalSize.width >
                    tester.view.physicalSize.height) ==
                (direction == ScreenDirection.landscape),
          );
          expect(await ScreenDirection.load(), direction);
          expect(
            tester.widget<MediaPreview>(find.byType(MediaPreview)).source,
            same(source),
          );
        }
      }
      await tester.dragFrom(tester.getCenter(surface), const Offset(-150, 0));
      await tester.pump();
      expect(find.text('已经是最后一个视频'), findsOneWidget);
      final previous = source;
      await tester.dragFrom(tester.getCenter(surface), const Offset(150, 0));
      await waitFor(
        tester,
        () =>
            tester.widget<PreviewPane>(find.byType(PreviewPane)).data!.name ==
            'broken.mp4',
      );
      await expectLater(previous.statistics(), throwsA(isA<ReaderFailure>()));
      await tester.dragFrom(tester.getCenter(surface), const Offset(-150, 0));
      await waitFor(
        tester,
        () =>
            tester.widget<PreviewPane>(find.byType(PreviewPane)).data!.name ==
            'sample.mp4',
      );
      source = tester.widget<MediaPreview>(find.byType(MediaPreview)).source;
      await waitFor(tester, () => source.duration.inSeconds >= 30);
      expect(source.volume, 0);
      expect(source.player.state.rate, 1);
      final rect = tester.getRect(surface);
      await tester.dragFrom(
        Offset(rect.center.dx, rect.top + rect.height * 0.25),
        const Offset(0, 200),
      );
      await tester.pumpAndSettle();
      await expectLater(source.statistics(), throwsA(isA<ReaderFailure>()));
      await tester.ensureVisible(find.text('broken.mp4'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('broken.mp4'));
      await waitFor(
        tester,
        () =>
            find.textContaining('无法播放').evaluate().isNotEmpty ||
            find.textContaining('无法启动播放器').evaluate().isNotEmpty,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await browserAction(tester, 'open-image');
      await tester.pumpAndSettle();
      await switchImage(tester, 0);
      await browserAction(tester, 'close-image');
      await tester.pumpAndSettle();
      expect(find.text('can.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
