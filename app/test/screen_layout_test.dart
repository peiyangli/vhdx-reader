import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/platform_storage.dart';
import 'package:vhdx_reader/preview.dart';
import 'workspace_navigation_test.dart' show FolderBackend;
import 'windows_workspace_test.dart' show PagedBackend;
import 'ui_actions.dart';

void main() {
  testWidgets('short landscape welcome keeps primary action visible', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(820, 360);
    tester.view.padding = const FakeViewPadding(left: 36, top: 24);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ReaderApp(backend: FolderBackend(), platform: TargetPlatform.android),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(
      find.ancestor(
        of: find.text('选择 VHDX 文件'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(rect.bottom, lessThanOrEqualTo(360));
    expect(rect.top, greaterThanOrEqualTo(72));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cutout is background only; drawer and scrim reach both screen edges',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(840, 390);
      tester.view.padding = const FakeViewPadding(left: 40, bottom: 24);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ReaderApp(
          backend: FolderBackend()..reject = false,
          initialImage: 'disk.vhdx',
          platform: TargetPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.byKey(const Key('disk-navigation'))).dx,
        40,
      );
      expect(
        tester.getSize(find.byKey(const Key('disk-navigation'))).height,
        48,
      );
      expect(find.text('只读'), findsNothing);
      await tester.tap(find.byKey(const Key('disk-navigation')));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(Drawer)).topLeft, Offset.zero);
      expect(tester.getRect(find.byType(Drawer)).height, 390);
      expect(
        tester.getRect(find.byKey(const Key('settings-nav'))).bottom,
        lessThanOrEqualTo(366),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rotate and resize preserves folder, sort, preview state and scroll',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 840);
      addTearDown(tester.view.reset);
      final backend = FolderBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'disk.vhdx',
          platform: TargetPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documents'));
      await tester.pumpAndSettle();
      await browserAction(tester, 'sort-size');
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      final previewState = tester.state(find.byType(PreviewPane));
      final reads = backend.ops.where((e) => e == 'read').length;
      for (final size in [
        const Size(840, 390),
        const Size(1200, 800),
        const Size(600, 800),
        const Size(390, 840),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(PreviewPane)), same(previewState));
        expect(find.text('hello'), findsOneWidget);
        expect(find.byType(FileContents), findsNothing);
        expect(find.byKey(const Key('disk-navigation')), findsNothing);
        expect(find.byKey(const Key('display-menu')), findsNothing);
        expect(tester.getSize(find.byType(PreviewScreen)), size);
        expect(backend.paths.last, '/Documents');
        expect(backend.ops.where((e) => e == 'read').length, reads);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FileContents>(find.byType(FileContents)).sort,
        FileSort.size,
      );
    },
  );

  testWidgets('file scroll position survives compact layout and preview', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 840);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ReaderApp(
        backend: PagedBackend()..reject = false,
        initialImage: 'disk.vhdx',
        platform: TargetPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
    final offset = scroll.position.pixels;
    tester.view.physicalSize = const Size(840, 390);
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(find.byType(Scrollable)),
      same(scroll),
    );
    expect(scroll.position.pixels, offset);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'orientation setting loads, saves and reports failure without changing selection',
    (tester) async {
      var saved = 'landscape';
      var failSave = false;
      var shake = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformStorage.channel,
        (call) async {
          if (call.method == 'screenDirection') return saved;
          if (call.method == 'shakeRotation') {
            return {'enabled': shake, 'available': true};
          }
          if (call.method == 'setShakeRotation') {
            if (failSave) throw PlatformException(code: 'save');
            shake = call.arguments['value'] as bool;
          }
          if (call.method == 'setScreenDirection') {
            if (failSave) throw PlatformException(code: 'save');
            saved = call.arguments['value'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          PlatformStorage.channel,
          null,
        ),
      );
      await tester.pumpWidget(
        ReaderApp(
          backend: FolderBackend()..reject = false,
          initialImage: 'disk.vhdx',
          platform: TargetPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      await openReaderSettings(tester);
      expect(find.text('固定横屏'), findsOneWidget);
      await tester.tap(find.byKey(const Key('shake-rotation')));
      await tester.pumpAndSettle();
      expect(shake, true);
      expect(find.text('仅在屏幕方向为自动时生效'), findsOneWidget);
      await tester.tap(find.byKey(const Key('screen-direction')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direction-portrait')));
      await tester.pumpAndSettle();
      expect(saved, 'portrait');
      expect(find.text('固定竖屏'), findsOneWidget);
      failSave = true;
      await tester.tap(find.byKey(const Key('screen-direction')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('direction-automatic')));
      await tester.pumpAndSettle();
      expect(find.text('固定竖屏'), findsOneWidget);
      expect(find.text('无法保存屏幕方向，请重试。'), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byKey(const Key('shake-rotation'))),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shake-rotation')));
      await tester.pumpAndSettle();
      expect(shake, true);
      expect(find.text('无法保存摇晃旋转设置，请重试。'), findsOneWidget);
    },
  );

  testWidgets('short landscape menu and large text remain reachable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(740, 320);
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ReaderApp(
        backend: FolderBackend()..reject = false,
        initialImage: 'very-long-disk-name.vhdx',
        platform: TargetPlatform.android,
      ),
    );
    await tester.pumpAndSettle();
    await browserAction(tester, 'order-descending');
    expect(
      tester.widget<FileContents>(find.byType(FileContents)).descending,
      true,
    );
    await browserAction(tester, 'view-grid');
    await openReaderSettings(tester);
    expect(tester.takeException(), isNull);
  });
  testWidgets('iOS exposes persisted direction without Android shake setting', (
    tester,
  ) async {
    var saved = 'automatic';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      PlatformStorage.channel,
      (call) async {
        if (call.method == 'screenDirection') return saved;
        if (call.method == 'setScreenDirection') {
          saved = call.arguments['value'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        PlatformStorage.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      ReaderApp(
        backend: FolderBackend()..reject = false,
        initialImage: 'disk.vhdx',
        platform: TargetPlatform.iOS,
      ),
    );
    await tester.pumpAndSettle();
    await openReaderSettings(tester);
    expect(find.byKey(const Key('shake-rotation')), findsNothing);
    await tester.tap(find.byKey(const Key('screen-direction')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('direction-landscape')));
    await tester.pumpAndSettle();
    expect(saved, 'landscape');
    expect(find.text('固定横屏'), findsOneWidget);
  });
}
