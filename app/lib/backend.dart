import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'platform_storage.dart';
import 'native_media.dart';

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

/// Optional capability: test/remote backends can retain the JSON contract.
abstract class BinaryReaderBackend {
  int get readEpoch;
  Future<Uint8List> readFileBytes(int file, int offset, int length);
}

extension ReaderBytes on ReaderBackend {
  Future<Uint8List> readFileBytes(int file, int offset, int length) async {
    final backend = this;
    if (backend is BinaryReaderBackend) {
      return (backend as BinaryReaderBackend).readFileBytes(
        file,
        offset,
        length,
      );
    }
    final data = await request({
      'op': 'file_read',
      'file': file,
      'offset': offset,
      'length': length,
    });
    return base64Decode(data['bytes'] as String);
  }
}

class _Bindings {
  _Bindings(String path) : library = DynamicLibrary.open(path) {
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
      'vhdx_api_version',
    )();
    if (version != 10) throw ReaderFailure('version', '读取组件版本不匹配，请重新解压完整程序。');
    NativeMedia.library = library;
    request = library
        .lookupFunction<
          Pointer<Utf8> Function(Uint64, Pointer<Uint8>, UintPtr),
          Pointer<Utf8> Function(int, Pointer<Uint8>, int)
        >('vhdx_request');
    readFile = library
        .lookupFunction<
          Pointer<Utf8> Function(
            Uint64,
            Uint64,
            Uint64,
            Uint64,
            UintPtr,
            Pointer<Uint8>,
          ),
          Pointer<Utf8> Function(int, int, int, int, int, Pointer<Uint8>)
        >('vhdx_file_read');
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
  late final Pointer<Utf8> Function(int, int, int, int, int, Pointer<Uint8>)
  readFile;

  Map<String, dynamic> callBytes(int context, Map<String, dynamic> request) {
    final length = request['length'] as int;
    if (length < 0 || length > 1024 * 1024 || (request['offset'] as int) < 0) {
      throw ReaderFailure('invalid', '读取范围无效。');
    }
    final buffer = calloc<Uint8>(length == 0 ? 1 : length);
    Pointer<Utf8> metadata = nullptr;
    try {
      metadata = readFile(
        context,
        request['session'] as int,
        request['file'] as int,
        request['offset'] as int,
        length,
        buffer,
      );
      if (metadata == nullptr) throw ReaderFailure('internal', '读取组件没有返回结果。');
      final response =
          jsonDecode(metadata.toDartString()) as Map<String, dynamic>;
      if (response['ok'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final count = data['length'] as int;
        if (count < 0 || count > length) {
          throw ReaderFailure('internal', '读取长度无效。');
        }
        // Copies once into VM-owned transferable storage; no Base64 or UI decode.
        data['bytes'] = TransferableTypedData.fromList([
          buffer.asTypedList(count),
        ]);
      }
      return response;
    } finally {
      buffer.asTypedList(length).fillRange(0, length, 0);
      calloc.free(buffer);
      if (metadata != nullptr) free(metadata);
    }
  }

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
        parent.send([
          id,
          message.length > 2 && message[2] == true
              ? bindings.callBytes(args[2] as int, request)
              : bindings.call(args[2] as int, request),
        ]);
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

class NativeBackend implements ReaderBackend, BinaryReaderBackend {
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
  @override
  int get readEpoch => _readEpoch;
  int _readEpoch = 0;
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
        final response = Map<String, dynamic>.from(message[1] as Map);
        final data = response['data'];
        Uint8List? bytes;
        if (data is Map && data['bytes'] is TransferableTypedData) {
          bytes = (data['bytes'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          data['bytes'] = bytes;
        }
        final pending = backend._pending.remove(message[0]);
        if (pending == null) {
          bytes?.fillRange(0, bytes.length, 0);
        } else {
          pending.complete(response);
        }
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
    _readEpoch++;
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

  @override
  Future<Uint8List> readFileBytes(int file, int offset, int length) async {
    if (offset < 0 || length < 0 || length > 1024 * 1024) {
      throw ReaderFailure('invalid', '读取范围无效。');
    }
    final data = await _requestRaw({
      'op': 'file_read',
      'file': file,
      'offset': offset,
      'length': length,
    }, binary: true);
    return data['bytes'] as Uint8List;
  }

  Future<Map<String, dynamic>> _requestRaw(
    Map<String, dynamic> request, {
    bool binary = false,
  }) async {
    if (_disposed) throw ReaderFailure('closed', '读取组件已关闭。');
    // Revocation must still reach the worker after an operation was cancelled.
    // Otherwise disposing a cancelled preview leaks its live media capability.
    if (_cancelled &&
        !{
          'disk_cache_configure',
          'disk_cache_clear',
          'disk_cache_status',
          'media_close',
          'file_close',
          'thumbnail_cancel',
          'thumbnail_finish',
        }.contains(request['op'])) {
      throw ReaderFailure('cancelled', '操作已取消。');
    }
    // These Rust operations only touch bounded metadata. Calling them here
    // lets cancellation/deadline control bypass an isolate blocked in media_open.
    if ({
      'thumbnail_begin',
      'thumbnail_cancel',
      'thumbnail_finish',
    }.contains(request['op'])) {
      final response = _bindings.call(_context, {
        ...request,
        if (request['op'] == 'thumbnail_begin') 'session': _session,
      });
      if (response['ok'] != true) {
        final error = response['error'] as Map;
        throw ReaderFailure(
          error['code'] as String,
          error['message'] as String,
        );
      }
      return Map<String, dynamic>.from(response['data'] as Map);
    }
    if (_pending.length >= 8) throw ReaderFailure('busy', '操作过多，请稍后重试。');
    if ({
      'open',
      'unlock',
      'unlock_saved',
      'lock',
      'close',
      'dispose',
    }.contains(request['op'])) {
      _readEpoch++;
    }
    final epoch = _readEpoch;
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
          'disk_cache_configure',
          'disk_cache_clear',
          'disk_cache_status',
        }.contains(request['op']))
          'session': _session,
      },
      binary,
    ]);
    final response = await complete.future;
    if (binary && (_disposed || _cancelled || epoch != _readEpoch)) {
      final bytes = (response['data'] as Map?)?['bytes'];
      if (bytes is Uint8List) bytes.fillRange(0, bytes.length, 0);
      throw ReaderFailure('cancelled', '此读取已取消或会话已关闭。');
    }
    if (response['invalidated'] == true) _readEpoch++;
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
