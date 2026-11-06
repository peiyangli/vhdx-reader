import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';
import 'package:vhdx_reader/recent_images.dart';
import 'reader_test.dart' show FakeBackend;

class FailedImageBackend extends FakeBackend {
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
    if (value['op'] == 'open') throw ReaderFailure('invalid', '无法读取镜像');
    return super.request(value);
  }
}

void main() {
  test(
    'recent locations persist, deduplicate and serialize writes; clear removes bookmarks',
    () async {
      final directory = await Directory.systemTemp.createTemp('recent-images-');
      final store = RecentImagesStore(directory: directory, limit: 2);
      try {
        await Future.wait([
          store.record('/one.vhdx', '一.vhdx'),
          store.record('/two.vhdx', '二.vhdx'),
          store.record('/three.vhdx', '三.vhdx'),
        ]);
        await store.record('/two.vhdx', '二.vhdx');
        await store.attachBookmark('/two.vhdx', 'opaque-bookmark');
        final reopened = RecentImagesStore(directory: directory, limit: 2);
        await reopened.load();
        expect(reopened.items.map((e) => e.path), ['/two.vhdx', '/three.vhdx']);
        expect(reopened.items.first.bookmark, 'opaque-bookmark');
        await reopened.remove('/two.vhdx');
        await reopened.attachBookmark('/two.vhdx', 'late-result');
        expect(reopened.items.map((e) => e.path), ['/three.vhdx']);
        await reopened.clear();
        final empty = RecentImagesStore(directory: directory);
        await empty.load();
        expect(empty.items, isEmpty);
        empty.dispose();
        reopened.dispose();
      } finally {
        store.dispose();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    testWidgets(
      '$platform recent shortcut loads an image without bypassing unlock',
      (tester) async {
        final store = RecentImagesStore.memory();
        await store.record('/recent.vhdx', 'recent.vhdx');
        final backend = FakeBackend();
        await tester.pumpWidget(
          ReaderApp(backend: backend, platform: platform, recents: store),
        );
        await tester.pumpAndSettle();
        final recent = find.byKey(const ValueKey('recent-image-/recent.vhdx'));
        await tester.ensureVisible(recent);
        await tester.tap(recent);
        await tester.pumpAndSettle();
        expect(backend.ops.where((e) => e == 'open').length, 1);
        expect(backend.ops, isNot(contains('unlock')));
        expect(backend.ops, isNot(contains('unlock_saved')));
        expect(find.byKey(const Key('unlock-button')), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        store.dispose();
      },
    );
  }

  testWidgets(
    'recent shortcut focuses an already unlocked tab without reopening it',
    (tester) async {
      final store = RecentImagesStore.memory();
      final backend = FakeBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          platform: TargetPlatform.windows,
          initialImage: '/loaded.vhdx',
          recents: store,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('unlock-secret')), 'fixture');
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('disk-navigation')));
      await tester.pumpAndSettle();
      final recent = find.byKey(const ValueKey('recent-image-/loaded.vhdx'));
      await tester.scrollUntilVisible(
        recent,
        160,
        scrollable: find
            .descendant(
              of: find.byType(Drawer),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(recent);
      await tester.tap(recent);
      await tester.pumpAndSettle();
      expect(backend.ops.where((e) => e == 'open').length, 1);
      expect(backend.ops.where((e) => e == 'unlock').length, 1);
      expect(find.text('notes.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      store.dispose();
    },
  );

  testWidgets('failed image opens do not enter recent history', (tester) async {
    final store = RecentImagesStore.memory();
    await tester.pumpWidget(
      ReaderApp(
        backend: FailedImageBackend(),
        initialImage: '/missing.vhdx',
        recents: store,
      ),
    );
    await tester.pumpAndSettle();
    expect(store.items, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    store.dispose();
  });

  testWidgets('forwarded desktop launches deduplicate existing image tabs', (
    tester,
  ) async {
    final backend = FakeBackend();
    var created = 0;
    await tester.pumpWidget(
      ReaderApp(
        backend: backend,
        platform: TargetPlatform.windows,
        createBackend: () async {
          created++;
          return FakeBackend();
        },
      ),
    );
    await tester.pumpAndSettle();
    Future<void> launch(List<String> paths) async {
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'vhdx_reader/window',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('openImages', paths),
        ),
        (_) {},
      );
      await tester.pumpAndSettle();
    }

    await launch(['/one.vhdx']);
    await launch(['/one.vhdx', '/two.vhdx']);
    expect(created, 1);
    expect(backend.ops.where((e) => e == 'open').length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
