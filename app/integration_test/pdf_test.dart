import 'test_configuration.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/range_reader.dart';

Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 150; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (condition()) return;
  }
  fail('Timed out waiting for PDF viewer');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final fixture = fixtureSetting('VHDX_PDF_FIXTURE');
  testWidgets(
    'PDFium renders two pages through real Rust file ranges without reading the 16 MiB gap',
    (tester) async {
      expect(
        fixture,
        isNotNull,
        reason: 'Set VHDX_PDF_FIXTURE to the generated PDF test VHDX',
      );
      final backend = await NativeBackend.start();
      addTearDown(backend.dispose);
      await backend.request({'op': 'open', 'path': fixture});
      await backend.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
      final reader = await BackendRangeReader.open(backend, '/guide.pdf');
      await pdfrxFlutterInitialize();
      final document = await PdfDocument.openCustom(
        read: reader.read,
        fileSize: reader.size,
        sourceName: 'range-regression',
        maxSizeToCacheOnMemory: 0,
      );
      try {
        expect(document.pages.length, 2);
        for (final page in document.pages) {
          final image = await page.render(
            width: 298,
            height: 421,
            fullWidth: 298,
            fullHeight: 421,
          );
          expect(image, isNotNull);
          expect(image!.pixels.any((value) => value != 255), isTrue);
          image.dispose();
        }
        expect(reader.size, greaterThan(16 * 1024 * 1024));
        expect(reader.fetchedBytes, lessThan(1024 * 1024));
      } finally {
        await document.dispose();
        await reader.close();
      }
      final held = await BackendRangeReader.open(backend, '/guide.pdf');
      await backend.request({'op': 'lock'});
      await expectLater(
        held.read(Uint8List(10), 0, 10),
        throwsA(isA<ReaderFailure>()),
      );
      await held.close();
    },
  );

  testWidgets(
    'PDF UI navigates, zooms, preserves page between image tabs, and reports corrupt files',
    (tester) async {
      final backend = await NativeBackend.start();
      final capture = GlobalKey();
      final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: ReaderApp(
            backend: backend,
            initialImage: fixture,
            pickImages: () async => [
              '$root${Platform.pathSeparator}basicvhdx.vhdx',
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('guide.pdf'));
      await waitFor(tester, () => find.text('/ 2').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('下一页'));
      await waitFor(
        tester,
        () =>
            tester
                .widget<TextField>(find.byKey(const Key('pdf-page-input')))
                .controller!
                .text ==
            '2',
      );
      await tester.tap(find.byTooltip('放大 PDF'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加镜像（可多选）'));
      await tester.pumpAndSettle();
      expect(find.text('can.txt'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('image-tab-0')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pdf-page-input')))
            .controller!
            .text,
        '2',
      );
      final output = fixtureSetting('VHDX_PDF_SCREENSHOT');
      if (output != null) {
        await tester.tap(find.text('适合页面'));
        await tester.pumpAndSettle();
        // PDFium renders asynchronously after the navigation animation settles.
        await tester.pump(const Duration(seconds: 1));
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(png!.buffer.asUint8List());
        image.dispose();
      }
      await tester.tap(find.text('返回文件列表'));
      await tester.pumpAndSettle();
      expect(find.text('guide.pdf'), findsOneWidget);
      await tester.tap(find.text('broken.pdf'));
      await waitFor(
        tester,
        () => find.textContaining('无法打开 PDF').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('返回文件列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('small.pdf'));
      await waitFor(tester, () => find.text('/ 2').evaluate().isNotEmpty);
      await tester.tap(find.byKey(const ValueKey('close-tab-0')));
      await tester.pumpAndSettle();
      expect(find.text('can.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
