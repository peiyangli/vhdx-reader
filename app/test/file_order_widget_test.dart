import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'file_browser_test.dart' show entry;

void main() {
  testWidgets('selection and layout rebuilds reuse the same ordering', (
    tester,
  ) async {
    final entries = [entry('file10.txt'), entry('file2.txt')];
    Future<void> show({
      bool grid = false,
      String? selected,
      FileSort sort = FileSort.name,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FileContents(
            entries: entries,
            grid: grid,
            sort: sort,
            descending: false,
            selected: selected,
            onOpen: (_) {},
            storageKey: 'cache',
          ),
        ),
      ),
    );
    await show();
    final state = tester.state<FileContentsState>(find.byType(FileContents));
    final first = state.currentOrder;
    await show(selected: 'file2.txt');
    expect(identical(first, state.currentOrder), isTrue);
    await show(grid: true);
    expect(identical(first, state.currentOrder), isTrue);
    tester.view.physicalSize = const Size(1100, 800);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    expect(identical(first, state.currentOrder), isTrue);
    await show(sort: FileSort.size);
    expect(identical(first, state.currentOrder), isFalse);
  });
  for (final grid in [false, true]) {
    testWidgets(
      'incremental ${grid ? 'grid' : 'list'} insertion preserves visible anchor',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final order = DirectoryOrder()
          ..add([for (var i = 100; i < 240; i++) entry('n$i.txt')]);
        Future<void> show({bool descending = false}) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: FileContents(
                entries: const [],
                order: order.snapshot(FileSort.name, descending),
                grid: grid,
                sort: FileSort.name,
                descending: descending,
                onOpen: (_) {},
                storageKey: 'anchor',
              ),
            ),
          ),
        );
        await show();
        final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
        scroll.position.jumpTo(grid ? 526 : 968);
        await tester.pumpAndSettle();
        final anchor = find.byKey(
          ValueKey(grid ? 'file-n121.txt' : 'file-n120.txt'),
        );
        final before = tester.getTopLeft(anchor).dy;
        order.add([for (var i = 0; i < 14; i++) entry('a$i.txt')]);
        await show();
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(anchor).dy, closeTo(before, 0.1));
        expect(scroll.position.pixels, closeTo(grid ? 866 : 1640, 0.1));
        await show(descending: true);
        await tester.pumpAndSettle();
        expect(scroll.position.pixels, 0);
      },
    );
  }
}
