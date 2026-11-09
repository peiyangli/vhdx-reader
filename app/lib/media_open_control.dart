import 'dart:async';
import 'backend.dart';

/// Registered before media_open so a late native open cannot escape cleanup.
class MediaOpenControl {
  bool cancelled = false;
  final _listeners = <void Function()>{};
  void add(void Function() listener) {
    if (cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void remove(void Function() listener) => _listeners.remove(listener);
  void check() {
    if (cancelled) throw ReaderFailure('thumbnail_cancelled', '缩略图已取消。');
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

class ThumbnailReadTask {
  ThumbnailReadTask(this.backend, this.control, this.onTrace) {
    control?.add(cancel);
  }
  final ReaderBackend backend;
  final MediaOpenControl? control;
  final void Function(Map<String, dynamic>)? onTrace;
  int? id;
  bool _cancelled = false;
  Future<void>? _finished;
  Future<void> begin() async {
    final result = await backend.request({
      'op': 'thumbnail_begin',
      'trace': onTrace != null,
    });
    id = result['task'] as int;
    if (_cancelled) {
      cancel();
    }
    control?.check();
  }

  void cancel() {
    _cancelled = true;
    final task = id;
    if (task != null) {
      unawaited(
        backend
            .request({'op': 'thumbnail_cancel', 'task': task})
            .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  Future<void> finish() => _finished ??= _finish();
  Future<void> _finish() async {
    control?.remove(cancel);
    final task = id;
    if (task == null) return;
    try {
      final stats = await backend.request({
        'op': 'thumbnail_finish',
        'task': task,
      });
      onTrace?.call(stats);
    } catch (_) {
      /* Context retirement may already have removed the task. */
    }
  }
}
