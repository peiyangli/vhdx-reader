import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/preview.dart';
import 'package:vhdx_reader/window_chrome.dart';
import 'reader_test.dart' show FakeBackend;

void main() {
  testWidgets(
    'desktop titlebar survives preview; tray hide retains unlock and lock-all revokes it',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final backend = FakeBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'test.vhdx',
          platform: TargetPlatform.windows,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('unlock-secret')),
        'test-value',
      );
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopTitleBar).hitTestable(), findsOneWidget);
      expect(find.byType(WindowButtons), findsOneWidget);
      expect(find.byType(PreviewPane), findsOneWidget);
      final unlocks = backend.ops.where((op) => op == 'unlock').length;
      Future<void> event(String name) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'vhdx_reader/window',
          const StandardMethodCodec().encodeMethodCall(MethodCall(name)),
          (_) {},
        );
        await tester.pumpAndSettle();
      }

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderHome>(find.byType(ReaderHome)).active,
        isTrue,
        reason:
            'A visible desktop window remains active without keyboard focus',
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await event('hidden');
      expect(
        tester.widget<ReaderHome>(find.byType(ReaderHome)).active,
        isFalse,
      );
      expect(backend.ops, isNot(contains('lock')));
      expect(backend.disposed, isFalse);
      await event('shown');
      expect(tester.widget<ReaderHome>(find.byType(ReaderHome)).active, isTrue);
      expect(find.byType(PreviewPane), findsOneWidget);
      expect(backend.ops.where((op) => op == 'unlock').length, unlocks);
      await event('lockAll');
      expect(backend.ops, contains('lock'));
      expect(find.byType(PreviewPane), findsNothing);
      expect(find.byKey(const Key('unlock-button')), findsOneWidget);
    },
  );
}
