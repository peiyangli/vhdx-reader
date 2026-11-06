import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/playback_controls.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    VoidCallback? exit,
    VoidCallback? play,
    VoidCallback? mute,
    VoidCallback? next,
    VoidCallback? previous,
    VoidCallback? holdStart,
    VoidCallback? holdEnd,
    bool enabled = true,
    int seekSeconds = 5,
    ValueChanged<Duration>? seek,
    Duration duration = const Duration(seconds: 60),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: PlaybackControls(
            position: const Duration(seconds: 10),
            duration: duration,
            playing: true,
            muted: false,
            onPlay: play ?? () {},
            onMute: mute ?? () {},
            onSeek: seek ?? (_) {},
            onExit: exit ?? () {},
            onNext: next,
            onPrevious: previous,
            onHoldStart: holdStart,
            onHoldEnd: holdEnd,
            enabled: enabled,
            seekSeconds: seekSeconds,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'only three controls, transparent panel and tap toggles without pausing',
    (tester) async {
      var plays = 0;
      await show(tester, play: () => plays++);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(IconButton), findsNWidgets(2));
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byKey(const Key('media-controls')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.type, MaterialType.transparency);
      final surface = find.byKey(const Key('media-surface'));
      await tester.tapAt(tester.getCenter(surface));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-play')).hitTestable(), findsNothing);
      expect(plays, 0);
      await tester.tapAt(tester.getCenter(surface));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-play')).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const Key('media-play')));
      await tester.pumpAndSettle();
      expect(plays, 1);
      expect(find.byKey(const Key('media-play')).hitTestable(), findsOneWidget);
    },
  );

  testWidgets('seek and mute do not dismiss or hide controls', (tester) async {
    var exits = 0;
    var mutes = 0;
    Duration? target;
    await show(
      tester,
      exit: () => exits++,
      mute: () => mutes++,
      seek: (v) => target = v,
    );
    await tester.tap(find.byKey(const Key('media-mute')));
    expect(mutes, 1);
    final rect = tester.getRect(find.byKey(const Key('media-seek')));
    await tester.dragFrom(
      Offset(rect.left + rect.width * 0.2, rect.center.dy),
      Offset(rect.width * 0.5, 4),
    );
    await tester.pumpAndSettle();
    expect(target!.inSeconds, greaterThan(30));
    expect(exits, 0);
    expect(find.byKey(const Key('media-play')).hitTestable(), findsOneWidget);
    await tester.dragFrom(rect.center, const Offset(0, -130));
    expect(exits, 0);
  });

  testWidgets(
    'swipe down exits even when hidden; upward and short drags do not',
    (tester) async {
      var exits = 0;
      await show(tester, exit: () => exits++);
      final surface = find.byKey(const Key('media-surface'));
      final start = tester.getCenter(surface);
      await tester.dragFrom(start, const Offset(0, -150));
      await tester.dragFrom(start, const Offset(0, 12));
      expect(exits, 0);
      await tester.tapAt(start);
      await tester.pumpAndSettle();
      await tester.dragFrom(start, const Offset(0, 150));
      expect(exits, 1);
    },
  );

  testWidgets('space plays and escape exits; unknown duration cannot seek', (
    tester,
  ) async {
    var plays = 0;
    var exits = 0;
    await show(
      tester,
      play: () => plays++,
      exit: () => exits++,
      duration: Duration.zero,
    );
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(plays, 1);
    expect(exits, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'left/right switch once; seek and vertical exit stay independent',
    (tester) async {
      var next = 0, previous = 0, exits = 0;
      await show(
        tester,
        next: () => next++,
        previous: () => previous++,
        exit: () => exits++,
      );
      final center = tester.getCenter(find.byKey(const Key('media-surface')));
      await tester.dragFrom(center, const Offset(-150, 3));
      await tester.dragFrom(center, const Offset(150, 3));
      expect([next, previous, exits], [1, 1, 0]);
      final seek = tester.getRect(find.byKey(const Key('media-seek')));
      await tester.dragFrom(seek.center, const Offset(150, 0));
      expect([next, previous, exits], [1, 1, 0]);
      await tester.dragFrom(center, const Offset(0, 150));
      expect(exits, 1);
    },
  );

  testWidgets('boundaries show a temporary message without wrapping', (
    tester,
  ) async {
    await show(tester);
    final center = tester.getCenter(find.byKey(const Key('media-surface')));
    await tester.dragFrom(center, const Offset(-150, 0));
    await tester.pump();
    expect(find.text('已经是最后一个视频'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('media-gesture-notice')), findsNothing);
    await tester.dragFrom(center, const Offset(150, 0));
    await tester.pump();
    expect(find.text('已经是第一个视频'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets(
    'hold starts after long press and restores exactly once on up/cancel',
    (tester) async {
      var starts = 0, ends = 0, next = 0;
      await show(
        tester,
        holdStart: () => starts++,
        holdEnd: () => ends++,
        next: () => next++,
      );
      final center = tester.getCenter(find.byKey(const Key('media-surface')));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(starts, 0);
      for (final cancel in [false, true]) {
        final gesture = await tester.startGesture(center);
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('2 倍速播放'), findsOneWidget);
        await gesture.moveBy(const Offset(-180, 0));
        expect(next, 0);
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pumpAndSettle();
        expect(find.text('2 倍速播放'), findsNothing);
      }
      expect(starts, 2);
      expect(ends, 2);
    },
  );

  testWidgets(
    'disabling or disposing controls ends hold; disabled swipes cannot switch',
    (tester) async {
      var starts = 0, ends = 0, next = 0;
      await show(
        tester,
        holdStart: () => starts++,
        holdEnd: () => ends++,
        next: () => next++,
      );
      final center = tester.getCenter(find.byKey(const Key('media-surface')));
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 600));
      await show(
        tester,
        enabled: false,
        holdStart: () => starts++,
        holdEnd: () => ends++,
        next: () => next++,
      );
      expect(ends, 1);
      await gesture.cancel();
      await tester.dragFrom(center, const Offset(-150, 0));
      expect(next, 0);
      await show(tester, holdStart: () => starts++, holdEnd: () => ends++);
      final again = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpWidget(const SizedBox());
      await again.cancel();
      expect(starts, 2);
      expect(ends, 2);
    },
  );
  testWidgets('desktop mouse hold and page keys retain the compact controls', (
    tester,
  ) async {
    var starts = 0, ends = 0, next = 0, previous = 0;
    await show(
      tester,
      holdStart: () => starts++,
      holdEnd: () => ends++,
      next: () => next++,
      previous: () => previous++,
    );
    final mouse = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('media-surface'))),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(starts, 1);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(ends, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect([previous, next], [1, 1]);
  });
  testWidgets(
    'arrows seek configured seconds, clamp bounds and respect disabled state',
    (tester) async {
      final targets = <Duration>[];
      var mutes = 0;
      await show(
        tester,
        seekSeconds: 15,
        seek: targets.add,
        mute: () => mutes++,
        duration: const Duration(seconds: 20),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      expect(targets, [Duration.zero, const Duration(seconds: 20)]);
      expect(mutes, 1);
      await show(
        tester,
        enabled: false,
        seek: targets.add,
        mute: () => mutes++,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      expect(targets.length, 2);
      expect(mutes, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'desktop shortcuts override focused controls but not dialog input',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var plays = 0, mutes = 0;
      final seeks = <Duration>[];
      await show(
        tester,
        play: () => plays++,
        mute: () => mutes++,
        seek: seeks.add,
        seekSeconds: 15,
      );
      Focus.of(tester.element(find.byIcon(Icons.volume_up))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(plays, 1);
      expect(mutes, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(mutes, 1);
      final sliderFocus = find
          .descendant(
            of: find.byType(Slider),
            matching: find.byType(FocusableActionDetector),
          )
          .first;
      tester
          .widget<FocusableActionDetector>(sliderFocus)
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(seeks, [const Duration(seconds: 25)]);
      final context = tester.element(find.byType(PlaybackControls));
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: TextField(autofocus: true)),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect(plays, 1);
      expect(seeks.length, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
