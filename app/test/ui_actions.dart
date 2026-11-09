import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> openReaderSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('disk-navigation')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('settings-nav')));
  await tester.pumpAndSettle();
}

Future<void> ensureReaderSettingVisible(
  WidgetTester tester,
  Finder item,
) async {
  final scrollable = find
      .descendant(
        of: find.byKey(const Key('reader-settings-page')),
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(
    item,
    120,
    scrollable: scrollable,
    maxScrolls: 30,
  );
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
}

Future<void> browserAction(
  WidgetTester tester,
  String action, {
  Finder? legacy,
}) async {
  final display =
      action.startsWith('view-') ||
      action.startsWith('sort-') ||
      action.startsWith('order-');
  if (action == 'show-system' || action == 'credential-manager') {
    await openReaderSettings(tester);
  } else {
    await tester.tap(
      find.byKey(Key(display ? 'display-menu' : 'disk-navigation')),
    );
    await tester.pumpAndSettle();
  }
  final item = find.byKey(ValueKey(action));
  if (action == 'show-system' || action == 'credential-manager') {
    await ensureReaderSettingVisible(tester, item);
  } else if (item.evaluate().isEmpty && !display) {
    await tester.scrollUntilVisible(
      item,
      160,
      scrollable: find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(item);
  await tester.pumpAndSettle();
  await tester.tap(item);
  await tester.pumpAndSettle();
  if (action == 'show-system') {
    await tester.tap(find.byKey(const Key('settings-back')));
    await tester.pumpAndSettle();
  }
}

Future<void> switchImage(WidgetTester tester, int id) async {
  await tester.tap(find.byKey(const Key('disk-navigation')));
  await tester.pumpAndSettle();
  final item = find.byKey(ValueKey('image-tab-$id'));
  if (item.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      item,
      160,
      scrollable: find
          .descendant(
            of: find.byType(Drawer),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 30,
    );
  }
  await tester.ensureVisible(item);
  await tester.tap(find.byKey(ValueKey('image-tab-$id')));
  await tester.pumpAndSettle();
}

Future<void> closePreview(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('navigate-back')));
  await tester.pumpAndSettle();
}
