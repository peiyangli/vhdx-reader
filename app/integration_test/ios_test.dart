import 'vault_test.dart' as vault;
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/platform_storage.dart';
import 'native_test.dart' as native;
import 'test_configuration.dart';
import 'pdf_test.dart' as pdf;
import 'media_test.dart' as media;

Future<String> document(String name) async {
  final result = await PlatformStorage.channel.invokeListMethod<dynamic>(
    'testRegisterDocument',
    {'name': name},
  );
  return result!.single['uri'] as String;
}

Future<void> main() async {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final root = (await PlatformStorage.channel.invokeMethod<String>(
    'testFixtureDirectory',
  ))!;
  fixtureOverrides.addAll({
    'VHDX_SAMPLE_DIR': root,
    'VHDX_PDF_FIXTURE': '$root/pdf-preview.vhdx',
    'VHDX_MEDIA_FIXTURE': '$root/media-preview.vhdx',
    'VHDX_SCREENSHOT': '$root/native.png',
    'VHDX_PDF_SCREENSHOT': '$root/pdf.png',
    'VHDX_MEDIA_SCREENSHOT': '$root/video.png',
  });
  testWidgets(
    'iOS scoped descriptors survive unlock and independent tabs, then release',
    (tester) async {
      final initial = await PlatformStorage.channel.invokeMethod<int>(
        'testLeaseCount',
      );
      final first = await NativeBackend.start();
      final second = await NativeBackend.start();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.request({
        'op': 'open',
        'path': await document('bitlockervhdx.vhdx'),
      });
      await first.request({
        'op': 'unlock',
        'partition': 1,
        'mode': 'password',
        'credential_file': await document('password.txt'),
      });
      await second.request({
        'op': 'open',
        'path': await document('basicvhdx.vhdx'),
      });
      expect(
        await PlatformStorage.channel.invokeMethod<int>('testLeaseCount'),
        initial! + 2,
      );
      await second.dispose();
      final read = await first.request({
        'op': 'read',
        'path': '/hello.txt',
        'offset': 0,
        'length': 16,
      });
      expect(read['size'], 5);
      expect(
        await PlatformStorage.channel.invokeMethod<int>('testLeaseCount'),
        initial + 1,
      );
      await first.dispose();
      expect(
        await PlatformStorage.channel.invokeMethod<int>('testLeaseCount'),
        initial,
      );
    },
  );
  tearDownAll(() async {
    if (const bool.fromEnvironment('VHDX_COLLECT_SCREENSHOTS')) {
      await File('$root/.complete').writeAsString('ready');
      for (var i = 0; i < 120; i++) {
        if (await File('$root/.copied').exists()) return;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      fail('Host did not collect the iOS test screenshots');
    }
  });
  vault.main();
  native.main();
  pdf.main();
  media.main();
}
