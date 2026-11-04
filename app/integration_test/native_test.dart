import 'test_configuration.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native desktop opens and unlocks the private sample with password.txt',
    (tester) async {
      final root = fixtureSetting('VHDX_SAMPLE_DIR');
      expect(
        root,
        isNotNull,
        reason: 'Set VHDX_SAMPLE_DIR to the private examples directory',
      );
      final backend = await NativeBackend.start();
      addTearDown(backend.dispose);
      final image = await backend.request({
        'op': 'open',
        'path': '$root${Platform.pathSeparator}bitlockervhdx.vhdx',
      });
      expect(image['virtual_size'], 134217728);
      await backend.request({
        'op': 'unlock',
        'partition': 1,
        'mode': 'password',
        'credential_file': '$root${Platform.pathSeparator}password.txt',
      });
      final entries = await backend.request({
        'op': 'list',
        'path': '/',
        'start': 0,
        'limit': 200,
        'show_system': false,
      });
      expect(
        (entries['entries'] as List).any((e) => e['name'] == 'hello.txt'),
        isTrue,
      );
      // A second real FFI client must not replace the unlocked encrypted image.
      final other = await NativeBackend.start();
      addTearDown(other.dispose);
      await other.request({
        'op': 'open',
        'path': '$root${Platform.pathSeparator}basicvhdx.vhdx',
      });
      await other.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
      final plain = await other.request({
        'op': 'read',
        'path': '/can.txt',
        'offset': 0,
        'length': 64,
      });
      expect(plain['size'], 7);
      await other.request({'op': 'close'});
      final read = await backend.request({
        'op': 'read',
        'path': '/hello.txt',
        'offset': 0,
        'length': 1024,
      });
      expect(base64Decode(read['bytes'] as String).length, 5);
      await backend.request({'op': 'lock'});
      await expectLater(
        backend.request({
          'op': 'read',
          'path': '/hello.txt',
          'offset': 0,
          'length': 10,
        }),
        throwsA(isA<ReaderFailure>().having((e) => e.code, 'code', 'locked')),
      );
    },
  );
  testWidgets('desktop UI reads and previews the real ordinary sample', (
    tester,
  ) async {
    final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
    final backend = await NativeBackend.start();
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: ReaderApp(
          backend: backend,
          initialImage: '$root${Platform.pathSeparator}basicvhdx.vhdx',
          pickImages: () async => [
            '$root${Platform.pathSeparator}bitlockervhdx.vhdx',
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('can.txt'), findsOneWidget);
    await tester.tap(find.text('can.txt'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    final modalPreview = find.byType(Dialog).evaluate().isNotEmpty;
    if (modalPreview) {
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('添加镜像（可多选）'));
    await tester.pumpAndSettle();
    expect(find.text('解锁 BitLocker 分区'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('image-tab-0')));
    await tester.pumpAndSettle();
    if (modalPreview) {
      await tester.tap(find.text('can.txt'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(SelectableText), findsOneWidget);
    final output = fixtureSetting('VHDX_SCREENSHOT');
    if (output != null) {
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(output).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }
    if (modalPreview) {
      Navigator.of(tester.element(find.byType(Dialog))).pop();
      await tester.pumpAndSettle();
    }
    final closeOther = find.byKey(const ValueKey('close-tab-1'));
    if (modalPreview) {
      await tester.drag(
        find.ancestor(of: closeOther, matching: find.byType(ListView)).first,
        const Offset(-320, 0),
      );
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(closeOther);
    await tester.pumpAndSettle();
    for (
      var i = 0;
      i < 50 && tester.widget<IconButton>(closeOther).onPressed == null;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(closeOther);
    await tester.pumpAndSettle();
    for (var i = 0; i < 50 && closeOther.evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(closeOther, findsNothing);
    if (modalPreview) {
      await tester.tap(find.text('can.txt'));
      await tester.pumpAndSettle();
    }
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
