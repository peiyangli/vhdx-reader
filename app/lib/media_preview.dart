import 'dart:async';
import 'dart:io';
import 'platform_storage.dart';
import 'playback_controls.dart';
import 'media_playback_events.dart';
import 'video_dismiss_view.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
// Pinned media_kit_video 2.0.1: drain its Android resize work before teardown.
// ignore: implementation_imports
import 'package:media_kit_video/src/video_controller/android_video_controller/android_video_controller.dart';
import 'backend.dart';

class MediaPreviewSource extends ChangeNotifier {
  MediaPreviewSource._(
    this.backend,
    this.file,
    this.player,
    this.controller,
    this._ownsPlaybackSession,
  ) {
    _subscriptions.addAll([
      player.stream.position.listen((value) {
        position = value;
        _changed();
      }),
      player.stream.duration.listen((value) {
        duration = value;
        _changed();
      }),
      player.stream.playing.listen((value) {
        playing = value && !_playbackFailed;
        _changed();
      }),
      player.stream.buffering.listen((value) {
        buffering = value && !_playbackFailed;
        _changed();
      }),
      player.stream.volume.listen((value) {
        volume = value;
        _changed();
      }),
    ]);
  }
  static const _playbackFailure = '无法播放此文件，请检查格式或存储设备后重试。';
  MediaPlaybackEvents? _playbackEvents;
  bool _playbackFailed = false;
  final bool _ownsPlaybackSession;
  bool get audioOutputAvailable => !Platform.isIOS || _ownsPlaybackSession;
  final ReaderBackend backend;
  final int file;
  final Player player;
  final VideoController controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;
  Future<void> closed = Future.value();
  bool _visible = false;
  bool _firstVisibility = true;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool buffering = true;
  double volume = 100;
  String? error;
  Future<void> _commands = Future.value();

