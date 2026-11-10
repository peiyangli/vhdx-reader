import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/range_reader.dart';

class BytesBackend implements ReaderBackend {
  final bytes = Uint8List.fromList(
    List.generate(2 * 1024 * 1024 + 37, (i) => i % 251),
  );
  final reads = <(int, int)>[];
  Completer<void>? gate;
  bool closed = false;
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async {
    switch (request['op']) {
      case 'file_open':
        return {'file': 1, 'size': bytes.length};
      case 'file_close':
        closed = true;
        return {};
      case 'file_read':
        final offset = request['offset'] as int;
        final length = request['length'] as int;
        reads.add((offset, length));
        if (gate != null) await gate!.future;
        return {
          'bytes': base64Encode(
            bytes.sublist(offset, math.min(offset + length, bytes.length)),
          ),
        };
      default:
        throw StateError('Unexpected operation');
    }
  }

  @override
  void beginOperation() {}
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

class BinaryBytesBackend extends BytesBackend implements BinaryReaderBackend {
  @override
  int readEpoch = 0;
  Uint8List? lastResult;
  bool short = false;
  int? failAt;
  @override
  Future<Uint8List> readFileBytes(int file, int offset, int length) async {
    reads.add((offset, length));
    if (gate != null) await gate!.future;
    if (failAt != null && offset >= failAt!) {
      throw ReaderFailure('io', 'source failed', invalidated: true);
    }
    return lastResult = Uint8List.fromList(
      bytes.sublist(offset, offset + length - (short ? 1 : 0)),
    );
  }
}

void main() {
  test(
    'binary runs merge at 1 MiB and wipe transport buffers with bounded LRU',
    () async {
      final backend = BinaryBytesBackend();
      final reader = await BackendRangeReader.open(backend, '/image.bmp');
      final result = await reader.readAll(limit: 16 * 1024 * 1024);
      expect(result, backend.bytes);
      expect(backend.reads, [(0, 1048576), (1048576, 1048576), (2097152, 37)]);
      expect(reader.readCalls, 3);
      expect(reader.cachedBytes, lessThanOrEqualTo(1048576));
      expect(backend.lastResult!.every((byte) => byte == 0), isTrue);
      await reader.close();
      expect(reader.cachedBytes, 0);
    },
  );
  test(
    'cached page splits a missing run and short data fails without partial plaintext',
    () async {
      final backend = BinaryBytesBackend();
      final reader = await BackendRangeReader.open(backend, '/scan.pdf');
      await reader.read(Uint8List(1), 65536, 1);
      final output = Uint8List(3 * 65536);
      await reader.read(output, 0, output.length);
      expect(backend.reads, [(65536, 65536), (0, 65536), (131072, 65536)]);
      expect(output, backend.bytes.sublist(0, output.length));
      backend.short = true;
      final partial = Uint8List(2 * 65536)..fillRange(0, 2 * 65536, 17);
      await expectLater(
        reader.read(partial, 2 * 65536, partial.length),
        throwsA(isA<ReaderFailure>()),
      );
      expect(partial.every((b) => b == 0), isTrue);
      expect(reader.cachedBytes, 0);
      expect(backend.lastResult!.every((b) => b == 0), isTrue);
      await reader.close();
    },
  );
  test(
    'session change rejects cached bytes and late binary returns are wiped',
    () async {
      final backend = BinaryBytesBackend();
      final reader = await BackendRangeReader.open(backend, '/scan.pdf');
      await reader.read(Uint8List(1), 0, 1);
      backend.readEpoch++;
      await expectLater(
        reader.read(Uint8List(1), 0, 1),
        throwsA(isA<ReaderFailure>()),
      );
      expect(reader.cachedBytes, 0);
      await reader.close();
      final next = await BackendRangeReader.open(backend, '/scan.pdf');
      backend.gate = Completer<void>();
      final output = Uint8List(65536);
      final pending = expectLater(
        next.read(output, 0, output.length),
        throwsA(isA<ReaderFailure>()),
      );
      await Future<void>.delayed(Duration.zero);
      await next.close();
      backend.gate!.complete();
      await pending;
      expect(output.every((b) => b == 0), isTrue);
      expect(backend.lastResult!.every((b) => b == 0), isTrue);
    },
  );
  test('queued read cannot resurrect cache after source failure', () async {
    final backend = BinaryBytesBackend()..failAt = 1048576;
    final reader = await BackendRangeReader.open(backend, '/scan.pdf');
    final first = expectLater(
      reader.readAll(limit: 16 * 1024 * 1024),
      throwsA(
        isA<ReaderFailure>().having((e) => e.invalidated, 'invalidated', true),
      ),
    );
    await first;
    final second = expectLater(
      reader.read(Uint8List(1), 0, 1),
      throwsA(isA<ReaderFailure>()),
    );
    await second;
    expect(reader.cachedBytes, 0);
    await reader.close();
  });
  test(
    'PDF range reads cross pages, reuse cache, bound memory, and stop at EOF',
    () async {
      final backend = BytesBackend();
      final reader = await BackendRangeReader.open(backend, '/large.pdf');
      final buffer = Uint8List(100);
      expect(await reader.read(buffer, 65520, 100), 100);
      expect(buffer, backend.bytes.sublist(65520, 65620));
      expect(backend.reads.length, 1);
      await reader.read(buffer, 65520, 100);
      expect(backend.reads.length, 1);
      for (var i = 2; i < 20; i++) {
        await reader.read(buffer, i * 65536, 100);
      }
      final prior = backend.reads.length;
      await reader.read(buffer, 0, 100);
      expect(backend.reads.length, prior + 1); // First cache page was evicted.
      expect(await reader.read(buffer, backend.bytes.length - 7, 100), 7);
      expect(
        buffer.sublist(0, 7),
        backend.bytes.sublist(backend.bytes.length - 7),
      );
      expect(await reader.read(buffer, backend.bytes.length + 10, 100), 0);
      expect(
        backend.reads.every(
          (read) => read.$2 <= BackendRangeReader.maxReadBytes,
        ),
        isTrue,
      );
      await reader.close();
      expect(backend.closed, isTrue);
      await expectLater(
        reader.read(buffer, 0, 1),
        throwsA(isA<ReaderFailure>()),
      );
    },
  );
  test(
    'closing during a read rejects late plaintext and later cached reads',
    () async {
      final backend = BytesBackend()..gate = Completer<void>();
      final reader = await BackendRangeReader.open(backend, '/large.pdf');
      final output = Uint8List(32);
      final pending = reader.read(output, 0, 32);
      final checked = expectLater(pending, throwsA(isA<ReaderFailure>()));
      await Future<void>.delayed(Duration.zero);
      await reader.close();
      backend.gate!.complete();
      await checked;
      expect(output, Uint8List(32));
      expect(reader.fetchedBytes, 0);
    },
  );
}
