import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;
import 'package:vhdx_reader/backend.dart';
import 'package:vhdx_reader/media_preview.dart';
import 'test_configuration.dart';

// Whole-process CPU, including Flutter/decoder/worker. NaN on other platforms.
double cpuMs() {
  if (!Platform.isWindows) return double.nan;
  final kernel = DynamicLibrary.open('kernel32.dll');
  final process = kernel
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      )();
  final times = kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetProcessTimes');
  final values = calloc<Uint64>(4);
  try {
    if (times(process, values, values + 1, values + 2, values + 3) == 0) {
      throw StateError('CPU clock unavailable');
    }
    return (values[2] + values[3]) / 10000;
  } finally {
    calloc.free(values);
  }
}

Future<void> until(WidgetTester tester, bool Function() ready) async {
  final clock = Stopwatch()..start();
  while (!ready() && clock.elapsed < const Duration(seconds: 20)) {
    await tester.pump(const Duration(milliseconds: 5));
  }
  expect(ready(), isTrue, reason: 'Timed out waiting for playback');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets('HTTP and native streams: first frame, seek, bytes and close', (
    tester,
  ) async {
    final root = fixtureSetting('VHDX_SAMPLE_DIR')!;
    final fixture = fixtureSetting('VHDX_MEDIA_FIXTURE')!;
    const rounds = int.fromEnvironment(
      'VHDX_MEDIA_BENCH_ROUNDS',
      defaultValue: 3,
    );
    final samples = [
      (fixture, '/sample.mp4', false),
      for (final name in [
        'avi.avi',
        'mkv.mkv',
        'mp4.1.mp4',
        'asf.asf',
        'flv.flv',
      ])
        ('$root/bitlockervhdx.vhdx', '/video/$name', true),
    ];
    for (var round = 0; round < rounds; round++) {
      for (final sample in samples) {
        final order = round.isEven ? ['http', 'native'] : ['native', 'http'];
        for (final transport in order) {
          final backend = await NativeBackend.start();
          MediaPreviewSource? source;
          try {
            // Fresh volume caches per trial. OS caches remain warm/unspecified.
            await backend.request({'op': 'open', 'path': sample.$1});
            await backend.request({
              'op': 'unlock',
              'partition': 1,
              'mode': sample.$3 ? 'password' : 'none',
              if (sample.$3) 'credential_file': '$root/password.txt',
            });
            Object? failure;
            final cpu = cpuMs();
            final clock = Stopwatch()..start();
            var openUs = 0;
            MediaPreviewSource.open(
              backend,
              sample.$2,
              transport: transport,
            ).then(
              (value) {
                source = value;
                openUs = clock.elapsedMicroseconds;
              },
              onError: (Object error) {
                failure = error;
              },
            );
            await until(tester, () => source != null || failure != null);
            expect(failure, isNull);
            final opened = source!;
            await opened.setVolume(0);
            await tester.pumpWidget(
              MaterialApp(
                home: MediaPreview(source: opened, active: true, onExit: () {}),
              ),
            );
            var frame = false;
            opened.controller.waitUntilFirstFrameRendered.then((_) {
              frame = true;
            });
            await until(tester, () => frame || opened.error != null);
            expect(opened.error, isNull);
            final firstFrameUs = clock.elapsedMicroseconds;
            await until(tester, () => opened.duration.inMilliseconds > 1000);
            final native = opened.player.platform as NativePlayer;
            expect(await native.getProperty('cache-on-disk'), 'no');
            expect(opened.player.state.width, greaterThan(0));
            await opened.player.pause();
            final before = await opened.statistics();
            expect(before['transport'], transport);
            final seeks = <int>[];
            final clientName = 'vhdx-benchmark'.toNativeUtf8();
            final client = native.mpv.mpv_create_weak_client(
              native.ctx,
              clientName.cast(),
            );
            calloc.free(clientName);
            expect(client, isNot(nullptr));
            try {
              for (final fraction in [0.75, 0.25]) {
                // Drain old events before starting each measured seek.
                while (native.mpv.mpv_wait_event(client, 0).ref.event_id !=
                    mpv.mpv_event_id.MPV_EVENT_NONE) {}
                final target = Duration(
                  microseconds: (opened.duration.inMicroseconds * fraction)
                      .round(),
                );
                final seekClock = Stopwatch()..start();
                await opened.seek(target);
                var restarted = false;
                await until(tester, () {
                  for (var i = 0; i < 64; i++) {
                    final event = native.mpv.mpv_wait_event(client, 0).ref;
                    if (event.event_id == mpv.mpv_event_id.MPV_EVENT_NONE) {
                      break;
                    }
                    if (event.event_id ==
                        mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART) {
                      restarted = true;
                    }
                  }
                  return restarted;
                });
                seeks.add(seekClock.elapsedMicroseconds);
                expect(
                  (opened.player.state.position - target).inMilliseconds.abs(),
                  lessThan(1500),
                );
              }
            } finally {
              native.mpv.mpv_destroy(client);
            }
            final usedCpu = cpuMs() - cpu;
            final after = await opened.statistics();
            expect(opened.error, isNull);
            // Verify decoded image availability without staging it on disk.
            final screenshot = await opened.player.screenshot(
              format: 'image/png',
            );
            expect(screenshot, isNotNull);
            expect(screenshot!.length, greaterThan(100));
            final closeClock = Stopwatch()..start();
            await tester.pumpWidget(const SizedBox.shrink());
            opened.dispose();
            await opened.closed.timeout(const Duration(seconds: 15));
            final closeUs = closeClock.elapsedMicroseconds;
            await expectLater(
              opened.statistics(),
              throwsA(isA<ReaderFailure>()),
            );
            debugPrint(
              'MEDIA_TRANSPORT ${jsonEncode({'round': round, 'file': sample.$2, 'transport': transport, 'mpv_api': native.mpv.mpv_client_api_version(), 'open_us': openUs, 'first_frame_us': firstFrameUs, 'seek_restart_us': seeks, 'close_us': closeUs, 'cpu_ms': usedCpu.isFinite ? usedCpu : null, 'before_seek': before, 'after_seek': after})}',
            );
          } finally {
            source?.dispose();
            if (source != null) await source!.closed;
            await backend.dispose();
          }
        }
      }
    }
    // media_kit 1.2.6 delays mpv_terminate_destroy by 5 seconds. Exercise late
    // termination before the test process exits; the callback module stays live.
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
