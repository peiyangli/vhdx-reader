import 'dart:async';
import 'dart:io';
import 'platform_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
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
        playing = value;
        _changed();
      }),
      player.stream.buffering.listen((value) {
        buffering = value;
        _changed();
      }),
      player.stream.volume.listen((value) {
        volume = value;
        _changed();
      }),
      player.stream.error.listen((_) {
        error = '无法播放此文件，请检查格式或存储设备后重试。';
        _changed();
      }),
    ]);
  }
  final bool _ownsPlaybackSession;
  bool get audioOutputAvailable => !Platform.isIOS || _ownsPlaybackSession;
  final ReaderBackend backend;
  final int file;
  final Player player;
  final VideoController controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _disposed = false;
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
    String path,
  ) async {
    final media = await backend.request({'op': 'media_open', 'path': path});
    Player? player;
    MediaPreviewSource? source;
    var audioAcquired = false;
    try {
      if (Platform.isIOS) {
        audioAcquired = await PlatformStorage.beginPlayback();
      }
      MediaKit.ensureInitialized();
      player = Player(
        configuration: const PlayerConfiguration(
          title: 'VHDX Reader',
          logLevel: MPVLogLevel.error,
          bufferSize: 8 * 1024 * 1024,
          protocolWhitelist: ['http', 'tcp'],
        ),
      );
      final controller = VideoController(player);
      final native = player.platform;
      if (native is! NativePlayer) throw StateError('Native player required');
      if (Platform.isIOS && !audioAcquired) {
        await native.setProperty('ao', 'null');
      }
      // media_kit enables disk caching by default. Override BEFORE opening media.
      await native.setProperty('cache-on-disk', 'no');
      if (await native.getProperty('cache-on-disk') != 'no') {
        throw StateError('Cannot disable media disk cache');
      }
      await native.setProperty('demuxer-max-back-bytes', '${2 * 1024 * 1024}');
      await native.setProperty('cache-secs', '5');
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
      // add uses loadfile directly; open writes a temporary playlist to disk.
      await player.add(Media(media['url'] as String));
      await native.setProperty('playlist-pos', '0');
      return source;
    } catch (_) {
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

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    // Revoke access immediately, then release the player and its buffered packets.
    unawaited(
      backend
          .request({'op': 'media_close', 'file': file})
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(
      _commands
          .then((_) async {
            try {
              await player.dispose();
            } finally {
              if (_ownsPlaybackSession) await PlatformStorage.endPlayback();
            }
          })
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}

class MediaPreview extends StatefulWidget {
  const MediaPreview({super.key, required this.source, required this.active});
  final MediaPreviewSource source;
  final bool active;
  @override
  State<MediaPreview> createState() => _MediaPreviewState();
}

class _MediaPreviewState extends State<MediaPreview> {
  @override
  void initState() {
    super.initState();
    widget.source.setVisible(widget.active);
  }

  @override
  void didUpdateWidget(covariant MediaPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      widget.source.setVisible(widget.active);
    }
  }

  @override
  Widget build(BuildContext context) => Video(
    controller: widget.source.controller,
    controls: (state) => _PlaybackControls(source: widget.source),
    pauseUponEnteringBackgroundMode: true,
    resumeUponEnteringForegroundMode: false,
  );
}

String mediaTime(Duration time) {
  final seconds = time.inSeconds.clamp(0, 999999);
  final minutes = seconds ~/ 60;
  return minutes >= 60
      ? '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
}

class _PlaybackControls extends StatefulWidget {
  const _PlaybackControls({required this.source});
  final MediaPreviewSource source;
  @override
  State<_PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<_PlaybackControls> {
  double? _drag;
  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.space) {
        unawaited(widget.source.toggle());
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.escape &&
          isFullscreen(context)) {
        unawaited(exitFullscreen(context));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: AnimatedBuilder(
      animation: widget.source,
      builder: (context, child) {
        final source = widget.source;
        final duration = source.duration.inMilliseconds.toDouble();
        final position = (_drag ?? source.position.inMilliseconds.toDouble())
            .clamp(0.0, duration > 0 ? duration : 1.0);
        return Stack(
          children: [
            if (source.error != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(18),
                  color: Colors.black87,
                  child: Text(
                    source.error!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              )
            else if (source.buffering)
              const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                color: const Color(0xcc101820),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!source.audioOutputAvailable)
                        const Text(
                          '模拟器不输出声音，请在真机验证音频。',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      Slider(
                        key: const Key('media-seek'),
                        value: position,
                        max: duration > 0 ? duration : 1,
                        onChangeStart: duration > 0
                            ? (value) => setState(() => _drag = value)
                            : null,
                        onChanged: duration > 0
                            ? (value) => setState(() => _drag = value)
                            : null,
                        onChangeEnd: duration > 0
                            ? (value) {
                                setState(() => _drag = null);
                                unawaited(
                                  source.seek(
                                    Duration(milliseconds: value.round()),
                                  ),
                                );
                              }
                            : null,
                      ),
                      Row(
                        children: [
                          IconButton(
                            key: const Key('media-play'),
                            tooltip: source.playing ? '暂停' : '播放',
                            onPressed: source.toggle,
                            color: Colors.white,
                            icon: Icon(
                              source.playing ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          Text(
                            '${mediaTime(Duration(milliseconds: position.round()))} / ${mediaTime(source.duration)}',
                            key: const Key('media-time'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: !source.audioOutputAvailable
                                ? '模拟器无音频输出'
                                : source.volume == 0
                                ? '取消静音'
                                : '静音',
                            onPressed: source.audioOutputAvailable
                                ? () => source.setVolume(
                                    source.volume == 0 ? 100 : 0,
                                  )
                                : null,
                            color: Colors.white,
                            icon: Icon(
                              source.volume == 0
                                  ? Icons.volume_off
                                  : Icons.volume_up,
                            ),
                          ),
                          SizedBox(
                            width: MediaQuery.sizeOf(context).width < 480
                                ? 64
                                : 100,
                            child: Slider(
                              key: const Key('media-volume'),
                              value: source.volume.clamp(0, 100),
                              max: 100,
                              onChanged: source.audioOutputAvailable
                                  ? source.setVolume
                                  : null,
                            ),
                          ),
                          IconButton(
                            key: const Key('media-fullscreen'),
                            tooltip: isFullscreen(context) ? '退出全屏' : '全屏',
                            onPressed: () => toggleFullscreen(context),
                            color: Colors.white,
                            icon: Icon(
                              isFullscreen(context)
                                  ? Icons.fullscreen_exit
                                  : Icons.fullscreen,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}
