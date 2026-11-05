import 'test_configuration.dart';
import '../test/ui_actions.dart';
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
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const Key('disk-navigation')), findsNothing);
    await closePreview(tester);
    await browserAction(
      tester,
      'open-image',
      legacy: find.byTooltip('添加镜像（可多选）'),
    );
    await tester.pumpAndSettle();
    // Native startup is asynchronous. A saved device credential may also unlock
    // this fixture automatically; leave the user's vault untouched in either case.
    final lockedView = find.text('解锁 BitLocker 分区');
    final unlockedFile = find.text('hello.txt');
    for (
      var i = 0;
      i < 100 &&
          lockedView.evaluate().isEmpty &&
          unlockedFile.evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('bitlockervhdx.vhdx'), findsOneWidget);
    expect(
      lockedView.evaluate().isNotEmpty || unlockedFile.evaluate().isNotEmpty,
      isTrue,
      reason:
          'The added encrypted image must show its unlock screen or successfully auto-unlock',
    );
    await switchImage(tester, 0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('can.txt'));
    await tester.pumpAndSettle();
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
    Future<void> captureView(String suffix) async {
      if (output == null) return;
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final snapshot = await boundary.toImage();
      final bytes = await snapshot.toByteData(format: ui.ImageByteFormat.png);
      await File(
        output.replaceFirst(RegExp(r'\.png$'), '.$suffix.png'),
      ).writeAsBytes(bytes!.buffer.asUint8List());
      snapshot.dispose();
    }

    await closePreview(tester);
    await captureView('list');
    await openReaderSettings(tester);
    await captureView('settings');
    await tester.tap(find.byKey(const Key('settings-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('disk-navigation')));
    await tester.pumpAndSettle();
    await captureView('images');
    await tester.tap(find.byKey(const ValueKey('image-tab-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('display-menu')));
    await tester.pumpAndSettle();
    await captureView('menu');
    await tester.tap(find.byKey(const Key('view-grid')));
    await tester.pumpAndSettle();
    await captureView('grid');
    await tester.tap(find.text('can.txt'));
    await tester.pumpAndSettle();
    await closePreview(tester);
    await switchImage(tester, 1);
    await browserAction(tester, 'close-image');
    expect(find.text('can.txt'), findsWidgets);
    await tester.tap(find.text('can.txt'));
    await tester.pumpAndSettle();
    expect(find.byType(SelectableText), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
