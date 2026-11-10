import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'backend.dart';

/// A file token is bound to its original volume in Rust. It cannot start reading
/// another partition after a lock or switch, even if the path is identical.
class BackendRangeReader {
  BackendRangeReader._(this.backend, this.file, this.size)
    : _epoch = backend is BinaryReaderBackend
          ? (backend as BinaryReaderBackend).readEpoch
          : null;
  final ReaderBackend backend;
  final int file;
  final int size;
  static const pageSize = 64 * 1024;
  static const maxPages = 16;
  static const maxReadBytes = pageSize * maxPages;
  final int? _epoch;
  int readCalls = 0;
  int get cachedBytes =>
      _pages.values.fold(0, (sum, bytes) => sum + bytes.length);
  final _pages = <int, Uint8List>{};
  Future<void> _tail = Future.value();
  bool _closed = false;
  ReaderFailure? failure;
  void Function(ReaderFailure)? onError;
  int fetchedBytes = 0;

  static Future<BackendRangeReader> open(
    ReaderBackend backend,
    String path,
  ) async {
    final result = await backend.request({'op': 'file_open', 'path': path});
    return BackendRangeReader._(
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
    if (_epoch != null &&
        (backend as BinaryReaderBackend).readEpoch != _epoch) {
      _clearCache();
      throw ReaderFailure('stale_session', '此文件会话已失效，请重新打开。');
    }
  }

  Future<int> _read(Uint8List buffer, int position, int length) async {
    _check();
    if (position < 0 || length < 0 || length > buffer.length) {
      throw ReaderFailure('invalid', '文件读取范围无效。');
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
          // Merge only contiguous missing pages needed by this callback. Random
          // small reads still fetch one page; a cached page ends the run.
          final last = (position + count - 1) ~/ pageSize;
          var end = page + 1;
          while (end <= last &&
              end - page < maxPages &&
              !_pages.containsKey(end)) {
            end++;
          }
          final start = page * pageSize;
          final wanted = math.min(end * pageSize, size) - start;
          readCalls++;
          final fetched = await backend.readFileBytes(file, start, wanted);
          try {
            _check();
            if (fetched.length != wanted) {
              throw ReaderFailure('io', '文件数据不完整，请检查存储设备后重新打开。');
            }
            fetchedBytes += fetched.length;
            // Separate small pages so eviction zeroes exactly one page and does
            // not retain or wipe a larger backing buffer shared by other pages.
            for (var index = page; index < end; index++) {
              final from = (index - page) * pageSize;
              _pages[index] = Uint8List.fromList(
                Uint8List.sublistView(
                  fetched,
                  from,
                  math.min(from + pageSize, fetched.length),
                ),
              );
              while (_pages.length > maxPages) {
                final evicted = _pages.remove(_pages.keys.first)!;
                evicted.fillRange(0, evicted.length, 0);
              }
            }
            bytes = _pages.remove(page)!;
          } finally {
            fetched.fillRange(0, fetched.length, 0);
          }
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
      buffer.fillRange(0, count, 0);
      if (!_closed) {
        failure = error;
        _clearCache();
        onError?.call(error);
      }
      rethrow;
    }
  }

  /// Bounded whole-image helper. The caller owns and must release/clear success
  /// bytes. A failed or cancelled read wipes the entire partially filled image.
  Future<Uint8List> readAll({
    required int limit,
    void Function()? check,
  }) async {
    _check();
    if (size > limit) throw ReaderFailure('invalid', '文件超过预览大小限制。');
    final bytes = Uint8List(size);
    try {
      for (var offset = 0; offset < size;) {
        check?.call();
        final length = math.min(maxReadBytes, size - offset);
        final count = await read(
          Uint8List.sublistView(bytes, offset, offset + length),
          offset,
          length,
        );
        if (count != length) throw ReaderFailure('io', '文件数据不完整。');
        offset += count;
      }
      _check();
      check?.call();
      return bytes;
    } catch (_) {
      bytes.fillRange(0, bytes.length, 0);
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
