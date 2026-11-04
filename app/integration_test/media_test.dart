import 'test_configuration.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/media_preview.dart';

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
    'real H264/AAC video plays and seeks through Rust ranges; tabs pause; close revokes',
    (tester) async {
      final fixture = fixtureSetting('VHDX_MEDIA_FIXTURE');
      expect(fixture, isNotNull);
      final backend = await NativeBackend.start();
      final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: fixture,
          pickImages: () async => [
            '$root${Platform.pathSeparator}basicvhdx.vhdx',
          ],
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
      if (Platform.isIOS) {
        expect(source.audioOutputAvailable, isFalse);
        expect(await native.getProperty('current-ao'), 'null');
      }
      expect(source.player.state.width, 640);
      final stats = await source.statistics();
      expect(stats['bytes'] as int, lessThan(8 * 1024 * 1024));
      await tester.tap(find.byKey(const Key('media-play')));
      await waitFor(tester, () => !source.playing);
      final seek = tester.getRect(find.byKey(const Key('media-seek')));
      await tester.tapAt(Offset(seek.left + seek.width * 0.84, seek.center.dy));
      await waitFor(tester, () => source.position.inSeconds >= 25);
      expect(
        (await source.statistics())['ranges'] as int,
        greaterThan(stats['ranges'] as int),
      );
      final screenshotPath = fixtureSetting('VHDX_MEDIA_SCREENSHOT');
      if (screenshotPath != null) {
        final png = await source.player.screenshot(format: 'image/png');
        expect(png, isNotNull);
        await File(screenshotPath).writeAsBytes(png!);
      }
      await tester.tap(find.byKey(const Key('media-fullscreen')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      await tester.tap(find.byTooltip('退出全屏'));
      await tester.pumpAndSettle();
      await source.toggle();
      await waitFor(tester, () => source.playing);
      await tester.tap(find.byTooltip('添加镜像（可多选）'));
      await waitFor(
        tester,
        () => find.text('can.txt').evaluate().isNotEmpty && !source.playing,
      );
      final position = source.position;
      await tester.tap(find.byKey(const ValueKey('image-tab-0')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(source.playing, isFalse);
      expect((source.position - position).inMilliseconds.abs(), lessThan(500));
      await tester.tap(find.text('返回文件列表'));
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
      await tester.tap(find.byKey(const ValueKey('close-tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('can.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
