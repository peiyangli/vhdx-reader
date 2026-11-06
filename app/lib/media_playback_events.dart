import 'dart:async';
import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
// Pinned media_kit 1.2.6 does not expose end-file events in PlayerStream.
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;

/// Observes actual playback failure, independently of recoverable decoder logs.
/// A separate weak client has its own queue and cannot consume media_kit events
/// or keep its player alive. Dispose it before disposing the owning player.
class MediaPlaybackEvents {
  MediaPlaybackEvents(
    NativePlayer player, {
    required this.onFailure,
    required this.onPlaybackRestart,
  }) : _mpv = player.mpv {
    final name = 'vhdx-playback-events'.toNativeUtf8();
    try {
      _client = _mpv.mpv_create_weak_client(player.ctx, name.cast());
    } finally {
      calloc.free(name);
    }
    if (_client == nullptr) {
      throw StateError('Cannot observe playback events');
    }
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _drain());
  }

  final mpv.MPV _mpv;
  final void Function() onFailure;
  final void Function() onPlaybackRestart;
  Pointer<mpv.mpv_handle> _client = nullptr;
  Timer? _timer;

  void _drain() {
    // Nonblocking, bounded work on the UI isolate. The next tick drains any
    // remainder; only this client reads this queue.
    for (var i = 0; i < 64 && _client != nullptr; i++) {
      final event = _mpv.mpv_wait_event(_client, 0).ref;
      switch (event.event_id) {
        case mpv.mpv_event_id.MPV_EVENT_NONE:
          return;
        case mpv.mpv_event_id.MPV_EVENT_SHUTDOWN:
          dispose();
          return;
        case mpv.mpv_event_id.MPV_EVENT_END_FILE:
          final end = event.data.cast<mpv.mpv_event_end_file>().ref;
          if (end.reason == mpv.mpv_end_file_reason.MPV_END_FILE_REASON_ERROR) {
            onFailure();
          }
        case mpv.mpv_event_id.MPV_EVENT_PLAYBACK_RESTART:
          onPlaybackRestart();
      }
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    if (_client == nullptr) return;
    _mpv.mpv_destroy(_client);
    _client = nullptr;
  }
}
