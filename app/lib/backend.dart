import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'platform_storage.dart';

class ReaderFailure implements Exception {
  ReaderFailure(this.code, this.message, {this.invalidated = false});
  final String code;
  final String message;
  final bool invalidated;
  @override
  String toString() => message;
}

abstract class ReaderBackend {
  Future<Map<String, dynamic>> request(Map<String, dynamic> request);
  void beginOperation();
  void cancel();
  Future<void> dispose();
}

class _Bindings {
  _Bindings(String path) : library = DynamicLibrary.open(path) {
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'vhdx_api_version',
    )();
    if (version != 6) throw ReaderFailure('version', '读取组件版本不匹配，请重新解压完整程序。');
    request = library
        .lookupFunction<
          Pointer<Utf8> Function(Uint64, Pointer<Uint8>, UintPtr),
          Pointer<Utf8> Function(int, Pointer<Uint8>, int)
        >('vhdx_request');
    free = library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('vhdx_response_free');
    cancel = library.lookupFunction<Void Function(Uint64), void Function(int)>(
      'vhdx_cancel',
    );
  }
  final DynamicLibrary library;
  late final Pointer<Utf8> Function(int, Pointer<Uint8>, int) request;
  late final void Function(Pointer<Utf8>) free;
  late final void Function(int) cancel;
  int createContext() =>
      library.lookupFunction<Uint64 Function(), int Function()>(
        'vhdx_context_create',
      )();
  Map<String, dynamic> call(int context, Map<String, dynamic> value) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    final input = calloc<Uint8>(bytes.length);
    Pointer<Utf8> output = nullptr;
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      output = request(context, input, bytes.length);
      if (output == nullptr) throw ReaderFailure('internal', '读取组件没有返回结果。');
      return jsonDecode(output.toDartString()) as Map<String, dynamic>;
    } finally {
      input.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(input);
      bytes.fillRange(0, bytes.length, 0);
      if (output != nullptr) free(output);
    }
  }
}

void _readerIsolate(List<Object> args) {
  final parent = args[0] as SendPort;
  try {
    final bindings = _Bindings(args[1] as String);
    final inbox = ReceivePort();
    parent.send(['ready', inbox.sendPort]);
    inbox.listen((dynamic raw) {
      final message = raw as List;
      final id = message[0] as int;
      final request = Map<String, dynamic>.from(message[1] as Map);
      try {
        parent.send([id, bindings.call(args[2] as int, request)]);
      } catch (_) {
        parent.send([
          id,
          {
            'ok': false,
            'error': {'code': 'internal', 'message': '读取组件发生错误，请重新打开镜像。'},
          },
        ]);
      } finally {
        request.remove('secret');
      }
    });
  } catch (_) {
    parent.send([
      'startup_error',
      (Platform.isAndroid || Platform.isIOS)
          ? '无法加载读取组件，请重新安装完整应用。'
          : '无法加载读取组件。请完整解压程序，并保留 native 文件夹。',
    ]);
  }
}

class NativeBackend implements ReaderBackend {
  NativeBackend._(this._bindings, this._inbox, this._nativeDirectory)
    : _context = _bindings.createContext();
  final String? _nativeDirectory;
  final int _context;
  final _Bindings _bindings;
  final ReceivePort _inbox;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  late final Isolate _isolate;
  late final SendPort _commands;
  int _nextId = 0;
  int _session = 0;
  bool _cancelled = false;
  bool _disposed = false;
  int? _imageHandle;

