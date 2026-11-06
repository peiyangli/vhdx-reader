import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/browser_settings.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/main.dart';
import '../test/ui_actions.dart';
import 'test_configuration.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'file presentation survives persistent store and native workspace recreation',
    (tester) async {
      final path = Platform.isAndroid
          ? 'content://org.vhdxreader.vhdx_reader.uitest.fixtures/basicvhdx.vhdx'
          : '${fixtureSetting('VHDX_SAMPLE_DIR')}${Platform.pathSeparator}basicvhdx.vhdx';
      final directory = await Directory.systemTemp.createTemp(
        'browser-native-',
      );
      var store = BrowserSettingsStore(directory: directory);
      Future<void> ready() async {
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(FileContents).evaluate().isNotEmpty) return;
        }
        fail('Reader did not become ready');
      }

      try {
        await tester.pumpWidget(
          ReaderApp(
            backend: await NativeBackend.start(),
            initialImage: path,
            browserSettings: await store.load(),
            saveBrowserSettings: store.save,
          ),
        );
        await ready();
        await browserAction(tester, 'view-grid');
        await browserAction(tester, 'sort-modified');
        await browserAction(tester, 'order-descending');
        await browserAction(tester, 'show-system');
        // load waits for all queued writes, then we discard the entire workspace.
        expect(
          (await store.load()).toJson(),
          const BrowserSettings(
            grid: true,
            sort: FileSort.modified,
            descending: true,
            showSystem: true,
          ).toJson(),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        store = BrowserSettingsStore(directory: directory);
        final restored = await store.load();
        await tester.pumpWidget(
          ReaderApp(
            backend: await NativeBackend.start(),
            initialImage: path,
            browserSettings: restored,
            saveBrowserSettings: store.save,
          ),
        );
        await ready();
        final contents = tester.widget<FileContents>(find.byType(FileContents));
        expect(contents.grid, true);
        expect(contents.sort, FileSort.modified);
        expect(contents.descending, true);
        await openReaderSettings(tester);
        expect(
          tester
              .widget<SwitchListTile>(find.byKey(const Key('show-system')))
              .value,
          true,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await directory.delete(recursive: true);
      }
    },
  );
}
