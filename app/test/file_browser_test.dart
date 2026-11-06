import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/file_browser.dart';

Map<String, dynamic> entry(
  String name, {
  bool folder = false,
  int? date,
  int size = 123,
}) => {
  'name': name,
  'directory': folder,
  'size': size,
  'modified_unix_ms': date,
};

void main() {
  test(
    'video neighbours use directory sort, skip folders/non-video, never wrap',
    () {
      final files = [
        entry('clip10.mp4', size: 20),
        entry('folder.mp4', folder: true),
        entry('clip2.mp4', size: 30),
        entry('notes.txt'),
        entry('clip1.MKV', size: 10),
      ];
      expect(
        adjacentVideo(files, 'clip2.mp4', 1, FileSort.name, false)?['name'],
        'clip10.mp4',
      );
      expect(
        adjacentVideo(files, 'clip2.mp4', -1, FileSort.name, false)?['name'],
        'clip1.MKV',
      );
      expect(
        adjacentVideo(files, 'clip2.mp4', 1, FileSort.name, true)?['name'],
        'clip1.MKV',
      );
      expect(
        adjacentVideo(files, 'clip2.mp4', 1, FileSort.size, false),
        isNull,
      );
      expect(
        adjacentVideo(files, 'clip1.MKV', -1, FileSort.name, false),
        isNull,
      );
      expect(
        adjacentVideo(files, 'missing.mp4', 1, FileSort.name, false),
        isNull,
      );
    },
  );

  test(
    'natural filename order keeps folders first and does not mutate input',
    () {
      final files = [
        entry('file10.txt'),
        entry('docs', folder: true),
        entry('file2.txt'),
      ];
      expect(sortedFiles(files, FileSort.name, false).map((e) => e['name']), [
        'docs',
        'file2.txt',
        'file10.txt',
      ]);
      expect(sortedFiles(files, FileSort.name, true).map((e) => e['name']), [
        'docs',
        'file10.txt',
        'file2.txt',
      ]);
      expect(files.first['name'], 'file10.txt');
    },
  );

  test('date order keeps unknown dates last in either direction', () {
    final files = [
      entry('unknown'),
      entry('old', date: 1000),
      entry('new', date: 2000),
      entry('folder', folder: true, date: 500),
    ];
    expect(sortedFiles(files, FileSort.modified, false).map((e) => e['name']), [
      'folder',
      'old',
      'new',
      'unknown',
    ]);
    expect(sortedFiles(files, FileSort.modified, true).map((e) => e['name']), [
      'folder',
      'new',
      'old',
      'unknown',
    ]);
    expect(fileDate(null), '—');
  });

  test('size uses bytes, keeps folders first, and breaks ties by name', () {
    final files = [
      entry('large', size: 100),
      entry('small2', size: 9),
      entry('small1', size: 9),
      entry('folder', folder: true, size: 999),
    ];
    expect(sortedFiles(files, FileSort.size, false).map((e) => e['name']), [
      'folder',
      'small1',
      'small2',
      'large',
    ]);
    expect(sortedFiles(files, FileSort.size, true).map((e) => e['name']), [
      'folder',
      'large',
      'small2',
      'small1',
    ]);
  });

  test(
    'type groups friendly categories and uses natural names within each category',
    () {
      final files = [
        entry('zeta.txt'),
        entry('alpha.TXT'),
        entry('report.pdf'),
        entry('README'),
        entry('folder.zzz', folder: true),
      ];
      expect(sortedFiles(files, FileSort.type, false).map((e) => e['name']), [
        'folder.zzz',
        'report.pdf',
        'alpha.TXT',
        'zeta.txt',
        'README',
      ]);
      expect(sortedFiles(files, FileSort.type, true).map((e) => e['name']), [
        'folder.zzz',
        'README',
        'zeta.txt',
        'alpha.TXT',
        'report.pdf',
      ]);
      expect(fileType('.env'), '');
      expect(fileType('name.'), '');
    },
  );

  for (final mode in ['empty', 'list', 'grid']) {
    testWidgets('pull refresh works for $mode contents', (tester) async {
      var refreshes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileContents(
              entries: mode == 'empty' ? [] : [entry('one.txt')],
              grid: mode == 'grid',
              sort: FileSort.name,
              descending: false,
              onOpen: (_) {},
              storageKey: mode,
              onRefresh: () async {
                refreshes++;
              },
            ),
          ),
        ),
      );
      await tester.drag(
        find.byType(Scrollable).first,
        const Offset(0, 450),
        kind: mode == 'list'
            ? PointerDeviceKind.mouse
            : PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(refreshes, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'list and grid open the same entry and handle narrow preview widths',
    (tester) async {
      tester.view.physicalSize = const Size(700, 650);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final files = [
        entry('notes.txt', date: 1000),
        entry('documents', folder: true),
      ];
      Map<String, dynamic>? opened;
      for (final grid in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 480,
                child: FileContents(
                  entries: files,
                  grid: grid,
                  sort: FileSort.name,
                  descending: false,

                  onOpen: (e) => opened = e,
                  storageKey: 'fixture',
                  selected: 'notes.txt',
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const ValueKey('file-notes.txt')));
        expect(opened, same(files.first));
        expect(tester.takeException(), isNull);
      }
    },
  );
}
