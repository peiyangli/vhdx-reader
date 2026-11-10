import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/preview.dart';
import '../test/ui_actions.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/range_reader.dart';
import 'test_configuration.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'binary NTFS and BitLocker bytes match JSON, EOF, cancellation and cached lock',
    (tester) async {
      final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
      final fixture = Platform.environment['VHDX_PREVIEW_FIXTURE_DIR']!;
      for (final encrypted in [false, true]) {
        final backend = await NativeBackend.start();
        try {
          await backend.request({
            'op': 'open',
            'path': encrypted
                ? '$root/bitlockervhdx.vhdx'
                : '$fixture/preview.vhdx',
          });
          await backend.request({
            'op': 'unlock',
            'partition': 1,
            'mode': encrypted ? 'password' : 'none',
            if (encrypted) 'credential_file': '$root/password.txt',
          });
          final path = encrypted ? '/\$LogFile' : '/near-limit.bmp';
          final reader = await BackendRangeReader.open(backend, path);
          final reference = encrypted
              ? null
              : await File('$fixture/near-limit.bmp').readAsBytes();
          for (var offset = 0; offset < reader.size; offset += 1048576) {
            final bytes = await backend.readFileBytes(
              reader.file,
              offset,
              1048576,
            );
            final json = await backend.request({
              'op': 'file_read',
              'file': reader.file,
              'offset': offset,
              'length': 1048576,
            });
            expect(bytes, base64Decode(json['bytes'] as String));
            if (reference != null) {
              expect(
                bytes,
                reference.sublist(
                  offset,
                  (offset + 1048576).clamp(0, reference.length),
                ),
              );
            }
            bytes.fillRange(0, bytes.length, 0);
          }
          expect(
            await backend.readFileBytes(reader.file, reader.size, 64),
            isEmpty,
          );
          await expectLater(
            backend.readFileBytes(reader.file, 0, 1048577),
            throwsA(isA<ReaderFailure>()),
          );
          final pending = backend.readFileBytes(reader.file, 0, 1048576);
          final cancelled = expectLater(pending, throwsA(isA<ReaderFailure>()));
          backend.cancel();
          backend
              .beginOperation(); // A late result must not become valid again.
          await cancelled;
          backend.cancel();
          await reader
              .close(); // Revocation reaches worker even after cancellation.
          backend.beginOperation();
          await expectLater(
            backend.readFileBytes(reader.file, 0, 1),
            throwsA(isA<ReaderFailure>()),
          );
          final next = await BackendRangeReader.open(backend, path);
          await next.read(Uint8List(8), 0, 8);
          expect(next.cachedBytes, greaterThan(0));
          await backend.request({'op': 'lock'});
          await expectLater(
            next.read(Uint8List(8), 0, 8),
            throwsA(isA<ReaderFailure>()),
          );
          expect(next.cachedBytes, 0);
          await next.close();
        } finally {
          await backend.dispose();
        }
      }
    },
  );
  testWidgets(
    'near-limit image displays and closing clears its encoded bytes',
    (tester) async {
      final fixture = Platform.environment['VHDX_PREVIEW_FIXTURE_DIR']!;
      final backend = await NativeBackend.start();
      await tester.pumpWidget(
        ReaderApp(backend: backend, initialImage: '$fixture/preview.vhdx'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('near-limit.bmp'));
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final images = find.descendant(
          of: find.byType(InteractiveViewer),
          matching: find.byType(RawImage),
        );
        if (images.evaluate().isNotEmpty &&
            tester.widget<RawImage>(images.first).image != null) {
          break;
        }
      }
      final image = find.descendant(
        of: find.byType(InteractiveViewer),
        matching: find.byType(RawImage),
      );
      expect(image, findsOneWidget);
      expect(tester.widget<RawImage>(image).image, isNotNull);
      final bytes = tester
          .widget<PreviewScreen>(find.byType(PreviewScreen))
          .data
          .bytes!;
      expect(bytes.length, 16560054);
      await closePreview(tester);
      await tester.pumpAndSettle();
      expect(bytes.every((b) => b == 0), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
  testWidgets('dispose rejects an in-flight binary result', (tester) async {
    final fixture = Platform.environment['VHDX_PREVIEW_FIXTURE_DIR']!;
    final backend = await NativeBackend.start();
    await backend.request({'op': 'open', 'path': '$fixture/preview.vhdx'});
    await backend.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
    final reader = await BackendRangeReader.open(backend, '/near-limit.bmp');
    final pending = expectLater(
      backend.readFileBytes(reader.file, 0, 1048576),
      throwsA(isA<ReaderFailure>()),
    );
    await backend.dispose();
    await pending;
    await reader.close();
  });
}
