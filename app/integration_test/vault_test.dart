import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'test_configuration.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'OS vault saves only valid credentials, survives reopen and rename, deletes independently',
    (tester) async {
      final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
      var backend = await NativeBackend.start();
      addTearDown(() => backend.dispose());
      final path = '$root/bitlockervhdx.vhdx';
      await backend.request({'op': 'open', 'path': path});
      final status = await backend.request({
        'op': 'vault_status',
        'partition': 1,
      });
      expect(status['available'], true);
      final id = status['id'] as String;
      // Never remove an existing user's record during a test.
      expect(
        status['saved'],
        false,
        reason:
            'Use an isolated test app or remove this test fixture record before testing.',
      );
      addTearDown(() async {
        await backend.request({'op': 'vault_remove', 'id': id});
      });
      await expectLater(
        backend.request({
          'op': 'unlock',
          'partition': 1,
          'mode': 'password',
          'secret': 'deliberately-wrong-vault-fixture',
          'remember': true,
          'label': 'vault regression',
        }),
        throwsA(isA<ReaderFailure>()),
      );
      expect(
        (await backend.request({
          'op': 'vault_status',
          'partition': 1,
        }))['saved'],
        false,
      );
      final unlock = await backend.request({
        'op': 'unlock',
        'partition': 1,
        'mode': 'password',
        'credential_file': '$root/password.txt',
        'remember': true,
        'label': 'vault regression',
      });
      expect(
        unlock['remembered'],
        true,
        reason: unlock['remember_error'] as String?,
      );
      final listing = await backend.request({'op': 'vault_list'});
      final item =
          (listing['entries'] as List).singleWhere((e) => e['id'] == id) as Map;
      expect(item.keys.toSet(), {'id', 'label', 'mode', 'updated'});
      await backend.request({'op': 'lock'});
      // Bad replacement must not erase the valid previous credential.
      await expectLater(
        backend.request({
          'op': 'unlock',
          'partition': 1,
          'mode': 'password',
          'secret': 'still-wrong',
          'remember': true,
        }),
        throwsA(isA<ReaderFailure>()),
      );
      await backend.dispose();
      backend = await NativeBackend.start();
      final renamed = File('$root/vault-renamed-test.vhdx');
      await File(path).copy(renamed.path);
      addTearDown(() async {
        if (await renamed.exists()) await renamed.delete();
      });
      await backend.request({'op': 'open', 'path': renamed.path});
      expect(
        (await backend.request({'op': 'vault_status', 'partition': 1}))['id'],
        id,
      );
      await backend.request({'op': 'unlock_saved', 'partition': 1});
      expect(
        (await backend.request({
          'op': 'read',
          'path': '/hello.txt',
          'offset': 0,
          'length': 16,
        }))['size'],
        5,
      );
      final other = await NativeBackend.start();
      addTearDown(other.dispose);
      await other.request({'op': 'open', 'path': '$root/basicvhdx.vhdx'});
      expect(
        (await other.request({
          'op': 'vault_status',
          'partition': 1,
        }))['available'],
        false,
      );
      await backend.request({'op': 'vault_remove', 'id': id});
      // Removing a credential doesn't revoke an already open volume.
      expect(
        (await backend.request({
          'op': 'read',
          'path': '/hello.txt',
          'offset': 0,
          'length': 16,
        }))['size'],
        5,
      );
      await backend.request({'op': 'lock'});
      await expectLater(
        backend.request({'op': 'unlock_saved', 'partition': 1}),
        throwsA(
          isA<ReaderFailure>().having((e) => e.code, 'code', 'vault_missing'),
        ),
      );
      await backend.request({'op': 'close'});
    },
    // Saved unlock now requires a real system prompt and an attending user.
    skip: !const bool.fromEnvironment('VHDX_INTERACTIVE_AUTH_TESTS'),
  );
}
