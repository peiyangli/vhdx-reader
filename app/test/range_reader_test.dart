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

void main() {
  test(
    'PDF range reads cross pages, reuse cache, bound memory, and stop at EOF',
    () async {
      final backend = BytesBackend();
      final reader = await BackendRangeReader.open(backend, '/large.pdf');
      final buffer = Uint8List(100);
      expect(await reader.read(buffer, 65520, 100), 100);
      expect(buffer, backend.bytes.sublist(65520, 65620));
      expect(backend.reads.length, 2);
      await reader.read(buffer, 65520, 100);
      expect(backend.reads.length, 2);
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
      expect(backend.reads.every((read) => read.$2 <= 65536), isTrue);
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
