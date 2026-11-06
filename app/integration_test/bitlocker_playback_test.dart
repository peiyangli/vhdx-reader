import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/media_preview.dart';
import 'package:vhdx_reader/playback_controls.dart';
import 'package:vhdx_reader/preview.dart';
import 'package:vhdx_reader/thumbnails.dart';
import 'bitlocker_thumbnails_test.dart' show FixtureBackend;
import 'test_configuration.dart';
import '../test/ui_actions.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('BitLocker browser plays and mouse-swipes through real videos', (
    tester,
  ) async {
    final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
    final backend = FixtureBackend(await NativeBackend.start(), root);
    Future<void> until(bool Function() ready, String stage) async {
      final clock = Stopwatch()..start();
      while (clock.elapsed < const Duration(seconds: 12)) {
        await tester.pump(const Duration(milliseconds: 100));
        if (ready()) return;
      }
      if (find.byType(MediaPreview).evaluate().isNotEmpty) {
        final p = tester.widget<MediaPreview>(find.byType(MediaPreview));
        final controls = tester.widget<PlaybackControls>(
          find.byType(PlaybackControls),
        );
        debugPrint(
          'STUCK $stage lifecycle=${binding.lifecycleState} active=${p.active} switching=${p.switching} enabled=${controls.enabled} playing=${p.source.playing} position=${p.source.position} duration=${p.source.duration} error=${p.source.error}',
        );
      }
      fail('Timed out: $stage');
    }

    try {
      await tester.pumpWidget(
        ReaderApp(backend: backend, initialImage: '$root/bitlockervhdx.vhdx'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('unlock-secret')), 'fixture');
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('video'));
      await tester.pumpAndSettle();
      await browserAction(tester, 'sort-name');
      await browserAction(tester, 'order-ascending');
      await until(
        () =>
            find
                .descendant(
                  of: find.byType(FileThumbnail),
                  matching: find.byType(RawImage),
                )
                .evaluate()
                .length ==
            5,
        'thumbnails',
      );
      await browserAction(tester, 'view-grid');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      await tester.tap(find.text('asf.asf'));
      await until(
        () => find.byType(MediaPreview).evaluate().isNotEmpty,
        'first preview',
      );
      for (final name in [
        'asf.asf',
        'avi.avi',
        'flv.flv',
        'mkv.mkv',
        'mp4.1.mp4',
      ]) {
        await until(
          () =>
              tester.widget<PreviewPane>(find.byType(PreviewPane)).data!.name ==
              name,
          'switch to $name',
        );
        final p = tester.widget<MediaPreview>(find.byType(MediaPreview));
        await p.source.setVolume(0);
        debugPrint(
          'OPEN $name lifecycle=${binding.lifecycleState} active=${p.active} switching=${p.switching}',
        );
        await until(
          () => p.source.position.inMilliseconds > 300,
          'playing $name',
        );
        expect(p.source.error, isNull);
        expect(
          tester
              .widget<PlaybackControls>(find.byType(PlaybackControls))
              .enabled,
          true,
        );
        debugPrint('PLAYING $name ${p.source.position}');
        if (name == 'avi.avi') {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pump();
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          await tester.pump();
          final before = p.source.position;
          await until(
            () =>
                p.source.position > before + const Duration(milliseconds: 400),
            'keeps playing without focus',
          );
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await until(() => !p.source.playing, 'space pauses');
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await until(
            () => p.source.position >= before + const Duration(seconds: 4),
            'right seeks',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await until(() => p.source.playing, 'space resumes');
          Future<void> windowEvent(String method) async {
            await binding.defaultBinaryMessenger.handlePlatformMessage(
              'vhdx_reader/window',
              const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
              (_) {},
            );
            await tester.pump();
          }

          await windowEvent('hidden');
          await until(() => !p.source.playing, 'close to tray pauses');
          await windowEvent('shown');
          await tester.pump(const Duration(milliseconds: 400));
          expect(p.source.playing, false);
          await tester.tap(find.byKey(const Key('media-play')));
          await until(
            () => p.source.playing,
            'restored playback resumes on request',
          );
        }
        if (name != 'mp4.1.mp4') {
          await tester.dragFrom(
            tester.getCenter(find.byKey(const Key('media-surface'))),
            const Offset(-180, 0),
            kind: PointerDeviceKind.mouse,
          );
        }
      }
      await tester.dragFrom(
        tester.getCenter(find.byKey(const Key('media-surface'))),
        const Offset(180, 0),
        kind: PointerDeviceKind.mouse,
      );
      await until(
        () =>
            tester.widget<PreviewPane>(find.byType(PreviewPane)).data!.name ==
            'mkv.mkv',
        'previous',
      );
      await tester.dragFrom(
        tester.getCenter(find.byKey(const Key('media-surface'))),
        const Offset(0, 220),
        kind: PointerDeviceKind.mouse,
      );
      await until(
        () => find.byType(MediaPreview).evaluate().isEmpty,
        'pull to list',
      );
      expect(find.text('asf.asf'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  });
}
