import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'window_chrome.dart';
import 'package:flutter/services.dart';

/// Independent from the decoder so gesture arbitration can be tested directly.
class PlaybackControls extends StatefulWidget {
  const PlaybackControls({
    super.key,
    required this.position,
    required this.duration,
    required this.playing,
    required this.muted,
    required this.onPlay,
    required this.onMute,
    required this.onSeek,
    required this.onExit,
    this.buffering = false,
    this.error,
    this.enabled = true,
    this.seekSeconds = 5,
    this.onPrevious,
    this.onNext,
    this.onHoldStart,
    this.onHoldEnd,
    this.onPullUpdate,
    this.onPullEnd,
    this.onPullCancel,
    this.pulling = false,
  });
  final bool enabled;
  final int seekSeconds;
  final ValueChanged<double>? onPullUpdate;
  final ValueChanged<double>? onPullEnd;
  final VoidCallback? onPullCancel;
  final bool pulling;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool muted;
  final bool buffering;
  final String? error;
  final VoidCallback onPlay;
  final VoidCallback? onMute;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onExit;
  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  final _keyboardFocus = FocusNode();
  Map<ShortcutActivator, VoidCallback> get _bindings => {
    const SingleActivator(LogicalKeyboardKey.escape): widget.onExit,
    const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skip(-1),
    const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skip(1),
    const SingleActivator(LogicalKeyboardKey.keyM, includeRepeats: false): () {
      if (widget.enabled && !widget.pulling) widget.onMute?.call();
    },
    const SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      shift: true,
      includeRepeats: false,
    ): () {
      if (widget.enabled && !widget.pulling) widget.onPrevious?.call();
    },
    const SingleActivator(
      LogicalKeyboardKey.arrowRight,
      shift: true,
      includeRepeats: false,
    ): () {
      if (widget.enabled && !widget.pulling) widget.onNext?.call();
    },
    const SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): () {
      if (widget.enabled && !widget.pulling) widget.onPlay();
    },
  };

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
    _focusWhenReady();
  }

  void _focusWhenReady() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled) _keyboardFocus.requestFocus();
    });
  }

  // Handle preview shortcuts before a focused slider/button consumes the same
  // keys. Scope to this preview's focus tree so dialogs and other tabs keep
  // their own keyboard behavior.
  KeyEventResult _handleKey(KeyEvent event) {
    if (!isDesktopPlatform(defaultTargetPlatform) || !_keyboardFocus.hasFocus) {
      return KeyEventResult.ignored;
    }
    for (final entry in _bindings.entries) {
      if (entry.key.accepts(event, HardwareKeyboard.instance)) {
        entry.value();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  bool _visible = true;
  double? _seek;
  double _down = 0;
  double _across = 0;
  bool _holding = false;
  String? _notice;
  Timer? _noticeTimer;

  void _endHold({bool rebuild = true}) {
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd?.call();
    if (rebuild && mounted) setState(() {});
  }

  void _boundary(String text) {
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _notice = null);
    });
  }

  @override
  void didUpdateWidget(covariant PlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _endHold(rebuild: false);
    if (widget.enabled && !oldWidget.enabled) _focusWhenReady();
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _keyboardFocus.dispose();
    _noticeTimer?.cancel();
    _endHold(rebuild: false);
    super.dispose();
  }

  void _skip(int direction) {
    if (!widget.enabled || widget.pulling || widget.duration <= Duration.zero) {
      return;
    }
    final milliseconds =
        (widget.position.inMilliseconds + direction * widget.seekSeconds * 1000)
            .clamp(0, widget.duration.inMilliseconds);
    widget.onSeek(Duration(milliseconds: milliseconds));
    _boundary('${direction < 0 ? '快退' : '快进'} ${widget.seekSeconds} 秒');
  }

  void _toggleControls() => setState(() => _visible = !_visible);
  static const _shadow = [Shadow(color: Colors.black87, blurRadius: 4)];

  @override
  Widget build(BuildContext context) {
    final duration = widget.duration.inMilliseconds.toDouble();
    final position = (_seek ?? widget.position.inMilliseconds.toDouble()).clamp(
      0.0,
      duration > 0 ? duration : 1.0,
    );
    return CallbackShortcuts(
      bindings: _bindings,
      child: Focus(
        focusNode: _keyboardFocus,
        autofocus: true,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Semantics(
                label: _visible ? '隐藏播放控件' : '显示播放控件',
                onDismiss: widget.onExit,
                child: Listener(
                  onPointerUp: (_) => _endHold(),
                  onPointerCancel: (_) {
                    _endHold();
                    widget.onPullCancel?.call();
                  },
                  child: GestureDetector(
                    key: const Key('media-surface'),
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.pulling ? null : _toggleControls,
                    onLongPressStart:
                        widget.enabled &&
                            !widget.pulling &&
                            widget.onHoldStart != null
                        ? (_) {
                            setState(() => _holding = true);
                            widget.onHoldStart!();
                          }
                        : null,
                    onLongPressEnd: (_) => _endHold(),
                    onLongPressCancel: _endHold,
                    onHorizontalDragStart: widget.enabled && !widget.pulling
                        ? (_) => _across = 0
                        : null,
                    onHorizontalDragUpdate: widget.enabled && !widget.pulling
                        ? (details) => _across += details.delta.dx
                        : null,
                    onHorizontalDragCancel: () => _across = 0,
                    onHorizontalDragEnd: widget.enabled && !widget.pulling
                        ? (details) {
                            if (_across.abs() >= 80 ||
                                (_across.abs() >= 24 &&
                                    (details.primaryVelocity ?? 0).abs() >
                                        700)) {
                              final next = _across < 0;
                              final action = next
                                  ? widget.onNext
                                  : widget.onPrevious;
                              if (action != null) {
                                action();
                              } else {
                                _boundary(next ? '已经是最后一个视频' : '已经是第一个视频');
                              }
                            }
                            _across = 0;
                          }
                        : null,
                    onVerticalDragStart: (_) => _down = 0,
                    onVerticalDragUpdate: (details) {
                      _down += details.delta.dy;
                      widget.onPullUpdate?.call(details.delta.dy);
                    },
                    onVerticalDragCancel: () {
                      _down = 0;
                      widget.onPullCancel?.call();
                    },
                    onVerticalDragEnd: (details) {
                      if (widget.onPullEnd != null) {
                        widget.onPullEnd!(details.primaryVelocity ?? 0);
                        _down = 0;
                        return;
                      }
                      if (_down >= 80 ||
                          (_down >= 24 &&
                              (details.primaryVelocity ?? 0) > 700)) {
                        widget.onExit();
                      }
                      _down = 0;
                    },
                  ),
                ),
              ),
            ),
            if (!widget.pulling && (_holding || _notice != null))
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: SafeArea(
                    bottom: false,
                    minimum: const EdgeInsets.all(16),
                    child: Text(
                      _holding ? '2 倍速播放' : _notice!,
                      key: const Key('media-gesture-notice'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        shadows: _shadow,
                      ),
                    ),
                  ),
                ),
              ),
            if (!widget.pulling && widget.error != null)
              IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        shadows: _shadow,
                      ),
                    ),
                  ),
                ),
              )
            else if (!widget.pulling && widget.buffering)
              const IgnorePointer(
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: SafeArea(
                top: false,
                minimum: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: ExcludeSemantics(
                  excluding: !_visible || widget.pulling,
                  child: IgnorePointer(
                    ignoring: !_visible || widget.pulling,
                    child: AnimatedOpacity(
                      key: const Key('media-controls'),
                      opacity: _visible && !widget.pulling ? 1 : 0,
                      duration: const Duration(milliseconds: 160),
                      child: SizedBox(
                        height: 48,
                        child: Material(
                          type: MaterialType.transparency,
                          child: Row(
                            children: [
                              IconButton(
                                key: const Key('media-play'),
                                tooltip: widget.playing ? '暂停' : '播放',
                                onPressed: widget.enabled
                                    ? widget.onPlay
                                    : null,
                                color: Colors.white,
                                icon: Icon(
                                  widget.playing
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  shadows: _shadow,
                                ),
                              ),
                              Expanded(
                                child: SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    activeTrackColor: Colors.white,
                                    inactiveTrackColor: Colors.white38,
                                    thumbColor: Colors.white,
                                    overlayColor: Colors.white24,
                                    trackHeight: 3,
                                  ),
                                  child: Slider(
                                    key: const Key('media-seek'),
                                    value: position,
                                    max: duration > 0 ? duration : 1,
                                    semanticFormatterCallback: (value) =>
                                        '${(value / 1000).round()} 秒',
                                    onChangeStart:
                                        widget.enabled && duration > 0
                                        ? (value) =>
                                              setState(() => _seek = value)
                                        : null,
                                    onChanged: widget.enabled && duration > 0
                                        ? (value) =>
                                              setState(() => _seek = value)
                                        : null,
                                    onChangeEnd: widget.enabled && duration > 0
                                        ? (value) {
                                            setState(() => _seek = null);
                                            widget.onSeek(
                                              Duration(
                                                milliseconds: value.round(),
                                              ),
                                            );
                                          }
                                        : null,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: const Key('media-mute'),
                                tooltip: widget.muted ? '取消静音' : '静音',
                                onPressed: widget.enabled
                                    ? widget.onMute
                                    : null,
                                color: Colors.white,
                                disabledColor: Colors.white38,
                                icon: Icon(
                                  widget.muted
                                      ? Icons.volume_off
                                      : Icons.volume_up,
                                  shadows: _shadow,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