  static Future<NativeBackend> start({String? libraryPath}) async {
    final filename = Platform.isWindows
        ? 'vhdx_app.dll'
        : Platform.isMacOS
        ? 'libvhdx_app.dylib'
        : 'libvhdx_app.so';
    final nativeDirectory = (Platform.isAndroid || Platform.isIOS)
        ? await PlatformStorage.nativeDirectory()
        : null;
    final path =
        libraryPath ??
        (Platform.isIOS
            ? '$nativeDirectory/vhdx_app.framework/vhdx_app'
            : null) ??
        (nativeDirectory == null ? null : "$nativeDirectory/$filename") ??
        (Platform.isMacOS
            ? '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/vhdx/$filename'
            : '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}native${Platform.pathSeparator}$filename');
    final inbox = ReceivePort();
    late final NativeBackend backend;
    try {
      backend = NativeBackend._(_Bindings(path), inbox, nativeDirectory);
    } catch (_) {
      inbox.close();
      throw ReaderFailure(
        'native',
        (Platform.isAndroid || Platform.isIOS)
            ? '无法加载读取组件，请重新安装完整应用。'
            : '无法加载读取组件。请完整解压程序，并保留 native 文件夹。',
      );
    }
    final ready = Completer<void>();
    inbox.listen((dynamic raw) {
      final message = raw as List;
      if (message[0] == 'ready') {
        backend._commands = message[1] as SendPort;
        ready.complete();
      } else if (message[0] == 'startup_error') {
        ready.completeError(ReaderFailure('native', message[1] as String));
      } else {
        backend._pending
            .remove(message[0])
            ?.complete(Map<String, dynamic>.from(message[1] as Map));
      }
    });
    backend._isolate = await Isolate.spawn(_readerIsolate, [
      inbox.sendPort,
      path,
      backend._context,
    ]);
    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      backend._isolate.kill();
      inbox.close();
      rethrow;
    }
    return backend;
  }

  @override
  void beginOperation() => _cancelled = false;
  @override
  void cancel() {
    _cancelled = true;
    _bindings.cancel(_context);
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    if (!Platform.isAndroid && !Platform.isIOS) return _requestRaw(request);
    if (_disposed) throw ReaderFailure('closed', '读取组件已关闭。');
    final input = Map<String, dynamic>.from(request);
    int? handle;
    try {
      final op = input['op'];
      if (op == 'open') input['native_directory'] = _nativeDirectory;
      final key = op == 'open'
          ? 'path'
          : op == 'unlock'
          ? 'credential_file'
          : op == 'export'
          ? 'output'
          : null;
      final uri = key == null ? null : input[key];
      if (uri is String && PlatformStorage.isDocument(uri)) {
        final descriptor = await PlatformStorage.open(
          uri,
          write: op == 'export',
        );
        handle = descriptor['handle'] as int;
        input[op == 'open'
                ? 'fd'
                : op == 'unlock'
                ? 'credential_fd'
                : 'output_fd'] =
            descriptor['fd'];
        if (op == 'unlock') input.remove('credential_file');
      }
      final result = await _requestRaw(input);
      if (Platform.isIOS &&
          (op == 'open' || op == 'close' || op == 'dispose')) {
        final previous = _imageHandle;
        _imageHandle = op == 'open' ? handle : null;
        if (op == 'open') handle = null;
        if (previous != null) await PlatformStorage.close(previous);
      }
      return result;
    } on PlatformException catch (e) {
      throw ReaderFailure('document', e.message ?? '无法访问所选文件。');
    } finally {
      input.remove('secret');
      if (handle != null) await PlatformStorage.close(handle);
    }
  }

  Future<Map<String, dynamic>> _requestRaw(Map<String, dynamic> request) async {
    if (_disposed) throw ReaderFailure('closed', '读取组件已关闭。');
    if (_cancelled) throw ReaderFailure('cancelled', '操作已取消。');
    if (_pending.length >= 8) throw ReaderFailure('busy', '操作过多，请稍后重试。');
    final id = _nextId++;
    final complete = Completer<Map<String, dynamic>>();
    _pending[id] = complete;
    _commands.send([
      id,
      {
        ...request,
        if (!{
          'open',
          'dispose',
          'vault_list',
          'vault_remove',
          'vault_clear',
        }.contains(request['op']))
          'session': _session,
      },
    ]);
    final response = await complete.future;
    if (response['session'] is int) _session = response['session'] as int;
    if (response['ok'] != true) {
      final error = response['error'] as Map;
      throw ReaderFailure(
        error['code'] as String,
        error['message'] as String,
        invalidated: response['invalidated'] == true,
      );
    }
    return Map<String, dynamic>.from(response['data'] as Map);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    cancel();
    _cancelled = false;
    try {
      await request({'op': 'dispose'}).timeout(const Duration(seconds: 5));
    } catch (_) {
      /* Process teardown may already be underway. */
    }
    _disposed = true;
    _isolate.kill();
    _inbox.close();
    for (final pending in _pending.values) {
      pending.completeError(ReaderFailure('closed', '读取组件已关闭。'));
    }
    _pending.clear();
  }
}
