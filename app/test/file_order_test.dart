import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/file_order.dart';
import 'support/legacy_file_order.dart';

Map<String, dynamic> item(String name, int i) => {
  'name': name,
  'directory': i % 13 == 0,
  'size': i % 7,
  'modified_unix_ms': i % 3 == 0 ? null : i % 19,
};
void main() {
  test('cached and incremental order match legacy across all sort modes', () {
    final entries = [
      for (var i = 0; i < 2400; i++)
        item(
          'file${i % 23}_${i.toString().padLeft(i % 5 + 1, '0')}.${i % 2 == 0 ? 'mp4' : 'txt'}',
          i,
        ),
      for (final name in [
        '',
        'A2',
        'a02',
        'a0002',
        'a9999999999999999999999999999999999999999',
        'a10000000000000000000000000000000000000000',
        '中文2',
        '中文10',
      ])
        item(name, 1),
    ]..shuffle(Random(71));
    final original = List.of(entries);
    for (final sort in FileSort.values) {
      for (final descending in [false, true]) {
        final order = DirectoryOrder();
        for (var start = 0; start < entries.length; start += 200) {
          final end = min(start + 200, entries.length);
          order.add(entries.sublist(start, end));
          final view = order.snapshot(sort, descending);
          expect(
            view.entries,
            legacySortedFiles(entries.sublist(0, end), sort, descending),
          );
          expect(identical(view, order.snapshot(sort, descending)), isTrue);
        }
        for (final nextSort in FileSort.values) {
          expect(
            order.snapshot(nextSort, !descending).entries,
            legacySortedFiles(entries, nextSort, !descending),
          );
        }
      }
    }
    expect(entries, original);
  });
  test('snapshot stays immutable and cache invalidates on source identity', () {
    final entries = [
      item('clip10.mp4', 1),
      item('clip2.mp4', 2),
      item('folder.mp4', 13),
      item('notes.txt', 3),
    ];
    final cache = FileOrderCache();
    final first = cache.resolve(entries, FileSort.name, false);
    expect(
      identical(first, cache.resolve(entries, FileSort.name, false)),
      isTrue,
    );
    expect(first.adjacentVideo('clip2.mp4', 1)?['name'], 'clip10.mp4');
    expect(first.adjacentVideo('clip2.mp4', -1), isNull);
    expect(first.adjacentVideo('folder.mp4', 1), isNull);
    expect(first.indexOf('clip2.mp4'), 1);
    expect(() => first.entries.add(item('x', 1)), throwsUnsupportedError);
    expect(
      identical(first, cache.resolve(List.of(entries), FileSort.name, false)),
      isFalse,
    );
    final order = DirectoryOrder()..add(entries);
    final snapshot = order.snapshot(FileSort.name, false);
    order.add([item('clip1.mp4', 4)]);
    expect(order.snapshot(FileSort.name, false).entries.length, 5);
    expect(snapshot.entries.length, 4);
  });
}
