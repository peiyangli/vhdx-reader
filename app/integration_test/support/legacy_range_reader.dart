import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:vhdx_reader/backend.dart';

/// A file token is bound to its original volume in Rust. It cannot start reading
/// another partition after a lock or switch, even if the path is identical.
class LegacyRangeReader {
  LegacyRangeReader._(this.backend, this.file, this.size);
  final ReaderBackend backend;
  final int file;
  final int size;
  static const pageSize = 64 * 1024;
  static const maxPages = 16;
  final _pages = <int, Uint8List>{};
  Future<void> _tail = Future.value();
  bool _closed = false;
  ReaderFailure? failure;
  void Function(ReaderFailure)? onError;
  int fetchedBytes = 0;

  static Future<LegacyRangeReader> open(
    ReaderBackend backend,
    String path,
  ) async {
    final result = await backend.request({'op': 'file_open', 'path': path});
    return LegacyRangeReader._(
      backend,
      result['file'] as int,
      result['size'] as int,
    );
  }

  Future<int> read(Uint8List buffer, int position, int length) {
    final result = _tail.then((_) => _read(buffer, position, length));
    // Serialize callbacks without retaining failed futures or poisoning the queue.
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _check() {
    if (_closed) throw ReaderFailure('closed', '文件预览已关闭。');
    if (failure != null) throw failure!;
  }

  Future<int> _read(Uint8List buffer, int position, int length) async {
    _check();
    if (position < 0 || length < 0 || length > buffer.length) {
      throw ReaderFailure('invalid', 'PDF 读取范围无效。');
    }
    final count = math.min(length, math.max(0, size - position));
    var done = 0;
    try {
      while (done < count) {
        _check();
        final at = position + done;
        final page = at ~/ pageSize;
        var bytes = _pages.remove(page);
        if (bytes == null) {
          final wanted = math.min(pageSize, size - page * pageSize);
          final response = await backend.request({
            'op': 'file_read',
            'file': file,
            'offset': page * pageSize,
            'length': wanted,
          });
          bytes = base64Decode(response['bytes'] as String);
          if (_closed || bytes.length != wanted) {
            bytes.fillRange(0, bytes.length, 0);
            _check();
            throw ReaderFailure('io', 'PDF 数据不完整，请检查存储设备后重新打开。');
          }
          fetchedBytes += bytes.length;
        }
        _pages[page] = bytes;
        while (_pages.length > maxPages) {
          final evicted = _pages.remove(_pages.keys.first)!;
          evicted.fillRange(0, evicted.length, 0);
        }
        final within = at % pageSize;
        final n = math.min(count - done, bytes.length - within);
        buffer.setRange(done, done + n, bytes, within);
        done += n;
      }
      return done;
    } on ReaderFailure catch (error) {
      if (!_closed) {
        failure = error;
        _clearCache();
        onError?.call(error);
      }
      rethrow;
    }
  }

  void _clearCache() {
    for (final page in _pages.values) {
      page.fillRange(0, page.length, 0);
    }
    _pages.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    onError = null;
    _clearCache();
    try {
      await backend.request({'op': 'file_close', 'file': file});
    } catch (_) {
      /* Lock, device failure, or context disposal already invalidates this handle. */
    }
  }
}
