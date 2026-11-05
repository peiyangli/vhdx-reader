import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/playback_controls.dart';
import 'package:vhdx_reader/video_dismiss_view.dart';

void main() {
  var starts = 0, cancels = 0, exits = 0, switches = 0;
  Future<void> show(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDismissView(
          enabled: enabled,
          onStart: () => starts++,
          onCancel: () => cancels++,
          onDismiss: () => exits++,
          child: const ColoredBox(color: Colors.blue),
          controls: (update, end, cancel, pulling) => PlaybackControls(
            position: const Duration(seconds: 5),
            duration: const Duration(seconds: 30),
            playing: true,
            muted: false,
            enabled: enabled,
            onPlay: () {},
            onMute: () {},
            onSeek: (_) {},
            onExit: () => exits++,
            onNext: () => switches++,
            onPullUpdate: update,
            onPullEnd: end,
            onPullCancel: cancel,
            pulling: pulling,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double offset(WidgetTester tester) => tester
      .widget<Transform>(find.byKey(const Key('video-dismiss-frame')))
      .transform
      .getTranslation()
      .y;

  setUp(() {
    starts = cancels = exits = switches = 0;
  });

  testWidgets(
    'frame follows finger and fades; short pull rebounds before resume',
    (tester) async {
      await show(tester);
      final gesture = await tester.startGesture(const Offset(400, 180));
      await gesture.moveBy(const Offset(0, 24));
      await gesture.moveBy(const Offset(0, 50));
      await tester.pumpAndSettle();
      expect(starts, 1);
      expect(offset(tester), closeTo(50, 1));
      expect(
        tester
            .widget<Opacity>(find.byKey(const Key('video-dismiss-opacity')))
            .opacity,
        lessThan(1),
      );
      expect(
        tester
            .widget<ColoredBox>(find.byKey(const Key('video-dismiss-backdrop')))
            .color
            .a,
        lessThan(1),
      );
      expect(find.byKey(const Key('media-play')).hitTestable(), findsNothing);
      await gesture.up();
      expect(cancels, 0);
      await tester.pumpAndSettle();
      expect(offset(tester), 0);
      expect([cancels, exits, switches], [1, 0, 0]);
      expect(find.byKey(const Key('media-play')).hitTestable(), findsOneWidget);
    },
  );

  testWidgets(
    'large pull animates out then exits exactly once without resuming',
    (tester) async {
      await show(tester);
      final gesture = await tester.startGesture(const Offset(400, 180));
      await gesture.moveBy(const Offset(0, 24));
      await gesture.moveBy(const Offset(0, 180));
      await tester.pump();
      await gesture.up();
      expect(exits, 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(offset(tester), greaterThan(180));
      await tester.pumpAndSettle();
      expect([starts, cancels, exits], [1, 0, 1]);
    },
  );

  testWidgets(
    'pointer cancellation and disabling reset pull; upward and seek stay independent',
    (tester) async {
      await show(tester);
      await tester.dragFrom(const Offset(400, 200), const Offset(0, -100));
      await tester.drag(
        find.byKey(const Key('media-seek')),
        const Offset(0, 100),
      );
      expect(starts, 0);
      for (final disable in [false, true]) {
        final gesture = await tester.startGesture(const Offset(400, 180));
        await gesture.moveBy(const Offset(0, 24));
        await gesture.moveBy(const Offset(0, 160));
        await tester.pump();
        if (disable) await show(tester, enabled: false);
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(offset(tester), 0);
      }
      expect([starts, cancels, exits], [2, 2, 0]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('landscape uses its height and rotation cancels an active pull', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester);
    final gesture = await tester.startGesture(const Offset(400, 180));
    await gesture.moveBy(const Offset(0, 24));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    tester.view.physicalSize = const Size(500, 1000);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(offset(tester), 0);
    expect([cancels, exits], [1, 0]);
  });
}
