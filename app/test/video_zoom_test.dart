import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/playback_controls.dart';
import 'package:vhdx_reader/video_dismiss_view.dart';
import 'package:vhdx_reader/video_zoom.dart';

void main() {
  late VideoZoomController zoom;
  var exits = 0, switches = 0, holds = 0, pulls = 0, plays = 0, rates = 0;
  final seeks = <Duration>[];

  setUp(() {
    zoom = VideoZoomController();
    exits = switches = holds = pulls = plays = rates = 0;
    seeks.clear();
  });
  tearDown(() => zoom.dispose());

  Future<void> show(
    WidgetTester tester, {
    bool enabled = true,
    double? ratio,
  }) async {
    if (!enabled) zoom.reset();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoZoomView(
            controller: zoom,
            aspectRatio: ratio,
            child: const ColoredBox(color: Colors.blue),
            builder: (context, frame) => VideoDismissView(
              enabled: enabled && !zoom.active,
              onStart: () => pulls++,
              onCancel: () {},
              onDismiss: () => exits++,
              child: frame,
              controls: (update, end, cancel, pulling) => PlaybackControls(
                zoom: zoom,
                enabled: enabled,
                position: const Duration(seconds: 10),
                duration: const Duration(seconds: 60),
                playing: true,
                muted: false,
                onPlay: () => plays++,
                onMute: () {},
                onCycleRate: () => rates++,
                onSeek: seeks.add,
                onExit: () => exits++,
                onNext: () => switches++,
                onPrevious: () => switches++,
                onHoldStart: () => holds++,
                onHoldEnd: () {},
                onPullUpdate: update,
                onPullEnd: end,
                onPullCancel: cancel,
                pulling: pulling,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> doubleTap(
    WidgetTester tester,
    Offset point, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) async {
    await tester.tapAt(point, kind: kind);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(point, kind: kind);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'double tap anchors 2x at the tapped pixel, keeps controls fixed and restores',
    (tester) async {
      await show(tester);
      final controls = tester.getRect(find.byKey(const Key('media-controls')));
      const point = Offset(220, 180);
      await doubleTap(tester, point);
      expect(zoom.scale, 2);
      expect(zoom.offset + point * zoom.scale, point);
      final transform = tester
          .widget<Transform>(find.byKey(const Key('video-zoom-frame')))
          .transform;
      expect(transform.getMaxScaleOnAxis(), 2);
      expect(transform.getTranslation().x, -point.dx);
      expect(tester.getRect(find.byKey(const Key('media-controls'))), controls);
      expect(find.byKey(const Key('media-play')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('media-zoom-notice')), findsOneWidget);
      await doubleTap(tester, point);
      expect(zoom.active, isFalse);
      expect(zoom.scale, 1);
      expect(zoom.offset, Offset.zero);
      expect([exits, switches, holds, pulls, plays], [0, 0, 0, 0, 0]);
    },
  );

  testWidgets(
    'zoom owns dragging in every direction and holding never starts boost',
    (tester) async {
      await show(tester);
      await doubleTap(tester, const Offset(400, 250));
      final initial = zoom.offset;
      final finger = await tester.startGesture(const Offset(400, 250));
      await tester.pump(const Duration(milliseconds: 700));
      await finger.moveBy(const Offset(40, 40));
      await finger.moveBy(const Offset(90, 90));
      await tester.pump();
      expect(zoom.offset.dx, greaterThan(initial.dx));
      expect(zoom.offset.dy, greaterThan(initial.dy));
      await finger.up();
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(400, 250), const Offset(-200, -100));
      await tester.pumpAndSettle();
      expect([exits, switches, holds, pulls], [0, 0, 0, 0]);
      expect(zoom.active, isTrue);
    },
  );

  testWidgets(
    'pinch enlarges, caps at 4x and changing finger count does not jump',
    (tester) async {
      await show(tester);
      await doubleTap(tester, const Offset(400, 250));
      final left = await tester.startGesture(
        const Offset(300, 250),
        pointer: 1,
      );
      final right = await tester.startGesture(
        const Offset(500, 250),
        pointer: 2,
      );
      await left.moveTo(const Offset(270, 250));
      await right.moveTo(const Offset(530, 250));
      await left.moveTo(const Offset(220, 250));
      await right.moveTo(const Offset(580, 250));
      await tester.pump();
      expect(zoom.scale, greaterThan(2));
      await left.moveTo(const Offset(50, 250));
      await right.moveTo(const Offset(750, 250));
      await tester.pump();
      expect(zoom.scale, 4);
      final offset = zoom.offset;
      await right.up();
      await tester.pump();
      expect(zoom.offset, offset);
      await left.moveBy(const Offset(1, 0));
      await tester.pump();
      expect((zoom.offset - offset).distance, lessThanOrEqualTo(1.01));
      await left.moveBy(const Offset(30, 20));
      await tester.pump();
      expect(zoom.offset.dx, greaterThan(offset.dx));
      await left.up();
      await tester.pumpAndSettle();
      expect([switches, pulls, exits, holds], [0, 0, 0, 0]);
    },
  );

  testWidgets(
    'pinch below 1x consumes remaining fingers before restoring normal swipes',
    (tester) async {
      await show(tester);
      await doubleTap(tester, const Offset(400, 250));
      final left = await tester.startGesture(
        const Offset(200, 250),
        pointer: 1,
      );
      final right = await tester.startGesture(
        const Offset(600, 250),
        pointer: 2,
      );
      await left.moveTo(const Offset(240, 250));
      await right.moveTo(const Offset(560, 250));
      await left.moveTo(const Offset(370, 250));
      await right.moveTo(const Offset(430, 250));
      await tester.pump();
      expect(zoom.active, isFalse);
      expect(zoom.scale, 1);
      await right.up();
      await tester.pump();
      await left.moveBy(const Offset(0, 30));
      await left.moveBy(const Offset(0, 180));
      await left.moveBy(const Offset(-180, 0));
      await left.up();
      await tester.pumpAndSettle();
      expect([exits, switches, pulls, holds], [0, 0, 0, 0]);
      await tester.dragFrom(const Offset(400, 250), const Offset(-180, 0));
      await tester.pumpAndSettle();
      expect(switches, 1);
      await tester.dragFrom(const Offset(400, 180), const Offset(0, 220));
      await tester.pumpAndSettle();
      expect([pulls, exits], [1, 1]);
    },
  );

  testWidgets('normal-mode two-finger motion cannot switch, dismiss or boost', (
    tester,
  ) async {
    await show(tester);
    final first = await tester.startGesture(const Offset(300, 180), pointer: 1);
    final second = await tester.startGesture(
      const Offset(500, 180),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await first.moveBy(const Offset(0, 200));
    await second.up();
    await first.moveBy(const Offset(-200, 0));
    await first.up();
    await tester.pumpAndSettle();
    expect([exits, switches, holds, pulls], [0, 0, 0, 0]);
    expect(zoom.active, isFalse);
  });

  testWidgets(
    'buttons, seek and keyboard work; Escape restores before exiting and page keys reset',
    (tester) async {
      await show(tester);
      await doubleTap(
        tester,
        const Offset(400, 250),
        kind: PointerDeviceKind.mouse,
      );
      await tester.tap(find.byKey(const Key('media-play')));
      await tester.tap(find.byKey(const Key('media-rate')));
      await tester.drag(
        find.byKey(const Key('media-seek')),
        const Offset(90, 0),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      expect([plays, rates], [1, 1]);
      expect(seeks, isNotEmpty);
      expect(zoom.active, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(zoom.active, isFalse);
      expect(exits, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(exits, 1);
      await doubleTap(tester, const Offset(400, 250));
      await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
      await tester.pumpAndSettle();
      expect(switches, 1);
      expect(zoom.active, isFalse);
    },
  );

  testWidgets(
    'resize or disabling resets zoom and cancels an in-progress gesture',
    (tester) async {
      await show(tester);
      await doubleTap(tester, const Offset(400, 250));
      final finger = await tester.startGesture(const Offset(400, 250));
      await finger.moveBy(const Offset(0, 40));
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpAndSettle();
      expect(zoom.active, isFalse);
      await finger.moveBy(const Offset(0, 180));
      await finger.up();
      await tester.pumpAndSettle();
      expect([exits, switches, pulls], [0, 0, 0]);
      await doubleTap(tester, const Offset(200, 250));
      expect(zoom.active, isTrue);
      await show(tester, enabled: false);
      expect(zoom.active, isFalse);
      await doubleTap(tester, const Offset(200, 250));
      expect(zoom.active, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'single tap still toggles controls without changing zoom or playback',
    (tester) async {
      await show(tester);
      await doubleTap(tester, const Offset(400, 250));
      await tester.tapAt(const Offset(400, 250));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('media-play')).hitTestable(), findsNothing);
      expect(zoom.active, isTrue);
      expect(plays, 0);
    },
  );

  test('letterboxed anchor and panning bounds retain the visible image', () {
    zoom.layout(const Size(800, 600), 16 / 9);
    const point = Offset(200, 150);
    zoom.toggle(point);
    expect(zoom.offset + point * zoom.scale, point);
    zoom.start(point);
    zoom.update(const Offset(10000, 10000), 1);
    expect(zoom.offset, const Offset(0, -75));
    zoom.update(const Offset(-10000, -10000), 1);
    expect(zoom.offset, const Offset(-800, -525));
    zoom.start(point);
    zoom.update(point, 0.5);
    expect(zoom.scale, 1);
    expect(zoom.active, isTrue); // Only strictly below 1x exits.
    zoom.start(point);
    zoom.update(point, 0.99);
    expect(zoom.active, isFalse);
  });
}
