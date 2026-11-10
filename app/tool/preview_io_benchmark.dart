// PERF-05 Windows profile harness. Same native worker for legacy JSON and binary
// paths; real NTFS/PDFium/image decode. No OS cache flush. Round zero is warm-up.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/cache_settings.dart';
import 'package:vhdx_reader/range_reader.dart';
import 'package:vhdx_reader/thumbnails.dart';
import '../integration_test/support/legacy_range_reader.dart';

final shown = ValueNotifier<ui.Image?>(null);
final animating = ValueNotifier<bool>(false);
late File output;
final frames = <ui.FrameTiming>[];

class Probe implements ReaderBackend, BinaryReaderBackend {
  Probe(this.native, this.reference);
  final NativeBackend native;
  final Uint8List reference;
  int calls = 0, payload = 0, encoded = 0;
  @override
  int get readEpoch => native.readEpoch;
  void verify(Uint8List bytes, int offset) {
    if (offset + bytes.length > reference.length) throw StateError('over-read');
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != reference[offset + i]) {
        throw StateError('content mismatch');
      }
    }
  }

  @override
  Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
    final result = await native.request(value);
    if (value['op'] == 'file_read' || value['op'] == 'read') {
      calls++;
      final data = result['bytes'] as String;
      encoded += data.length;
      payload +=
          data.length ~/ 4 * 3 -
          (data.endsWith('==')
              ? 2
              : data.endsWith('=')
              ? 1
              : 0);
    }
    return result;
  }

  @override
  Future<Uint8List> readFileBytes(int file, int offset, int length) async {
    final bytes = await native.readFileBytes(file, offset, length);
    calls++;
    payload += bytes.length;
    return bytes;
  }

  @override
  void beginOperation() => native.beginOperation();
  @override
  void cancel() => native.cancel();
  @override
  Future<void> dispose() => native.dispose();
}

class CanvasView extends StatefulWidget {
  const CanvasView({super.key});
  @override
  State<CanvasView> createState() => _CanvasViewState();
}

