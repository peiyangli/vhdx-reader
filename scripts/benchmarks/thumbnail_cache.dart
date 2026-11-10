import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:vhdx_reader/backend.dart';

import 'baseline.dart' as old;
import 'candidate.dart' as next;

class NoSource extends ReaderBackend {
  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> request) async =>
      throw StateError('unexpected source read');
  @override
  void beginOperation() {}
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

late ui.Image frame;
late File output;
Future<void> emit(Map<String, dynamic> data) async {
  await output.writeAsString(
    '${jsonEncode(data)}\n',
    mode: FileMode.append,
    flush: true,
  );
}

Future<void> idle(dynamic cache, bool candidate) async {
  await cache.benchmarkIdle;
  if (candidate) await cache.persistenceIdle;
}

Future<void> run(bool candidate, int round, String mode) async {
  final dir = await Directory.systemTemp.createTemp('perf07-');
  var generated = 0,
      dropped = 0,
      writes = 0,
      hits = 0,
      peakCount = 0,
      peakBytes = 0;
  final traces = <Map<String, dynamic>>[];
  final backend = NoSource();
  dynamic cache, scope;
  final hold = Completer<void>();
  final writing = Completer<void>();
  var blocked = false;
  Future<void> hook(String stage) async {
    if (stage != 'write') return;
    if (mode == 'blocked_hit' && blocked) {
      if (!writing.isCompleted) writing.complete();
      await hold.future;
    }
    if (mode == 'slow_video')
      await Future<void>.delayed(const Duration(milliseconds: 40));
    writes++;
  }

  void trace(Map<String, dynamic> event) {
    traces.add(event);
    if (event['outcome'] == 'queue_full') dropped++;
    if (event['phase'] == 'lookup' && event['outcome'] == 'hit') hits++;
  }

  dynamic makeScope() => candidate
      ? next.ThumbnailScope(
          cache,
          backend,
          'unchanged-image:partition-1',
          encrypted: false,
        )
      : old.ThumbnailScope(
          cache,
          backend,
          'unchanged-image:partition-1',
          encrypted: false,
        );
  Future<dynamic> gen() async {
    generated++;
    await Future<void>.delayed(const Duration(milliseconds: 8));
    return candidate
        ? next.Thumbnail(frame.clone(), Duration.zero)
        : old.Thumbnail(frame.clone(), Duration.zero);
  }

  dynamic makeCache() => candidate
      ? next.ThumbnailCache(
          directory: dir,
          onTrace: trace,
          persistenceHook: hook,
          generator: (_, __, ___) async => await gen() as next.Thumbnail,
        )
      : old.ThumbnailCache(
          directory: dir,
          onTrace: trace,
          persistenceHook: hook,
          generator: (_, __, ___) async => await gen() as old.Thumbnail,
        );
  cache = makeCache();
  scope = makeScope();
  Future<void> request(int i, {bool video = false}) async {
    final name = '$i.${video ? 'mp4' : 'png'}';
    final dynamic value = await cache.request(scope, '/$name', {
      'name': name,
      'size': 100,
      'modified_unix_ms': 1,
    }).future;
    if (value == null) throw StateError('missing image');
    value.dispose();
  }

  Timer? sampler;
  try {
    if (mode == 'near_limit') {
      for (var i = 0; i < 10000; i++) {
        await File('${dir.path}/seed-$i.thumb')
            .writeAsString('{"unavailable":true}');
      }
    }
    if (mode == 'reopen' || mode == 'blocked_hit') {
      for (var i = 0; i < 24; i++) {
        await request(i);
        await idle(cache, candidate);
      }
      scope.invalidate();
      cache.dispose();
      cache = makeCache();
      scope = makeScope();
      generated = 0;
      writes = 0;
      traces.clear();
      hits = 0;
    }
    if (mode == 'blocked_hit') {
      blocked = true;
      await request(999);
      await writing.future;
      Timer(const Duration(milliseconds: 300), () {
        if (!hold.isCompleted) hold.complete();
      });
    }
    sampler = Timer.periodic(const Duration(milliseconds: 1), (_) {
      if (candidate) {
        final int count = cache.pendingPersistenceCount,
            bytes = cache.pendingPersistenceBytes;
        if (count > peakCount) peakCount = count;
        if (bytes > peakBytes) peakBytes = bytes;
      }
    });
    final clock = Stopwatch()..start();
    final ready = <int>[];
    final count = mode == 'slow_video' ? 6 : 24;
    await Future.wait(
      List.generate(count, (i) async {
        await request(
          i,
          video:
              mode == 'slow_video' ||
              ((mode == 'fresh' || mode == 'near_limit') && i.isOdd),
        );
        ready.add(clock.elapsedMicroseconds);
      }),
    );
    final shown = clock.elapsedMicroseconds;
    await idle(cache, candidate);
    final drained = clock.elapsedMicroseconds;
    final stored = (await dir.list().toList())
        .where((f) => f.path.endsWith('.thumb'))
        .length;
    if (mode == 'near_limit' && stored != 10000)
      throw StateError('entry quota mismatch: $stored');
    if (dropped != 0)
      throw StateError(
        'performance result would hide dropped writes: $dropped',
      );
    if ((mode == 'fresh' || mode == 'near_limit' || mode == 'slow_video') &&
        writes != count)
      throw StateError('missing writes: $writes/$count');
    if (mode == 'reopen' && generated != 0)
      throw StateError('reopen regenerated data');
    ready.sort();
    final generation =
        traces
            .where((e) => e['phase'] == 'generation')
            .map((e) => (e['elapsed_ms'] as int) - (e['queue_ms'] as int))
            .toList()
          ..sort();
    final queueWaits =
        traces
            .where((e) => e['phase'] == 'persistence' && e['queue_ms'] != null)
            .map((e) => e['queue_ms'] as int)
            .toList()
          ..sort();
    await emit({
      'persistence_queue_p95_ms': queueWaits.isEmpty
          ? null
          : queueWaits[(queueWaits.length * .95).ceil() - 1],
      'variant': candidate ? 'candidate' : 'baseline',
      'round': round,
      'mode': mode,
      'first_ms': ready.first / 1000,
      'all_ms': shown / 1000,
      'p95_ms': ready[(ready.length * .95).ceil() - 1] / 1000,
      'drain_ms': drained / 1000,
      'generated': generated,
      'writes': writes,
      'hits': hits,
      'dropped': dropped,
      'peak_pending': peakCount,
      'peak_pending_bytes': peakBytes,
      'generation_slot_p95_ms': generation.isEmpty
          ? 0
          : generation[(generation.length * .95).ceil() - 1],
      'rss_bytes': ProcessInfo.currentRss,
    });
  } finally {
    if (!hold.isCompleted) hold.complete();
    sampler?.cancel();
    await idle(cache, candidate);
    cache.dispose();
    await dir.delete(recursive: true);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('PERF-07 thumbnail benchmark'))),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    try {
      output = File(Platform.environment['VHDX_THUMB_BENCH_OUTPUT']!);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      for (var y = 0; y < 320; y += 4) {
        for (var x = 0; x < 320; x += 4) {
          canvas.drawRect(
            ui.Rect.fromLTWH(x.toDouble(), y.toDouble(), 4, 4),
            ui.Paint()
              ..color = ui.Color(
                0xff000000 | ((x * 971 + y * 7901) % 0xffffff),
              ),
          );
        }
      }
      final picture = recorder.endRecording();
      frame = await picture.toImage(320, 320);
      picture.dispose();
      for (var round = 0; round < 4; round++) {
        for (final mode in [
          'fresh',
          'slow_video',
          'reopen',
          'blocked_hit',
          'near_limit',
        ]) {
          for (final candidate
              in round.isEven ? [false, true] : [true, false]) {
            await run(candidate, round, mode);
          }
        }
      }
      frame.dispose();
      exit(0);
    } catch (e, st) {
      await emit({'error': '$e', 'stack': '$st'});
      exit(1);
    }
  });
}
