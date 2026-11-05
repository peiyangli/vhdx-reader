import 'package:flutter/services.dart';
import 'ui_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/main.dart';
import 'reader_test.dart' show FakeBackend;

class PagedBackend extends FakeBackend {
  final requests = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    requests.add(Map.from(request));
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
      final start = request['start'] as int;
      return {
        'entries': [
          for (var i = start; i < (start == 0 ? 200 : 205); i++)
            {
              'name': 'file${205 - i}.txt',
              'directory': false,
              'size': 5,
              'attributes': 32,
              'modified_unix_ms': i * 1000,
            },
        ],
        'next_index': start == 0 ? 200 : null,
      };
    }
    return super.request(request);
  }
}

void main() {
  testWidgets(
    'Windows loads all pages, shares view data and applies hidden setting',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = PagedBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'paged.vhdx',
          platform: TargetPlatform.windows,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('205 个项目'), findsOneWidget);
      expect(tester.getTopRight(find.byTooltip('关闭窗口')).dx, 1280);
      expect(find.text('筛选已加载文件'), findsNothing);
      expect(find.text('文件浏览'), findsNothing);
      expect(find.text('文件预览'), findsNothing);
      expect(find.text('file1.txt'), findsOneWidget);
      expect(
        backend.requests.where((r) => r['op'] == 'list').map((r) => r['start']),
        [0, 200],
      );
      expect(find.text('名称'), findsNothing);
      expect(find.text('修改日期'), findsNothing);
      expect(find.text('大小'), findsNothing);
      expect(find.byKey(const ValueKey('image-tab-0')), findsNothing);
      expect(find.byTooltip('刷新'), findsNothing);
      expect(find.byKey(const Key('image-switcher')), findsNothing);
      expect(find.byKey(const Key('disk-navigation')), findsOneWidget);
      expect(find.byTooltip('展示'), findsOneWidget);
      expect(find.byKey(const Key('browser-menu')), findsNothing);
      await tester.tap(find.byKey(const Key('display-menu')));
      await tester.pumpAndSettle();
      for (final action in [
        'view-grid',
        'view-list',
        'sort-name',
        'sort-size',
        'sort-modified',
        'sort-type',
        'order-ascending',
        'order-descending',
      ]) {
        expect(find.byKey(ValueKey(action)), findsOneWidget);
      }
      expect(find.text('✓ 列表'), findsOneWidget);
      expect(find.text('✓ 名称'), findsOneWidget);
      expect(find.text('✓ 升序'), findsOneWidget);
      expect(find.byKey(const Key('open-image')), findsNothing);
      await tester.tap(find.byKey(const Key('view-grid')));

      await tester.pumpAndSettle();
      expect(tester.widget<FileContents>(find.byType(FileContents)).grid, true);
      await browserAction(tester, 'sort-size');
      expect(
        tester.widget<FileContents>(find.byType(FileContents)).sort,
        FileSort.size,
      );
      await browserAction(tester, 'sort-type');
      expect(
        tester.widget<FileContents>(find.byType(FileContents)).sort,
        FileSort.type,
      );
      await browserAction(tester, 'order-descending');
      expect(
        tester.widget<FileContents>(find.byType(FileContents)).descending,
        true,
      );
      expect(tester.widget<FileContents>(find.byType(FileContents)).grid, true);
      await browserAction(tester, 'order-ascending');
      await tester.tap(find.byKey(const Key('disk-navigation')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sort-name')), findsNothing);
      expect(find.byKey(const Key('switch-image')), findsNothing);
      expect(find.byKey(const Key('open-image')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await openReaderSettings(tester);
      expect(tester.getTopRight(find.byTooltip('关闭窗口')).dx, 1280);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reader-settings-page')), findsNothing);
      await browserAction(tester, 'sort-modified');
      expect(
        tester.widget<FileContents>(find.byType(FileContents)).sort,
        FileSort.modified,
      );
      await browserAction(tester, 'show-system');
      expect(
        backend.requests.lastWhere((r) => r['op'] == 'list')['show_system'],
        true,
      );
      await browserAction(tester, 'view-list');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('file-file205.txt')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭预览'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭预览'));
      await tester.pumpAndSettle();
      expect(find.text('文件预览'), findsNothing);
      final beforeRefresh = backend.requests
          .where((r) => r['op'] == 'list')
          .length;
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pumpAndSettle();
      expect(
        backend.requests.where((r) => r['op'] == 'list').length,
        beforeRefresh + 2,
      );
      await tester.drag(find.byType(ListView).first, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(
        backend.requests.where((r) => r['op'] == 'list').length,
        beforeRefresh + 4,
      );
      tester.view.physicalSize = const Size(960, 650);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
