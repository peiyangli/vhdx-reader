import 'package:flutter/material.dart';

/// Keeps the hit-test surface stationary while the paused video follows a pull.
class VideoDismissView extends StatefulWidget {
  const VideoDismissView({
    super.key,
    required this.child,
    required this.controls,
    required this.onStart,
    required this.onCancel,
    required this.onDismiss,
    this.enabled = true,
  });
  final Widget child;
  final Widget Function(
    ValueChanged<double> update,
    ValueChanged<double> end,
    VoidCallback cancel,
    bool pulling,
  )
  controls;
  final VoidCallback onStart;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;
  final bool enabled;

  @override
  State<VideoDismissView> createState() => _VideoDismissViewState();
}

class _VideoDismissViewState extends State<VideoDismissView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  );
  bool _pulling = false;
  bool _settling = false;
  double _height = 1;
  Size? _size;

  void _reset() {
    _offset.stop();
    final wasPulling = _pulling;
    _pulling = _settling = false;
    _offset.value = 0;
    if (wasPulling) widget.onCancel();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    if (_size != null && size != _size) _reset();
    _size = size;
  }

  @override
  void didUpdateWidget(covariant VideoDismissView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _reset();
  }

  void _update(double delta) {
    if (!widget.enabled || _settling) return;
    final next = (_offset.value + delta).clamp(0.0, _height);
    if (!_pulling && next > 0) {
      _pulling = true;
      widget.onStart();
    }
    _offset.value = next;
  }

  Future<void> _finish(double velocity, {bool cancelled = false}) async {
    if (!_pulling || _settling) return;
    _settling = true;
    final dismiss =
        !cancelled &&
        (_offset.value >= (_height * 0.18).clamp(80.0, 140.0) ||
            (_offset.value >= 24 && velocity > 700));
    try {
      await _offset
          .animateTo(
            dismiss ? _height : 0,
            duration: Duration(milliseconds: dismiss ? 220 : 200),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted) return;
    if (dismiss) {
      widget.onDismiss();
    } else {
      setState(() => _pulling = _settling = false);
      widget.onCancel();
    }
  }

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _height = constraints.maxHeight;
      return AnimatedBuilder(
        animation: _offset,
        builder: (context, child) {
          final progress = (_offset.value / _height).clamp(0.0, 1.0);
          final pullProgress =
              (_offset.value / (_height * 0.18).clamp(80.0, 140.0)).clamp(
                0.0,
                1.0,
              );
          return ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  key: const Key('video-dismiss-backdrop'),
                  color: Colors.black.withValues(
                    alpha: 1 - (progress * 2).clamp(0.0, 1.0),
                  ),
                ),
                Transform.translate(
                  key: const Key('video-dismiss-frame'),
                  offset: Offset(0, _offset.value),
                  child: Opacity(
                    key: const Key('video-dismiss-opacity'),
                    opacity: 1 - pullProgress * 0.5,
                    child: child,
                  ),
                ),
                widget.controls(
                  _update,
                  (velocity) => _finish(velocity),
                  () => _finish(0, cancelled: true),
                  _pulling,
                ),
              ],
            ),
          );
        },
        child: widget.child,
      );
    },
  );
}
