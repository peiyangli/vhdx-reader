import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/main.dart';
import 'reader_test.dart' show FakeBackend;
import 'file_browser_test.dart' show entry;

class PendingPage {
  PendingPage(this.request);
  final Map<String, dynamic> request;
  final done = Completer<Map<String, dynamic>>();
  void finish(List<Map<String, dynamic>> entries, [int? next]) =>
      done.complete({'entries': entries, 'next_index': next});
}

class DelayedBackend extends FakeBackend {
  final pages = <PendingPage>[];
  int cancels = 0;
  @override
  void cancel() {
    cancels++;
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    if (request['op'] == 'open') {
      return {
        'virtual_size': 1024,
        'disk_type': 'dynamic',
        'partitions': [
          {'index': 1, 'length': 1024, 'kind': 'Ntfs'},
        ],
      };
    }
    if (request['op'] == 'list') {
      final page = PendingPage(Map.of(request));
      pages.add(page);
      return page.done.future;
    }
    return super.request(request);
  }
}

Future<void> until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 60 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}

Future<DelayedBackend> start(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final backend = DelayedBackend()..reject = false;
  await tester.pumpWidget(
    ReaderApp(
      backend: backend,
      initialImage: 'paged.vhdx',
      platform: TargetPlatform.windows,
    ),
  );
  await until(tester, () => backend.pages.isNotEmpty);
  return backend;
}

FileContents contents(WidgetTester tester) =>
    tester.widget<FileContents>(find.byType(FileContents));
void main() {
  testWidgets(
    'refresh failure before first page preserves complete previous snapshot',
    (tester) async {
      final backend = await start(tester);
      backend.pages[0].finish([entry('existing.txt')]);
      await tester.pumpAndSettle();
      final previous = contents(tester).order;
      final refresh = contents(tester).onRefresh!();
      await until(tester, () => backend.pages.length == 2);
      backend.pages[1].done.completeError(ReaderFailure('io', '刷新失败'));
      await refresh;
      await tester.pumpAndSettle();
      expect(identical(contents(tester).order, previous), isTrue);
      expect(contents(tester).incomplete, isFalse);
    },
  );
  testWidgets(
    'cancel publishes received batches but discards the pending response',
    (tester) async {
      final backend = await start(tester);
      backend.pages[0].finish([entry('a.txt')], 200);
      await until(tester, () => backend.pages.length == 2);
      backend.pages[1].finish([entry('b.txt')], 400);
      await until(tester, () => backend.pages.length == 3);
      await tester.tap(find.text('取消'));
      backend.pages[2].finish([entry('late.txt')]);
      await tester.pumpAndSettle();
      expect(contents(tester).entries.map((e) => e['name']), [
        'a.txt',
        'b.txt',
      ]);
      expect(contents(tester).incomplete, isTrue);
    },
  );

  testWidgets(
    'first page paints while later request is pending and final batch merges',
    (tester) async {
      final backend = await start(tester);
      backend.pages[0].finish([entry('file10.txt'), entry('file2.txt')], 200);
      await until(tester, () => backend.pages.length == 2);
      expect(find.text('file2.txt'), findsOneWidget);
      expect(contents(tester).loading, isTrue);
      expect(contents(tester).incomplete, isTrue);
      backend.pages[1].finish([entry('file1.txt')]);
      await tester.pumpAndSettle();
      expect(contents(tester).entries.map((e) => e['name']), [
        'file1.txt',
        'file2.txt',
        'file10.txt',
      ]);
      expect(contents(tester).loading, isFalse);
      expect(find.text('3 个项目'), findsOneWidget);
    },
  );
  testWidgets(
    'cancel discards late page and retains usable partial directory',
    (tester) async {
      final backend = await start(tester);
      backend.pages[0].finish([entry('notes.txt')], 200);
      await until(tester, () => backend.pages.length == 2);
      await tester.tap(find.text('取消'));
      backend.pages[1].finish([entry('late.txt')], 400);
      await tester.pumpAndSettle();
      expect(backend.cancels, 1);
      expect(backend.pages.length, 2);
      expect(contents(tester).entries.map((e) => e['name']), ['notes.txt']);
      expect(contents(tester).incomplete, isTrue);
      expect(find.textContaining('未完成'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('file-notes.txt')));
      await tester.pumpAndSettle();
      expect(backend.ops, contains('read'));
    },
  );
  testWidgets(
    'opening a partial folder drains cancellation before starting new path',
    (tester) async {
      final backend = await start(tester);
      backend.pages[0].finish([entry('docs', folder: true)], 200);
      await until(tester, () => backend.pages.length == 2);
      await tester.tap(find.byKey(const ValueKey('file-docs')));
      await tester.pump();
      expect(backend.cancels, 1);
      expect(backend.pages.length, 2);
      backend.pages[1].finish([entry('stale.txt')]);
      await until(tester, () => backend.pages.length == 3);
      expect(backend.pages[2].request['path'], '/docs');
      backend.pages[2].finish([entry('inside.txt')]);
      await tester.pumpAndSettle();
      expect(contents(tester).entries.single['name'], 'inside.txt');
    },
  );
  testWidgets('filter changes restart from zero with one consistent filter', (
    tester,
  ) async {
    final backend = await start(tester);
    backend.pages[0].finish([entry('old.txt')], 200);
    await until(tester, () => backend.pages.length == 2);
    final home = tester.widget<ReaderHome>(find.byType(ReaderHome));
    home.onBrowserSettings(home.browserSettings.copyWith(showSystem: true));
    await tester.pump();
    backend.pages[1].finish([entry('late.txt')], 400);
    await until(tester, () => backend.pages.length == 3);
    expect(backend.pages.take(2).map((p) => p.request['show_system']), [
      false,
      false,
    ]);
    expect(backend.pages[2].request['start'], 0);
    expect(backend.pages[2].request['show_system'], isTrue);
    backend.pages[2].finish([entry('system.txt')]);
    await tester.pumpAndSettle();
    expect(contents(tester).entries.single['name'], 'system.txt');
  });
  testWidgets('empty filtered page is loading, errors retain partial results', (
    tester,
  ) async {
    final backend = await start(tester);
    backend.pages[0].finish([], 200);
    await until(tester, () => backend.pages.length == 2);
    expect(find.text('正在读取目录…'), findsWidgets);
    expect(find.text('此文件夹为空'), findsNothing);
    backend.pages[1].finish([entry('kept.txt')], 400);
    await until(tester, () => backend.pages.length == 3);
    backend.pages[2].done.completeError(ReaderFailure('io', '读取失败'));
    await tester.pumpAndSettle();
    expect(contents(tester).entries.single['name'], 'kept.txt');
    expect(contents(tester).incomplete, isTrue);
    expect(find.text('读取失败'), findsWidgets);
  });
  testWidgets('invalid cursor stops and disposed page cannot update widgets', (
    tester,
  ) async {
    final backend = await start(tester);
    backend.pages[0].finish([entry('kept.txt')], 200);
    await until(tester, () => backend.pages.length == 2);
    backend.pages[1].finish([entry('bad.txt')], 200);
    await tester.pumpAndSettle();
    expect(backend.pages.length, 2);
    expect(contents(tester).entries.single['name'], 'kept.txt');
    final refresh = contents(tester).onRefresh!();
    await until(tester, () => backend.pages.length == 3);
    await tester.pumpWidget(const SizedBox());
    backend.pages[2].finish([entry('late.txt')]);
    await tester.pump();
    await refresh;
    expect(tester.takeException(), isNull);
  });
}