class _CanvasViewState extends State<CanvasView>
    with SingleTickerProviderStateMixin {
  late final AnimationController pulse;
  @override
  void initState() {
    super.initState();
    pulse = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    animating.addListener(toggle);
  }

  void toggle() {
    if (animating.value) {
      pulse.repeat();
    } else {
      pulse.stop();
    }
  }

  @override
  void dispose() {
    animating.removeListener(toggle);
    pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Center(
            child: ValueListenableBuilder<ui.Image?>(
              valueListenable: shown,
              builder: (_, image, _) =>
                  RawImage(image: image, fit: BoxFit.contain),
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: RotationTransition(
              turns: pulse,
              child: const Icon(Icons.sync),
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> present(ui.Image image) async {
  final previous = shown.value;
  shown.value = image;
  await WidgetsBinding.instance.endOfFrame;
  previous?.dispose();
}

double ms(Stopwatch watch) => watch.elapsedMicroseconds / 1000;
double pct(List<double> xs, double p) {
  if (xs.isEmpty) return 0;
  xs.sort();
  return xs[(xs.length * p).ceil().clamp(1, xs.length) - 1];
}

List<double> frameGaps() {
  final starts =
      frames
          .map((f) => f.timestampInMicroseconds(ui.FramePhase.vsyncStart))
          .toList()
        ..sort();
  return [
    for (var i = 1; i < starts.length; i++) (starts[i] - starts[i - 1]) / 1000,
  ];
}

Future<ui.Image> decode(Uint8List bytes, int side) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  final factor = math.min(
    1.0,
    side / math.max(descriptor.width, descriptor.height),
  );
  final codec = await descriptor.instantiateCodec(
    targetWidth: (descriptor.width * factor).round(),
    targetHeight: (descriptor.height * factor).round(),
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
  }
}

Future<Uint8List> oldImage(Probe probe, bool thumbnail) async {
  final output = BytesBuilder(copy: false);
  if (thumbnail) {
    final reader = await LegacyRangeReader.open(probe, '/near-limit.bmp');
    try {
      for (var offset = 0; offset < reader.size;) {
        final buffer = Uint8List(math.min(65536, reader.size - offset));
        offset += await reader.read(buffer, offset, buffer.length);
        output.add(buffer);
      }
    } finally {
      await reader.close();
    }
  } else {
    while (output.length < probe.reference.length) {
      final data = await probe.request({
        'op': 'read',
        'path': '/near-limit.bmp',
        'offset': output.length,
        'length': math.min(1048576, probe.reference.length - output.length),
      });
      output.add(base64Decode(data['bytes'] as String));
    }
  }
  return output.takeBytes();
}

final pixelHashes = <String, String>{};
Future<Map<String, dynamic>> workload(
  Probe probe,
  String kind,
  bool legacy,
) async {
  final watch = Stopwatch()..start();
  if (kind.startsWith('pdf')) {
    final dynamic reader = legacy
        ? await LegacyRangeReader.open(probe, '/scan.pdf')
        : await BackendRangeReader.open(probe, '/scan.pdf');
    final document = await PdfDocument.openCustom(
      read: (Uint8List bytes, int at, int length) async {
        final count = await reader.read(bytes, at, length) as int;
        probe.verify(Uint8List.sublistView(bytes, 0, count), at);
        return count;
      },
      fileSize: reader.size as int,
      sourceName: 'perf-${legacy ? "old" : "new"}',
      maxSizeToCacheOnMemory: 0,
    );
    double? first;
    final times = <double>[];
    final pageCalls = <int>[];
    final openCalls = probe.calls;
    final hashes = <String, String>{};
    try {
      final order = kind == 'pdf_scan'
          ? [0, 1, 2, 3, 4, 5, 6, 7]
          : [0, 7, 2, 6, 1, 5, 3, 4, 0, 7];
      for (final index in order) {
        final callsBefore = probe.calls;
        final pageTime = Stopwatch()..start();
        final rendered = (await document.pages[index].render(
          width: 595,
          height: 842,
          fullWidth: 595,
          fullHeight: 842,
        ))!;
        final image = await rendered.createImage();
        await present(image);
        times.add(ms(pageTime));
        pageCalls.add(probe.calls - callsBefore);
        first ??= ms(watch);
        hashes['$index'] = sha256.convert(rendered.pixels).toString();
        rendered.dispose();
      }
      for (final entry in hashes.entries) {
        final key = '$kind/${entry.key}';
        final old = pixelHashes.putIfAbsent(key, () => entry.value);
        if (old != entry.value) throw StateError('PDF pixels mismatch');
      }
      return {
        'first_paint_ms': first,
        'total_ms': ms(watch),
        'page_ms': times,
        'open_calls': openCalls,
        'page_calls': pageCalls,
        'page_p95_ms': pct(times.skip(1).toList(), .95),
        'reader_fetched': reader.fetchedBytes,
      };
    } finally {
      await document.dispose();
      await reader.close();
    }
  }
  if (kind == 'thumbnail') {
    final cache = ThumbnailCache(
      settings: const CacheSettings(thumbnailDisk: false),
      // Benchmark-only injection reproduces the previous thumbnail reader.
      // ignore: invalid_use_of_visible_for_testing_member
      generator: legacy
          ? (scope, path, entry) async {
              final bytes = await oldImage(probe, true);
              try {
                return Thumbnail(await decode(bytes, 320), Duration.zero);
              } finally {
                bytes.fillRange(0, bytes.length, 0);
              }
            }
          : null,
    );
    final scope = ThumbnailScope(cache, probe, 'perf', encrypted: false);
    try {
      final thumb = await cache.request(scope, '/near-limit.bmp', {
        'name': 'near-limit.bmp',
        'size': probe.reference.length,
        'modified_unix_ms': 1,
      }).future;
      if (thumb == null) throw StateError('thumbnail failed');
      await present(thumb.image.clone());
      thumb.dispose();
      return {'first_paint_ms': ms(watch), 'total_ms': ms(watch)};
    } finally {
      scope.invalidate();
      cache.dispose();
    }
  }
  late Uint8List bytes;
  if (legacy) {
    bytes = await oldImage(probe, false);
  } else {
    final reader = await BackendRangeReader.open(probe, '/near-limit.bmp');
    try {
      bytes = await reader.readAll(limit: 16 * 1024 * 1024);
    } finally {
      await reader.close();
    }
  }
  final readMs = ms(watch);
  try {
    await present(await decode(bytes, 2048));
    final first = ms(watch);
    probe.verify(bytes, 0);
    return {'first_paint_ms': first, 'read_ms': readMs, 'total_ms': ms(watch)};
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

Future<void> benchmark() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture = Platform.environment['VHDX_PREVIEW_FIXTURE_DIR']!;
  output = File(Platform.environment['VHDX_PREVIEW_BENCH_OUTPUT']!);
  await pdfrxFlutterInitialize();
  runApp(const CanvasView());
  await WidgetsBinding.instance.endOfFrame;
  WidgetsBinding.instance.addTimingsCallback(frames.addAll);
  final references = <String, Uint8List>{
    'scan.pdf': await File('$fixture/scan.pdf').readAsBytes(),
    'near-limit.bmp': await File('$fixture/near-limit.bmp').readAsBytes(),
  };
  for (var round = 0; round < 4; round++) {
    for (final kind in ['pdf_scan', 'pdf_random', 'image', 'thumbnail']) {
      for (final legacy in round.isEven ? [true, false] : [false, true]) {
        final native = await NativeBackend.start();
        await native.request({'op': 'open', 'path': '$fixture/preview.vhdx'});
        await native.request({'op': 'unlock', 'partition': 1, 'mode': 'none'});
        final probe = Probe(
          native,
          references[kind.startsWith('pdf') ? 'scan.pdf' : 'near-limit.bmp']!,
        );
        frames.clear();
        final rssBefore = ProcessInfo.currentRss;
        animating.value = true;
        final result = await workload(probe, kind, legacy);
        animating.value = false;
        final rssAfter = ProcessInfo.currentRss;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        output.writeAsStringSync(
          '${jsonEncode({'round': round, 'kind': kind, 'version': legacy ? 'baseline' : 'current', ...result, 'calls': probe.calls, 'payload_bytes': probe.payload, 'base64_bytes': probe.encoded, 'frame_count': frames.length, 'frame_gap_p95_ms': pct(frameGaps(), .95), 'frame_gap_max_ms': pct(frameGaps(), 1), 'build_p95_ms': pct(frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList(), .95), 'build_max_ms': pct(frames.map((f) => f.buildDuration.inMicroseconds / 1000).toList(), 1), 'raster_p95_ms': pct(frames.map((f) => f.rasterDuration.inMicroseconds / 1000).toList(), .95), 'rss_before': rssBefore, 'rss_after': rssAfter, 'peak_rss': ProcessInfo.maxRss})}\n',
          mode: FileMode.append,
        );
        await native.dispose();
      }
    }
  }
  exit(0);
}

void main() {
  runZonedGuarded(benchmark, (error, stack) {
    stderr.writeln('$error\n$stack');
    output.writeAsStringSync('ERROR $error\n$stack', mode: FileMode.append);
    exit(1);
  });
}
