import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/main.dart';
import '../test/ui_actions.dart';
import 'test_configuration.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'saved cache preferences reach native unlock and remain editable',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'vhdx-cache-integration-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = CacheSettingsStore(directory: directory);
      await store.save(
        const CacheSettings(
          plaintextMiB: 16384,
          plaintextPageKiB: 1024,
          ciphertextMiB: 4,
        ),
      );
      final settings = await CacheSettingsStore(directory: directory).load();
      final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
      final backend = await NativeBackend.start();
      addTearDown(backend.dispose);
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: '$root${Platform.pathSeparator}basicvhdx.vhdx',
          cacheSettings: settings,
          saveCacheSettings: store.save,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('can.txt'), findsOneWidget);
      await openReaderSettings(tester);
      await ensureReaderSettingVisible(
        tester,
        find.byKey(const Key('cache-plaintext')),
      );
      expect(find.text('16 GiB / 卷'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cache-plaintext')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cache-plaintext-128')));
      await tester.tap(find.byKey(const Key('cache-plaintext-128')));
      await tester.pumpAndSettle();
      // File persistence runs outside frame scheduling; wait for completion.
      for (
        var attempt = 0;
        attempt < 50 && find.text('128 MiB / 卷').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('128 MiB / 卷'), findsOneWidget);
      expect((await store.load()).plaintextMiB, 128);
      expect((await store.load()).plaintextPageKiB, 1024);
      await tester.tap(find.byKey(const Key('settings-back')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('can.txt'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('navigate-back')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
