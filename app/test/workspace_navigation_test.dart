import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/preview.dart';
import 'reader_test.dart' show FakeBackend;
import 'windows_workspace_test.dart' show PagedBackend;
import 'ui_actions.dart';

class FolderBackend extends FakeBackend {
  final paths = <String>[];
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    if (request['op'] == 'open') {
      return {
        'virtual_size': 134217728,
        'disk_type': 'dynamic',
        'partitions': [
          {'index': 1, 'length': 132120576, 'kind': 'Ntfs'},
        ],
      };
    }
    if (request['op'] == 'list') {
      paths.add(request['path'] as String);
      return {
        'entries': [
          if (request['path'] == '/')
            {'name': 'Documents', 'directory': true, 'size': 0},
          {'name': 'notes.txt', 'directory': false, 'size': 5},
        ],
        'next_index': null,
      };
    }
    return super.request(request);
  }
}

void main() {
  for (final (platform, size) in [
    (TargetPlatform.android, const Size(320, 640)),
    (TargetPlatform.android, const Size(800, 360)),
    (TargetPlatform.android, const Size(1024, 768)),
    (TargetPlatform.iOS, const Size(390, 844)),
    (TargetPlatform.iOS, const Size(1024, 768)),
    (TargetPlatform.macOS, const Size(1200, 800)),
    (TargetPlatform.windows, const Size(1280, 820)),
    (TargetPlatform.linux, const Size(1200, 800)),
  ]) {
    testWidgets('$platform shared navigation, sorting and refresh at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = PagedBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'a-very-long-image-filename.vhdx',
          platform: platform,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('205 个项目'), findsOneWidget);
      expect(find.byKey(const Key('image-switcher')), findsNothing);
      expect(find.byKey(const Key('browser-menu')), findsNothing);
      expect(find.byKey(const Key('disk-navigation')), findsOneWidget);
      expect(
        find.byTooltip('关闭窗口'),
        platform == TargetPlatform.windows ? findsOneWidget : findsNothing,
      );
      expect(find.byKey(const ValueKey('image-tab-0')), findsNothing);
      expect(find.text('修改日期'), findsNothing);
      expect(find.text('筛选已加载文件'), findsNothing);
      await browserAction(tester, 'view-grid');
      await browserAction(tester, 'sort-size');
      await browserAction(tester, 'order-descending');
      final contents = tester.widget<FileContents>(find.byType(FileContents));
      expect(contents.grid, true);
      expect(contents.sort, FileSort.size);
      expect(contents.descending, true);
      await browserAction(tester, 'show-system');
      expect(
        backend.requests.lastWhere((r) => r['op'] == 'list')['show_system'],
        true,
      );
      await browserAction(tester, 'view-list');
      final count = backend.requests.where((r) => r['op'] == 'list').length;
      await tester.drag(find.byType(ListView).first, const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(
        backend.requests.where((r) => r['op'] == 'list').length,
        count + 2,
      );
      await switchImage(tester, 0);
      await browserAction(tester, 'close-image');
      expect(find.text('选择 VHDX 文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'Android drawer switches and closes disks; settings preserves directory and view',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = FolderBackend()..reject = false;
      final second = FolderBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: first,
          initialImage: 'first.vhdx',
          platform: TargetPlatform.android,
          createBackend: () async => second,
          pickImages: () async => ['second.vhdx'],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documents'));
      await tester.pumpAndSettle();
      await browserAction(tester, 'view-grid');
      await tester.tap(find.byKey(const Key('disk-navigation')));
      await tester.pumpAndSettle();
      expect(find.text('已加载磁盘'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.byKey(const ValueKey('image-tab-0')))
            .selected,
        true,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(first.paths.last, '/Documents');
      expect(find.text('已加载磁盘'), findsNothing);
      await openReaderSettings(tester);
      expect(find.byKey(const Key('reader-settings-page')), findsOneWidget);
      expect(find.byKey(const Key('disk-navigation')), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      await tester.tap(find.byKey(const Key('show-system')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('show-system')))
            .value,
        true,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-settings-page')), findsNothing);
      expect(first.paths.last, '/Documents');
      expect(tester.widget<FileContents>(find.byType(FileContents)).grid, true);
      await openReaderSettings(tester);
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('show-system')))
            .value,
        true,
      );
      await tester.tap(find.byKey(const Key('credential-manager')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-settings-page')), findsOneWidget);
      await tester.tap(find.byKey(const Key('settings-back')));
      await tester.pumpAndSettle();
      await browserAction(tester, 'open-image');
      await tester.pumpAndSettle();
      expect(find.text('second.vhdx'), findsOneWidget);
      await switchImage(tester, 0);
      expect(tester.widget<FileContents>(find.byType(FileContents)).grid, true);
      expect(find.text('分区 1 · /Documents'), findsOneWidget);
      await switchImage(tester, 1);
      await browserAction(tester, 'close-image');
      expect(second.disposed, true);
      expect(find.text('first.vhdx'), findsOneWidget);
      await tester.tap(find.byKey(const Key('disk-navigation')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('image-tab-1')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Android back closes inline preview, goes up, and root permits exit',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FolderBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'folder.vhdx',
          platform: TargetPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Documents'));
      await tester.pumpAndSettle();
      expect(backend.paths.last, '/Documents');
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.byType(PreviewPane), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('hello'), findsOneWidget);
      expect(
        ModalRoute.of(tester.element(find.byType(PreviewPane)))!.popDisposition,
        RoutePopDisposition.doNotPop,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(PreviewPane), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(backend.paths.last, '/');
      expect(
        ModalRoute.of(
          tester.element(find.byType(FileContents)),
        )!.popDisposition,
        RoutePopDisposition.bubble,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
