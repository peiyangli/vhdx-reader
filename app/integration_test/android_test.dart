import 'dart:convert';
import 'dart:math' as math;
import '../test/ui_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vhdx_reader/screen_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/preview.dart';
import 'package:vhdx_reader/platform_storage.dart';
import 'package:vhdx_reader/range_reader.dart';
import 'package:vhdx_reader/media_preview.dart';
import 'package:pdfrx/pdfrx.dart';

String fixture(String name) =>
    'content://org.vhdxreader.vhdx_reader.uitest.fixtures/$name';
Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (ready()) return;
  }
  fail('Timed out waiting for Android reader');
}

List<List<num>> shakeTrace(int target, {bool single = false}) {
  final duration = single ? 400 : 1000;
  return [
    for (var t = 0; t <= 1600 + duration; t += 20)
      [
        t,
        (target == 1
                ? 9.81
                : target == 3
                ? -9.81
                : 0.0) +
            (target.isEven && t >= 800 && t < 800 + duration
                ? 8 * math.sin(2 * math.pi * 2.5 * (t - 800) / 1000)
                : 0),
        (target == 0
                ? 9.81
                : target == 2
                ? -9.81
                : 0.0) +
            (target.isOdd && t >= 800 && t < 800 + duration
                ? 8 * math.sin(2 * math.pi * 2.5 * (t - 800) / 1000)
                : 0),
        0.0,
      ],
  ];
}

Future<int> feedShake(int target, {bool single = false}) async =>
    await PlatformStorage.channel.invokeMethod<int>('debugShakeSamples', {
      'samples': shakeTrace(target, single: single),
    }) ??
    0;
