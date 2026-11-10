import 'package:flutter/material.dart';

/// Display-only transform; the decoder and playback state stay untouched.
class VideoZoomController extends ChangeNotifier {
  static const maxScale = 4.0;
  double _scale = 1;
  Offset _offset = Offset.zero;
  Size _viewport = Size.zero;
  Rect _content = Rect.zero;
  double _startScale = 1;
  Offset _anchor = Offset.zero;
  bool _active = false;

  bool get active => _active;
  double get scale => _scale;
  Offset get offset => _offset;

  // Called by the layout owner before rebuilding both frame and controls.
  void layout(Size viewport, double? aspectRatio) {
    final ratio = aspectRatio != null && aspectRatio.isFinite && aspectRatio > 0
        ? aspectRatio
        : viewport.aspectRatio;
    final size = applyBoxFit(
      BoxFit.contain,
      Size(ratio, 1),
      viewport,
    ).destination;
    final content = Alignment.center.inscribe(size, Offset.zero & viewport);
    if (viewport == _viewport && content == _content) return;
    _viewport = viewport;
    _content = content;
    reset(notify: false);
  }

  bool reset({bool notify = true}) {
    final wasActive = _active;
    _active = false;
    _scale = 1;
    _offset = Offset.zero;
    if (wasActive && notify) notifyListeners();
    return wasActive;
  }

  void toggle(Offset point) {
    if (reset()) return;
    if (_viewport.isEmpty) return;
    // Black bars are not video pixels; anchor to the nearest image edge.
    point = Offset(
      point.dx.clamp(_content.left, _content.right),
      point.dy.clamp(_content.top, _content.bottom),
    );
    _active = true;
    _scale = 2;
    _offset = _bounded(point * (1 - _scale));
    notifyListeners();
  }

  void start(Offset focalPoint) {
    _startScale = _scale;
    _anchor = (focalPoint - _offset) / _scale;
  }

  void update(Offset focalPoint, double relativeScale) {
    if (!_active || !relativeScale.isFinite || relativeScale <= 0) return;
    final next = _startScale * relativeScale;
    if (next < 1) {
      reset();
      return;
    }
    _scale = next.clamp(1.0, maxScale);
    _offset = _bounded(focalPoint - _anchor * _scale);
    notifyListeners();
  }

  Offset _bounded(Offset candidate) {
    double axis(double value, double start, double end) {
      // Keep the original fitted image covered. This preserves the tapped
      // pixel exactly, including on letterboxed videos, without losing the
      // image offscreen or exposing more black space than at 1x.
      return value.clamp(end * (1 - _scale), start * (1 - _scale));
    }

    return Offset(
      axis(candidate.dx, _content.left, _content.right),
      axis(candidate.dy, _content.top, _content.bottom),
    );
  }
}

/// Keeps controls and hit testing stationary while only the frame transforms.
class VideoZoomView extends StatelessWidget {
  const VideoZoomView({
    super.key,
    required this.controller,
    required this.child,
    required this.builder,
    this.aspectRatio,
  });

  final VideoZoomController controller;
  final double? aspectRatio;
  final Widget child;
  final Widget Function(BuildContext context, Widget frame) builder;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      controller.layout(constraints.biggest, aspectRatio);
      return AnimatedBuilder(
        animation: controller,
        child: child,
        builder: (context, child) => builder(
          context,
          ClipRect(
            child: Transform(
              key: const Key('video-zoom-frame'),
              transform: Matrix4.identity()
                ..translateByDouble(
                  controller.offset.dx,
                  controller.offset.dy,
                  0,
                  1,
                )
                ..scaleByDouble(controller.scale, controller.scale, 1, 1),
              child: child,
            ),
          ),
        ),
      );
    },
  );
}
