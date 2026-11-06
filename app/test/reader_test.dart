import 'dart:convert';
import 'ui_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/main.dart';

class FakeBackend implements ReaderBackend {
  final ops = <String>[];
  bool reject = true;
  bool disposed = false;
  @override
  void beginOperation() {}
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    final op = request['op'] as String;
    ops.add(op);
    switch (op) {
      case 'open':
        return {
          'virtual_size': 134217728,
          'disk_type': 'dynamic',
          'partitions': [
            {'index': 1, 'length': 132120576, 'kind': 'BitLocker'},
          ],
        };
      case 'unlock':
        if (reject) throw ReaderFailure('wrong_credential', '密码或恢复密钥不正确，请重试。');
        return {};
      case 'list':
        return {
          'entries': [
            {
              'name': 'notes.txt',
              'directory': false,
              'size': 5,
              'attributes': 32,
            },
          ],
          'next_index': null,
        };
      case 'read':
        return {'bytes': base64Encode(utf8.encode('hello')), 'size': 5};
      default:
        return {};
    }
  }
}

void main() {
  testWidgets(
    'old mobile native library cannot silently bypass device authentication',
    (tester) async {
      final backend = VaultBackend()
        ..saved = true
        ..supportsDeviceAuthentication = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'saved.vhdx',
          platform: TargetPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      expect(backend.ops.where((op) => op == 'unlock_saved'), isEmpty);
      expect(find.byKey(const Key('unlock-saved')), findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('remember-credential')),
            )
            .onChanged,
        isNull,
      );
      expect(find.textContaining('读取组件尚不支持身份验证'), findsOneWidget);
      expect(find.byKey(const Key('unlock-secret')), findsOneWidget);
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final code in [
      'vault_auth_cancelled',
      'vault_auth_unavailable',
      'vault_auth_busy',
    ]) {
      testWidgets(
        '$platform $code keeps saved unlock locked until retry succeeds',
        (tester) async {
          tester.view.physicalSize = const Size(1400, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final backend = VaultBackend()
            ..saved = true
            ..authError = code;
          await tester.pumpWidget(
            ReaderApp(
              backend: backend,
              initialImage: 'saved.vhdx',
              platform: platform,
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('notes.txt'), findsNothing);
          expect(find.text('在此设备记住，验证身份后解锁'), findsOneWidget);
          expect(find.text('验证身份并解锁'), findsOneWidget);
          expect(backend.saved, isTrue);
          expect(backend.ops.where((op) => op == 'unlock_saved').length, 1);
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('unlock-secret')))
                .controller!
                .text,
            isEmpty,
          );
          backend.authError = null;
          await tester.tap(find.byKey(const Key('unlock-saved')));
          await tester.pumpAndSettle();
          expect(find.text('notes.txt'), findsOneWidget);
          expect(backend.ops.where((op) => op == 'unlock_saved').length, 2);
        },
      );
    }
  }
  testWidgets(
    'manual password remains usable after cancelled device authentication',
    (tester) async {
      final backend = VaultBackend()
        ..saved = true
        ..authError = 'vault_auth_cancelled'
        ..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'saved.vhdx',
          platform: TargetPlatform.android,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('unlock-secret')),
        'fixture-only',
      );
      await tester.ensureVisible(find.byKey(const Key('unlock-button')));
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);
      expect(backend.ops.where((op) => op == 'unlock_saved').length, 1);
      expect(backend.lastRemember, isFalse);
      expect(backend.saved, isTrue);
    },
  );

  testWidgets('automatic unlock invalidation clears the stale image', (
    tester,
  ) async {
    final backend = VaultBackend()
      ..saved = true
      ..invalidateAuto = true;
    await tester.pumpWidget(
      ReaderApp(backend: backend, initialImage: 'gone.vhdx'),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择 VHDX 文件'), findsOneWidget);
    expect(find.text('解锁 BitLocker 分区'), findsNothing);
  });

  testWidgets(
    'saved credential auto unlocks once; manual lock and deletion do not auto reopen',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = VaultBackend()..saved = true;
      await tester.pumpWidget(
        ReaderApp(backend: backend, initialImage: 'saved.vhdx'),
      );
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);
      expect(find.byKey(const Key('unlock-secret')), findsNothing);
      expect(backend.ops.where((op) => op == 'unlock_saved').length, 1);
      await browserAction(tester, 'lock', legacy: find.text('锁定分区'));
      await tester.pumpAndSettle();
      expect(find.text('解锁 BitLocker 分区'), findsOneWidget);
      expect(backend.ops.where((op) => op == 'unlock_saved').length, 1);
      await browserAction(tester, 'credential-manager');

      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('删除记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(backend.saved, false);
      expect(find.text('没有已保存的解锁信息'), findsOneWidget);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('remember is opt-in; save failure preserves successful unlock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final backend = VaultBackend()
      ..reject = false
      ..saveFails = true;
    await tester.pumpWidget(
      ReaderApp(backend: backend, initialImage: 'saved.vhdx'),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('remember-credential')),
          )
          .value,
      false,
    );
    await tester.tap(find.byKey(const Key('remember-credential')));
    await tester.enterText(
      find.byKey(const Key('unlock-secret')),
      'fixture-only',
    );
    await tester.tap(find.byKey(const Key('unlock-button')));
    await tester.pumpAndSettle();
    expect(backend.lastRemember, true);
    expect(backend.saved, false);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('已解锁，但安全存储保存失败，下次仍需输入密码。'), findsOneWidget);
  });
  testWidgets(
    'stale saved credential falls back once without exposing the secret',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = VaultBackend()
        ..saved = true
        ..autoReject = true;
      await tester.pumpWidget(
        ReaderApp(backend: backend, initialImage: 'saved.vhdx'),
      );
      await tester.pumpAndSettle();
      expect(backend.ops.where((op) => op == 'unlock_saved').length, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('unlock-secret')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.textContaining('已保存的密码已失效'), findsOneWidget);
      expect(backend.saved, true);
    },
  );

  testWidgets(
    'phone layout opens drawer, unlocks and previews without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend()..reject = false;
      await tester.pumpWidget(
        ReaderApp(
          backend: backend,
          initialImage: 'phone.vhdx',
          platform: TargetPlatform.iOS,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('unlock-secret')), 'fake');
      await tester.ensureVisible(find.byKey(const Key('unlock-button')));
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsOneWidget);
      await closePreview(tester);
      await tester.pumpAndSettle();
      // A phone can remain landscape after leaving fullscreen video.
      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('notes.txt'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await closePreview(tester);
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      await browserAction(tester, 'lock', legacy: find.text('锁定分区'));
      await tester.pumpAndSettle();
      expect(find.text('解锁 BitLocker 分区'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpWidget(
        ReaderApp(backend: FakeBackend(), platform: TargetPlatform.iOS),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('disk-navigation')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'wrong password stays locked; correct password browses and previews; lock clears data',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final backend = FakeBackend();
      await tester.pumpWidget(
        ReaderApp(backend: backend, initialImage: 'test.vhdx'),
      );
      await tester.pumpAndSettle();
      expect(find.text('解锁 BitLocker 分区'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('unlock-secret')),
        'test-only-value',
      );
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      expect(find.text('密码或恢复密钥不正确，请重试。'), findsOneWidget);
      expect(find.text('notes.txt'), findsNothing);
      expect(
        (tester.widget<TextField>(
          find.byKey(const Key('unlock-secret')),
        )).controller!.text,
        isEmpty,
      );
      backend.reject = false;
      await tester.enterText(
        find.byKey(const Key('unlock-secret')),
        'another-test-only-value',
      );
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsOneWidget);
      await closePreview(tester);
      await browserAction(tester, 'lock', legacy: find.text('锁定分区'));
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsNothing);
      expect(find.text('解锁 BitLocker 分区'), findsOneWidget);
    },
  );
  testWidgets('empty window has open actions without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ReaderApp(backend: FakeBackend(), platform: TargetPlatform.iOS),
    );
    await tester.pumpAndSettle();
    expect(find.text('选择 VHDX 文件'), findsOneWidget);
  });
  testWidgets(
    'multiple images preserve directory and unlock state; duplicate focuses; close is isolated',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final first = FakeBackend()..reject = false;
      final second = FakeBackend()..reject = false;
      var picks = ['second.vhdx'];
      var creations = 0;
      await tester.pumpWidget(
        ReaderApp(
          backend: first,
          initialImage: 'first.vhdx',
          createBackend: () async {
            creations++;
            return second;
          },
          pickImages: () async => picks,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('unlock-secret')), 'fake');
      await tester.tap(find.byKey(const Key('unlock-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('notes.txt'));
      await tester.pumpAndSettle();
      expect(find.text('hello'), findsOneWidget);
      await closePreview(tester);
      await browserAction(
        tester,
        'open-image',
        legacy: find.byTooltip('添加镜像（可多选）'),
      );
      await tester.pumpAndSettle();
      expect(creations, 1);
      expect(find.text('解锁 BitLocker 分区'), findsOneWidget);
      await switchImage(tester, 0);
      await tester.pumpAndSettle();
      expect(find.text('notes.txt'), findsOneWidget);
      expect(first.ops.where((op) => op == 'unlock').length, 1);
      picks = ['first.vhdx'];
      await browserAction(
        tester,
        'open-image',
        legacy: find.byTooltip('添加镜像（可多选）'),
      );
      await tester.pumpAndSettle();
      expect(creations, 1);
      expect(first.ops.where((op) => op == 'open').length, 1);
      await switchImage(tester, 1);
      await tester.pumpAndSettle();
      await browserAction(
        tester,
        'close-image',
        legacy: find.byKey(const ValueKey('close-tab-1')),
      );
      await tester.pumpAndSettle();
      expect(second.disposed, isTrue);
      expect(first.disposed, isFalse);
      expect(find.text('notes.txt'), findsOneWidget);
      await browserAction(
        tester,
        'close-image',
        legacy: find.byKey(const ValueKey('close-tab-0')),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择 VHDX 文件'), findsOneWidget);
      expect(find.text('hello'), findsNothing);
    },
  );
}

class VaultBackend extends FakeBackend {
  bool saved = false;
  bool supportsDeviceAuthentication = true;
  bool autoReject = false;
  String? authError;
  bool saveFails = false;
  bool invalidateAuto = false;
  bool? lastRemember;
  static final id = 'v1-${List.filled(64, 'a').join()}';
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'vault_status':
        return {
          'available': true,
          'saved': saved,
          'id': id,
          if (supportsDeviceAuthentication) 'authentication_required': true,
        };
      case 'unlock_saved':
        ops.add('unlock_saved');
        if (invalidateAuto) {
          throw ReaderFailure('io', '设备已断开', invalidated: true);
        }
        if (authError != null) {
          throw ReaderFailure(authError!, '身份验证未完成，可重试或手动输入 BitLocker 密码。');
        }
        if (autoReject) throw ReaderFailure('wrong_credential', 'wrong');
        return {};
      case 'unlock':
        lastRemember = request['remember'] == true;
        await super.request(request);
        if (lastRemember! && !saveFails) saved = true;
        return {'remembered': lastRemember! ? !saveFails : null};
      case 'vault_list':
        return {
          'available': true,
          'entries': saved
              ? [
                  {
                    'id': id,
                    'label': 'saved.vhdx',
                    'mode': 'password',
                    'updated': 1,
                  },
                ]
              : [],
        };
      case 'vault_remove':
      case 'vault_clear':
        saved = false;
        return {};
      default:
        return super.request(request);
    }
  }
}
