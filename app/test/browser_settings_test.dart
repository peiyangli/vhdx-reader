import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/browser_settings.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/main.dart';
import 'windows_workspace_test.dart' show PagedBackend;
import 'ui_actions.dart';

void main() {
  test(
    'browser preferences persist in order and recover invalid input',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'browser-preferences-',
      );
      try {
        final store = BrowserSettingsStore(directory: directory);
        expect((await store.load()).toJson(), const BrowserSettings().toJson());
        const latest = BrowserSettings(
          seekSeconds: 15,
          grid: true,
          sort: FileSort.type,
          descending: true,
          showSystem: true,
        );
        await Future.wait([
          store.save(const BrowserSettings(grid: true)),
          store.save(const BrowserSettings(sort: FileSort.size)),
          store.save(latest),
        ]);
        expect(
          (await BrowserSettingsStore(directory: directory).load()).toJson(),
          latest.toJson(),
        );
        expect(directory.listSync().length, 1);
        final file = File('${directory.path}/browser-settings.json');
        await file.writeAsString('{broken');
        expect((await store.load()).toJson(), const BrowserSettings().toJson());
        await file.writeAsString(
          jsonEncode({
            'version': 1,
            'browser': {
              'grid': true,
              'sort': 'unknown',
              'descending': 'true',
              'show_system': 1,
            },
          }),
        );
        expect(
          (await store.load()).toJson(),
          const BrowserSettings(grid: true).toJson(),
        );
        await file.writeAsString(
          jsonEncode({'version': 99, 'browser': latest.toJson()}),
        );
        expect((await store.load()).toJson(), const BrowserSettings().toJson());
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test('seek preference rejects invalid and legacy values', () {
    for (final value in [null, '10', -1, 0, 999, 10.0]) {
      expect(BrowserSettings.fromJson({'seek_seconds': value}).seekSeconds, 5);
    }
    expect(BrowserSettings.fromJson({'seek_seconds': 10}).seekSeconds, 10);
  });

  testWidgets('desktop seek setting saves and restores', (tester) async {
    BrowserSettings saved = const BrowserSettings();
    await tester.pumpWidget(
      ReaderApp(
        backend: PagedBackend()..reject = false,
        initialImage: 'one.vhdx',
        platform: TargetPlatform.windows,
        saveBrowserSettings: (value) async => saved = value,
      ),
    );
    await tester.pumpAndSettle();
    await openReaderSettings(tester);
    await tester.tap(find.byKey(const Key('playback-seek-seconds')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('seek-seconds-15')));
    await tester.pumpAndSettle();
    expect(saved.seekSeconds, 15);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      ReaderApp(
        backend: PagedBackend()..reject = false,
        initialImage: 'two.vhdx',
        platform: TargetPlatform.windows,
        browserSettings: saved,
      ),
    );
    await tester.pumpAndSettle();
    await openReaderSettings(tester);
    expect(find.text('15 秒'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('failed save does not prevent a later preference save', () async {
    final root = await Directory.systemTemp.createTemp('browser-retry-');
    try {
      final blocked = File('${root.path}/settings');
      await blocked.writeAsString('not a directory');
      final store = BrowserSettingsStore(directory: Directory(blocked.path));
      await expectLater(
        store.save(const BrowserSettings(grid: true)),
        throwsA(isA<FileSystemException>()),
      );
      await blocked.delete();
      await store.save(const BrowserSettings(sort: FileSort.modified));
      expect((await store.load()).sort, FileSort.modified);
    } finally {
      await root.delete(recursive: true);
    }
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform restores display, ordering and system files in a new workspace',
      (tester) async {
        BrowserSettings saved = const BrowserSettings();
        await tester.pumpWidget(
          ReaderApp(
            backend: PagedBackend()..reject = false,
            initialImage: 'one.vhdx',
            platform: platform,
            saveBrowserSettings: (value) async => saved = value,
          ),
        );
        await tester.pumpAndSettle();
        await browserAction(tester, 'view-grid');
        await browserAction(tester, 'sort-type');
        await browserAction(tester, 'order-descending');
        await browserAction(tester, 'show-system');
        expect(
          saved.toJson(),
          const BrowserSettings(
            grid: true,
            sort: FileSort.type,
            descending: true,
            showSystem: true,
          ).toJson(),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final backend = PagedBackend()..reject = false;
        await tester.pumpWidget(
          ReaderApp(
            backend: backend,
            initialImage: 'two.vhdx',
            platform: platform,
            browserSettings: saved,
          ),
        );
        await tester.pumpAndSettle();
        final contents = tester.widget<FileContents>(find.byType(FileContents));
        expect(contents.grid, true);
        expect(contents.sort, FileSort.type);
        expect(contents.descending, true);
        expect(
          backend.requests.firstWhere((r) => r['op'] == 'list')['show_system'],
          true,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('saving failures report that preferences were not persisted', (
    tester,
  ) async {
    await tester.pumpWidget(
      ReaderApp(
        backend: PagedBackend()..reject = false,
        initialImage: 'one.vhdx',
        saveBrowserSettings: (_) async =>
            throw const FileSystemException('test failure'),
      ),
    );
    await tester.pumpAndSettle();
    await browserAction(tester, 'view-grid');
    expect(tester.widget<FileContents>(find.byType(FileContents)).grid, true);
    expect(find.text('无法保存文件列表设置，本次显示仍生效，请重试。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
