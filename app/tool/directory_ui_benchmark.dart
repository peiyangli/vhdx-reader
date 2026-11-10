// Windows profile harness. Synthetic directory backend: 200 entries/page,
// 10 ms response delay. Reports actual rendered frames, not storage throughput.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show FrameTiming;
import 'package:flutter/material.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/file_browser.dart';
import 'package:vhdx_reader/main.dart' show ReaderApp;

class DirectoryBackend implements ReaderBackend {
  DirectoryBackend(this.count);
  final int count;
  final watch = Stopwatch();
  int pages = 0;
  @override
  void beginOperation() {}
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
    switch (value['op']) {
      case 'open':
        return {
          'virtual_size': 1024,
          'disk_type': 'dynamic',
          'partitions': [
            {'index': 1, 'length': 1024, 'kind': 'Ntfs'},
          ],
        };
      case 'list':
        if (!watch.isRunning) watch.start();
        final start = value['start'] as int;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        pages++;
        final end = min(start + 200, count);
        return {
          'entries': [
            for (var i = start; i < end; i++)
              {
                'name': 'file${count - i}.txt',
                'size': 5,
                'directory': false,
                'attributes': 32,
              },
          ],
          'next_index': end < count ? end : null,
        };
      default:
        return {};
    }
  }
}

FileContents? visibleContents() {
  FileContents? found;
  void visit(Element element) {
    if (element.widget is FileContents) found = element.widget as FileContents;
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

double percentile(List<double> values, double p) {
  if (values.isEmpty) return 0;
  values.sort();
  return values[(values.length * p).ceil().clamp(1, values.length) - 1];
}

final output = File(
  Platform.environment['DIRECTORY_BENCH_OUTPUT'] ??
      'directory-ui-benchmark.jsonl',
);
Future<void> main() async {
  output.writeAsStringSync('');
  try {
    await benchmark();
  } catch (error, stack) {
    output.writeAsStringSync('$error\n$stack\n', mode: FileMode.append);
    exit(1);
  }
}

Future<void> benchmark() async {
  WidgetsFlutterBinding.ensureInitialized();
  final frames = <FrameTiming>[];
  WidgetsBinding.instance.addTimingsCallback(frames.addAll);
  for (var round = 0; round < 4; round++) {
    for (final count in [200, 2000, 10000, 50000]) {
      final backend = DirectoryBackend(count);
      frames.clear();
      runApp(
        ReaderApp(
          key: UniqueKey(),
          backend: backend,
          initialImage: 'synthetic.vhdx',
          platform: TargetPlatform.windows,
        ),
      );
      double? firstPaint;
      double? complete;
      var firstPages = 0;
      var observing = true;
      void observe(Duration _) {
        if (!observing) return;
        final contents = visibleContents();
        if (contents != null && contents.entries.isNotEmpty) {
          if (firstPaint == null) {
            firstPaint = backend.watch.elapsedMicroseconds / 1000;
            firstPages = backend.pages;
          }
          if (!contents.loading && contents.entries.length == count) {
            complete = backend.watch.elapsedMicroseconds / 1000;
          }
        }
        if (complete == null) {
          WidgetsBinding.instance.addPostFrameCallback(observe);
        }
      }

      WidgetsBinding.instance.addPostFrameCallback(observe);
      final timeout = Stopwatch()..start();
      while (complete == null) {
        if (timeout.elapsed.inSeconds > 60) {
          observing = false;
          throw StateError('benchmark timeout');
        }
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      observing = false;
      // FrameTiming arrives in batches. No new work is scheduled during this wait.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final build = frames
          .map((f) => f.buildDuration.inMicroseconds / 1000)
          .toList();
      final raster = frames
          .map((f) => f.rasterDuration.inMicroseconds / 1000)
          .toList();
      final total = frames
          .map((f) => f.totalSpan.inMicroseconds / 1000)
          .toList();
      output.writeAsStringSync(
        'DIRECTORY_BENCH ${jsonEncode({'round': round, 'entries': count, 'first_paint_ms': firstPaint, 'pages_at_first_paint': firstPages, 'complete_ms': complete, 'frame_count': frames.length, 'build_p95_ms': percentile(build, .95), 'build_max_ms': percentile(build, 1), 'raster_p95_ms': percentile(raster, .95), 'frame_total_p95_ms': percentile(total, .95), 'rss_bytes': ProcessInfo.currentRss, 'peak_rss_bytes': ProcessInfo.maxRss})}\n',
        mode: FileMode.append,
      );
    }
  }
  exit(0);
}