Future<int> rotation() async =>
    await PlatformStorage.channel.invokeMethod<int>('debugRotation') ?? 0;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android shake detector rejects noise and confirms stable target',
    (tester) async {
      final checks = await PlatformStorage.channel.invokeListMethod<String>(
        'debugShakeChecks',
      );
      expect(checks, hasLength(6));
    },
  );
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
      await waitFor(
        tester,
        () => find.text('sample.mp4').evaluate().isNotEmpty,
      );
      expect(find.byTooltip('展示'), findsOneWidget);
      expect(find.byKey(const Key('disk-navigation')), findsOneWidget);
      expect(find.byKey(const Key('browser-menu')), findsNothing);
      expect(find.byKey(const Key('image-switcher')), findsNothing);
      expect(find.byTooltip('关闭窗口'), findsNothing);
      expect(find.text('修改日期'), findsNothing);
      await browserAction(tester, 'view-grid');
      await browserAction(tester, 'sort-modified');
      await browserAction(tester, 'order-descending');
      final contents = tester.widget<FileContents>(find.byType(FileContents));
      expect(contents.grid, true);
      expect(contents.sort, FileSort.modified);
      expect(contents.descending, true);
      await browserAction(tester, 'view-list');
      await browserAction(tester, 'show-system');
      await browserAction(tester, 'show-system');
      await tester.drag(find.byType(ListView).first, const Offset(0, 400));
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
      // Hold temporarily plays at 2x and restores an arbitrary previous rate.
      if (source.playing) await source.toggle();
      await waitFor(tester, () => !source.playing);
      await source.player.setRate(1.25);
      await waitFor(tester, () => source.player.state.rate == 1.25);
      final hold = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('media-surface'))),
      );
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
      await source.toggle();
      await waitFor(tester, () => source.playing);
      final cancelled = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('media-surface'))),
      );
      await tester.pump(const Duration(milliseconds: 650));
      await waitFor(tester, () => source.player.state.rate == 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await waitFor(
        tester,
        () => source.player.state.rate == 1 && !source.playing,
      );
      await cancelled.cancel();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(source.playing, false);
      await source.toggle();
      await source.seek(const Duration(seconds: 26));
      await waitFor(tester, () => source.position.inSeconds >= 25);
      expect((await source.statistics())['ranges'] as int, greaterThan(1));
      final originalDirection = await ScreenDirection.load();
      addTearDown(() => originalDirection.save());
      final priorShake = await ShakeRotation.load();
      addTearDown(() => ShakeRotation.save(priorShake['enabled'] == true));
      await ScreenDirection.automatic.save();
      await ShakeRotation.save(true);
      final videoTarget = ((await rotation()) + 1) % 4;
      expect(await feedShake(videoTarget), 1);
      await waitFor(
        tester,
        () =>
            (tester.view.physicalSize.width >
                tester.view.physicalSize.height) ==
            videoTarget.isOdd,
      );
      expect(await rotation(), videoTarget);
      expect(
        tester.widget<MediaPreview>(find.byType(MediaPreview)).source,
        same(source),
      );
      expect(source.volume, 0);
      expect(source.player.state.rate, 1);
      await ShakeRotation.save(false);

      await ScreenDirection.portrait.save();
      await waitFor(
        tester,
        () => tester.view.physicalSize.height > tester.view.physicalSize.width,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('disk-navigation')).hitTestable(),
        findsNothing,
      );
      expect(find.byKey(const Key('display-menu')).hitTestable(), findsNothing);
      expect(find.byKey(const Key('media-fullscreen')), findsNothing);
      expect(find.byKey(const Key('media-volume')), findsNothing);
      final surface = find.byKey(const Key('media-surface'));
      await tester.tapAt(tester.getCenter(surface));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-play')).hitTestable(), findsNothing);
      await tester.tapAt(tester.getCenter(surface));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-play')).hitTestable(), findsOneWidget);
      expect(
        tester.view.physicalSize.height,
        greaterThan(tester.view.physicalSize.width),
      );
      expect(await ScreenDirection.load(), ScreenDirection.portrait);
      // Ascending names: broken.mp4, sample.mp4. Do not wrap at the last item.
      await tester.dragFrom(tester.getCenter(surface), const Offset(-150, 0));
      await tester.pump();
      expect(find.text('已经是最后一个视频'), findsOneWidget);
      expect(
        tester.widget<MediaPreview>(find.byType(MediaPreview)).source,
        same(source),
      );
      final firstSource = source;
      await tester.dragFrom(tester.getCenter(surface), const Offset(150, 0));
      await waitFor(
        tester,
        () =>
            tester.widget<PreviewPane>(find.byType(PreviewPane)).data!.name ==
            'broken.mp4',
      );
      await tester.pumpAndSettle();
      await expectLater(
        firstSource.statistics(),
        throwsA(isA<ReaderFailure>()),
      );
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
      expect(
        find.byKey(const Key('disk-navigation')).hitTestable(),
        findsNothing,
      );
      // Pull keeps the native frame paused; a short pull/cancel restores state.
      await source.seek(const Duration(seconds: 5));
      if (!source.playing) await source.toggle();
      await waitFor(tester, () => source.playing);
      for (final initiallyPlaying in [true, false]) {
        if (source.playing != initiallyPlaying) await source.toggle();
        await waitFor(tester, () => source.playing == initiallyPlaying);
        final pull = await tester.startGesture(tester.getCenter(surface));
        await pull.moveBy(const Offset(0, 24));
        await pull.moveBy(const Offset(0, 45));
        await waitFor(tester, () => !source.playing);
        await tester.pump();
        expect(
          tester
              .widget<Transform>(find.byKey(const Key('video-dismiss-frame')))
              .transform
              .getTranslation()
              .y,
          greaterThan(0),
        );
        expect(
          tester
              .widget<Opacity>(find.byKey(const Key('video-dismiss-opacity')))
              .opacity,
          lessThan(1),
        );
        final frozen = source.position;
        await tester.pump(const Duration(milliseconds: 350));
        expect((source.position - frozen).inMilliseconds.abs(), lessThan(150));
        if (initiallyPlaying) {
          await pull.up();
        } else {
          await pull.cancel();
        }
        await tester.pumpAndSettle();
        await waitFor(tester, () => source.playing == initiallyPlaying);
        expect(
          tester
              .widget<Transform>(find.byKey(const Key('video-dismiss-frame')))
              .transform
              .getTranslation()
              .y,
          0,
        );
      }
      final rect = tester.getRect(surface);
      await tester.dragFrom(
        Offset(rect.center.dx, rect.top + rect.height * 0.25),
        const Offset(0, 200),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MediaPreview), findsNothing);
      expect(find.text('sample.mp4'), findsOneWidget);
      await expectLater(source.statistics(), throwsA(isA<ReaderFailure>()));
      await originalDirection.save();
      await openReaderSettings(tester);
      expect(find.byKey(const Key('reader-settings-page')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-back')));
      await tester.pumpAndSettle();
      await browserAction(tester, 'open-image');
      await waitFor(tester, () => find.text('can.txt').evaluate().isNotEmpty);
      await tester.tap(find.text('can.txt'));
      await tester.pumpAndSettle();
      expect(
        find.text(utf8.decode(base64Decode(text['bytes'] as String))),
        findsOneWidget,
      );
      expect(find.byType(Dialog), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PreviewPane), findsNothing);
      await switchImage(tester, 0);
      await waitFor(
        tester,
        () => find.text('sample.mp4').evaluate().isNotEmpty,
      );
      for (var attempt = 0; attempt < 3; attempt++) {
        await tester.tap(find.text('sample.mp4'));
        await waitFor(
          tester,
          () => find.byType(MediaPreview).evaluate().isNotEmpty,
        );
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('sample.mp4'), findsOneWidget);
        expect(find.byType(MediaPreview), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(
        await PlatformStorage.channel.invokeMethod<int>('debugDescriptorCount'),
        0,
      );
    },
  );
  testWidgets(
    'Android orientation persists; rotation retains directory, view and text preview',
    (tester) async {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      final original = await ScreenDirection.load();
      addTearDown(() => original.save());
      final backend = await NativeBackend.start();
      await tester.pumpWidget(
        ReaderApp(backend: backend, initialImage: fixture('basicvhdx.vhdx')),
      );
      await waitFor(tester, () => find.text('can.txt').evaluate().isNotEmpty);
      await browserAction(tester, 'sort-size');
      await browserAction(tester, 'order-descending');
      for (final direction in [
        ScreenDirection.landscape,
        ScreenDirection.portrait,
        ScreenDirection.automatic,
      ]) {
        await openReaderSettings(tester);
        await tester.tap(find.byKey(const Key('screen-direction')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('direction-${direction.name}')));
        await tester.pumpAndSettle();
        await waitFor(tester, () {
          final size = tester.view.physicalSize;
          return direction == ScreenDirection.automatic ||
              (direction == ScreenDirection.landscape
                  ? size.width > size.height
                  : size.height > size.width);
        });
        expect(await ScreenDirection.load(), direction);
        expect(find.text(direction.label), findsOneWidget);
        await tester.tap(find.byKey(const Key('settings-back')));
        await tester.pumpAndSettle();
        final contents = tester.widget<FileContents>(find.byType(FileContents));
        expect(contents.sort, FileSort.size);
        expect(contents.descending, true);
        expect(find.text('can.txt'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('can.txt'));
      await waitFor(
        tester,
        () => find.byType(PreviewPane).evaluate().isNotEmpty,
      );
      final state = tester.state(find.byType(PreviewPane));
      final originalShake = await ShakeRotation.load();
      addTearDown(() => ShakeRotation.save(originalShake['enabled'] == true));
      await ScreenDirection.automatic.save();
      await ShakeRotation.save(true);
      expect((await ShakeRotation.load())['enabled'], true);
      var target = ((await rotation()) + 1) % 4;
      expect(await feedShake(target, single: true), 0);
      expect(await feedShake(target), 1);
      await waitFor(
        tester,
        () =>
            (tester.view.physicalSize.width >
                tester.view.physicalSize.height) ==
            target.isOdd,
      );
      expect(await rotation(), target);
      expect(tester.state(find.byType(PreviewPane)), same(state));
      target = (target + 1) % 4;
      expect(await feedShake(target), 1);
      await waitFor(
        tester,
        () =>
            (tester.view.physicalSize.width >
                tester.view.physicalSize.height) ==
            target.isOdd,
      );
      expect(await rotation(), target);
      await ShakeRotation.save(false);
      expect(await feedShake((target + 1) % 4), 0);
      await ScreenDirection.portrait.save();
      await ShakeRotation.save(true);
      expect(await feedShake(1), 0);
      await ShakeRotation.save(false);

      await ScreenDirection.landscape.save();
      await waitFor(
        tester,
        () => tester.view.physicalSize.width > tester.view.physicalSize.height,
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(PreviewPane)), same(state));
      await ScreenDirection.portrait.save();
      await waitFor(
        tester,
        () => tester.view.physicalSize.width < tester.view.physicalSize.height,
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(PreviewPane)), same(state));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
