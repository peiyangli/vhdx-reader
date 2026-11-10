// Run as a compiled Dart executable; excludes Flutter rendering and disk I/O.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:vhdx_reader/file_order.dart';
import '../test/support/legacy_file_order.dart';

List<Map<String, dynamic>> sample(int count) => [
  for (var i = 0; i < count; i++)
    {
      'name':
          'item${i % 117}_part${i.toString().padLeft(6, '0')}.${i % 4 == 0 ? 'mp4' : 'txt'}',
      'directory': i % 29 == 0,
      'size': i * 131 % 100003,
      'modified_unix_ms': i % 7 == 0 ? null : i * 1000,
    },
]..shuffle(Random(2026));
double timed(void Function() run) {
  final watch = Stopwatch()..start();
  run();
  return watch.elapsedMicroseconds / 1000;
}

double median(List<double> values) {
  values.sort();
  return values[values.length ~/ 2];
}

void main() {
  for (var i = 0; i < 3; i++) {
    final values = sample(2000);
    legacySortedFiles(values, FileSort.name, false);
    (DirectoryOrder()..add(values)).snapshot(FileSort.name, false);
  }
  for (final count in [200, 2000, 10000, 50000]) {
    final values = sample(count);
    final old = <double>[],
        fresh = <double>[],
        repeatOld = <double>[],
        repeatNew = <double>[],
        incremental = <double>[],
        maxBatch = <double>[],
        resort = <double>[];
    for (var round = 0; round < 5; round++) {
      final order = DirectoryOrder();
      late List<Map<String, dynamic>> expected;
      void baseline() {
        old.add(
          timed(
            () => expected = legacySortedFiles(values, FileSort.name, false),
          ),
        );
      }

      void candidate() {
        fresh.add(timed(() => order.add(values)));
        fresh[fresh.length - 1] += timed(
          () => order.snapshot(FileSort.name, false),
        );
      }

      if (round.isEven) {
        baseline();
        candidate();
      } else {
        candidate();
        baseline();
      }
      final view = order.snapshot(FileSort.name, false);
      if (List.generate(
        count,
        (i) => identical(view.entries[i], expected[i]),
      ).contains(false)) {
        throw StateError('order differs');
      }
      repeatOld.add(
        timed(() => legacySortedFiles(values, FileSort.name, false)),
      );
      repeatNew.add(
        timed(() {
              for (var i = 0; i < 1000; i++) {
                if (!identical(view, order.snapshot(FileSort.name, false))) {
                  throw StateError('uncached');
                }
              }
            }) /
            1000,
      );
      resort.add(timed(() => order.snapshot(FileSort.name, true)));
      final batched = DirectoryOrder();
      double worst = 0;
      incremental.add(
        timed(() {
          for (var start = 0; start < count; start += 200) {
            final elapsed = timed(() {
              batched.add(values.sublist(start, min(start + 200, count)));
              batched.snapshot(FileSort.name, false);
            });
            worst = max(worst, elapsed);
          }
        }),
      );
      maxBatch.add(worst);
    }
    stdout.writeln(
      jsonEncode({
        'entries': count,
        'legacy_sort_ms': median(old),
        'cached_prepare_sort_ms': median(fresh),
        'legacy_rebuild_sort_ms': median(repeatOld),
        'cached_snapshot_ms': median(repeatNew),
        'cached_reverse_sort_ms': median(resort),
        'incremental_publish_every_200_ms': median(incremental),
        'max_200_batch_ms': median(maxBatch),
        'rss_bytes': ProcessInfo.currentRss,
        'peak_rss_bytes': ProcessInfo.maxRss,
      }),
    );
  }
}