  static Future<MediaPreviewSource> open(
    ReaderBackend backend,
    String path, {
    bool thumbnail = false,
  }) async {
    final media = await backend.request({'op': 'media_open', 'path': path});
    Player? player;
    MediaPreviewSource? source;
    var audioAcquired = false;
    try {
      if (Platform.isIOS && !thumbnail) {
        audioAcquired = await PlatformStorage.beginPlayback();
      }
      MediaKit.ensureInitialized();
      player = Player(
        configuration: PlayerConfiguration(
          title: 'VHDX Reader',
          logLevel: MPVLogLevel.error,
          bufferSize: (thumbnail ? 1 : 8) * 1024 * 1024,
          protocolWhitelist: ['http', 'tcp'],
        ),
      );
      final controller = VideoController(
        player,
        configuration: thumbnail
            ? VideoControllerConfiguration(
                width: 320,
                height: 180,
                hwdec: Platform.isAndroid ? 'no' : null,
              )
            : const VideoControllerConfiguration(),
      );
      // Controller initialization is deferred to a frame. Lazy thumbnails can
      // start while the browser is idle, so explicitly request that frame.
      WidgetsBinding.instance.scheduleFrame();
      final native = player.platform;
      if (native is! NativePlayer) throw StateError('Native player required');
      if (thumbnail || (Platform.isIOS && !audioAcquired)) {
        await native.setProperty('ao', 'null');
      }
      // media_kit enables disk caching by default. Override BEFORE opening media.
      if (thumbnail) {
        await native.setProperty('pause', 'yes');
        await native.setProperty('audio', 'no');
        await native.setProperty('aid', 'no');
      }
      await native.setProperty('cache-on-disk', 'no');
      if (await native.getProperty('cache-on-disk') != 'no') {
        throw StateError('Cannot disable media disk cache');
      }
      await native.setProperty(
        'demuxer-max-back-bytes',
        '${thumbnail ? 0 : 2 * 1024 * 1024}',
      );
      await native.setProperty('cache-secs', thumbnail ? '0' : '5');
      if (thumbnail) {
        await native.setProperty('cache', 'no');
        await native.setProperty('demuxer-readahead-secs', '0');
      }
      await native.setProperty('access-references', 'no');
      await native.setProperty('sub-auto', 'no');
      await native.setProperty('audio-file-auto', 'no');
      source = MediaPreviewSource._(
        backend,
        media['file'] as int,
        player,
        controller,
        audioAcquired,
      );
      final opened = source;
      source._playbackEvents = MediaPlaybackEvents(
        native,
        onFailure: () {
          if (opened._disposed) return;
          opened._playbackFailed = true;
          opened.error = _playbackFailure;
          opened.playing = false;
          opened.buffering = false;
          opened._changed();
        },
        onPlaybackRestart: () {
          if (opened._disposed) return;
          opened._playbackFailed = false;
          if (opened.error == _playbackFailure) opened.error = null;
          opened.playing = opened.player.state.playing;
          opened.buffering = opened.player.state.buffering;
          opened._changed();
        },
      );
      // add uses loadfile directly; open writes a temporary playlist to disk.
      await player.add(Media(media['url'] as String));
      await native.setProperty('playlist-pos', '0');
      return source;
    } catch (error) {
      if (source != null) {
        source.dispose();
      } else {
        if (player != null) {
          try {
            await player.dispose();
          } catch (_) {}
        }
        if (audioAcquired) {
          try {
            await PlatformStorage.endPlayback();
          } catch (_) {}
        }
        try {
          await backend.request({'op': 'media_close', 'file': media['file']});
        } catch (_) {}
      }
      if (error is ReaderFailure && error.invalidated) rethrow;
      throw ReaderFailure('media', '无法启动播放器，请完整解压程序并检查视频格式。');
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _command(Future<void> Function() action) {
    _commands = _commands.then((_) async {
      if (_disposed) return;
      try {
        await action();
      } catch (_) {
        error = '播放操作失败，请重新打开视频。';
        _changed();
      }
    });
    return _commands;
  }

  void setVisible(bool visible) {
    _visible = visible;
    final autoPlay = _firstVisibility && visible;
    _firstVisibility = false;
    unawaited(
      _command(() async {
        if (!_visible) {
          _resumeAfterPull = null;
          await _restoreBoost(pause: true);
          await player.pause();
        } else if (autoPlay) {
          await player.play();
        }
      }),
    );
  }

  Future<void> toggle() => _command(() async {
    if (!_visible) return;
    if (player.state.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  });
  Future<void> seek(Duration value) => _command(() => player.seek(value));
  Future<void> setVolume(double value) =>
      _command(() => player.setVolume(value.clamp(0, 100)));
  Future<Map<String, dynamic>> statistics() =>
      backend.request({'op': 'media_status', 'file': file});

  bool? _resumeAfterPull;

  Future<void> beginPull() => _command(() async {
    if (!_visible || _resumeAfterPull != null) return;
    await _restoreBoost();
    _resumeAfterPull = player.state.playing;
    await player.pause();
  });

  Future<void> cancelPull() => _command(() async {
    final resume = _resumeAfterPull;
    _resumeAfterPull = null;
    if (resume == true && _visible) await player.play();
  });

  double? _restoreRate;
  bool _restorePlaying = false;

  Future<void> beginBoost() => _command(() async {
    if (!_visible || _restoreRate != null || error != null) return;
    _restoreRate = player.state.rate;
    _restorePlaying = player.state.playing;
    await player.setRate(2);
    if (!_restorePlaying) await player.play();
  });

  Future<void> _restoreBoost({bool pause = false}) async {
    final rate = _restoreRate;
    if (rate == null) return;
    _restoreRate = null;
    try {
      await player.setRate(rate);
    } finally {
      if (pause || !_restorePlaying) await player.pause();
    }
  }

  Future<void> endBoost({bool pause = false}) =>
      _command(() => _restoreBoost(pause: pause));
  Future<void> suspend() => _command(() async {
    _visible = false;
    _resumeAfterPull = null;
    await _restoreBoost(pause: true);
    await player.pause();
  });

  Future<void> _disposePlayer() async {
    try {
      final output = await controller.platform.future;
      if (output is AndroidVideoController) {
        // 2.0.1 disposes rect/wid before waiting for asynchronous resize callbacks.
        // Stop new work and drain queued callbacks while their notifiers and
        // player are still alive. No delays or swallowed use-after-dispose errors.
        await output.videoParamsSubscription?.cancel();
        output.wid.removeListener(output.widListener);
        await output.lock.synchronized(() async {});
      }
    } finally {
      await player.dispose();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _playbackEvents?.dispose();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    // Revoke access immediately, then release the player and its buffered packets.
    unawaited(
      backend
          .request({'op': 'media_close', 'file': file})
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    closed = _commands
        .then((_) async {
          try {
            await _disposePlayer();
          } finally {
            if (_ownsPlaybackSession) await PlatformStorage.endPlayback();
          }
        })
        .catchError((Object _) {});
    super.dispose();
  }
}

class MediaPreview extends StatefulWidget {
  const MediaPreview({
    super.key,
    required this.source,
    required this.active,
    required this.onExit,
    this.onPrevious,
    this.onNext,
    this.switching = false,
    this.message,
  });
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final bool switching;
  final String? message;
  final MediaPreviewSource source;
  final bool active;
  final VoidCallback onExit;
  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview>
    with WidgetsBindingObserver {
  bool _foreground = true;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (!active) unawaited(widget.source.suspend());
    if (active) widget.source.setVisible(widget.active);
    if (mounted) setState(() => _foreground = active);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(widget.source.endBoost(pause: true));
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    widget.source.setVisible(widget.active && _foreground);
  }

  @override
  void didUpdateWidget(covariant MediaPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      widget.source.setVisible(widget.active && _foreground);
    }
  }

  @override
  Widget build(BuildContext context) => VideoDismissView(
    enabled: widget.active && _foreground && !widget.switching,
    onStart: () => unawaited(widget.source.beginPull()),
    onCancel: () => unawaited(widget.source.cancelPull()),
    onDismiss: widget.onExit,
    child: Video(
      controller: widget.source.controller,
      controls: NoVideoControls,
      fill: Colors.transparent,
      pauseUponEnteringBackgroundMode: true,
      resumeUponEnteringForegroundMode: false,
    ),
    controls: (update, end, cancel, pulling) => AnimatedBuilder(
      animation: widget.source,
      builder: (context, child) => PlaybackControls(
        position: widget.source.position,
        duration: widget.source.duration,
        playing: widget.source.playing,
        muted: widget.source.volume == 0,
        buffering: widget.source.buffering || widget.switching,
        error: widget.message ?? widget.source.error,
        enabled: widget.active && _foreground && !widget.switching,
        onPullUpdate: update,
        onPullEnd: end,
        onPullCancel: cancel,
        pulling: pulling,
        onPrevious: widget.onPrevious,
        onNext: widget.onNext,
        onHoldStart: widget.source.error == null
            ? () => unawaited(widget.source.beginBoost())
            : null,
        onHoldEnd: () => unawaited(widget.source.endBoost()),
        onPlay: () => unawaited(widget.source.toggle()),
        onMute: widget.source.audioOutputAvailable
            ? () => unawaited(
                widget.source.setVolume(widget.source.volume == 0 ? 100 : 0),
              )
            : null,
        onSeek: (value) => unawaited(widget.source.seek(value)),
        onExit: widget.onExit,
      ),
    ),
  );
}
