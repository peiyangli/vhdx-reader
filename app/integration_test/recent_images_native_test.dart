import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/recent_images.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android recent document survives store and reader recreation', (
    tester,
  ) async {
    const path =
        'content://org.vhdxreader.vhdx_reader.uitest.fixtures/basicvhdx.vhdx';
    final directory = await Directory.systemTemp.createTemp('recent-native-');
    var store = RecentImagesStore(directory: directory);
    Future<void> waitFor(bool Function() ready) async {
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (ready()) return;
      }
      fail('Recent document did not become ready');
    }

    try {
      await tester.pumpWidget(
        ReaderApp(
          backend: await NativeBackend.start(),
          initialImage: path,
          recents: store,
        ),
      );
      await waitFor(
        () =>
            find.text('can.txt').evaluate().isNotEmpty &&
            store.items.isNotEmpty,
      );
      // Wait for the real persistent write; recreate both history and native
      // reader to verify the shortcut uses a saved SAF URI without a picker.
      await store.record(path, 'basicvhdx.vhdx');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      store.dispose();
      store = RecentImagesStore(directory: directory);
      await store.load();
      expect(store.items.single.path, path);
      await tester.pumpWidget(
        ReaderApp(
          backend: await NativeBackend.start(),
          recents: store,
          pickImages: () async =>
              throw StateError('Recent shortcut must not invoke picker'),
        ),
      );
      await tester.pumpAndSettle();
      final recent = find.byKey(const ValueKey('recent-image-$path'));
      await tester.ensureVisible(recent);
      await tester.tap(recent);
      await waitFor(() => find.text('can.txt').evaluate().isNotEmpty);
      expect(store.items, hasLength(1));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await store.clear();
      store.dispose();
      await directory.delete(recursive: true);
    }
  });
}
