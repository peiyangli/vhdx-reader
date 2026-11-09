import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'backend.dart';
import 'cache_settings.dart';
import 'media_preview.dart';
import 'media_open_control.dart';
import 'preview.dart' show isImage, isVideo, extension;
import 'range_reader.dart';

int friendlyTypeOrder(String name) => const [
  '图片',
  '视频',
  '音频',
  'PDF',
  '文档',
  '压缩包',
  '文件',
].indexOf(friendlyType(name));

String friendlyType(String name) {
  if (isImage(name)) return '图片';
  if (isVideo(name)) return '视频';
  final ext = extension(name);
  if ([
    'mp3',
    'flac',
    'wav',
    'aac',
    'm4a',
    'ogg',
    'opus',
    'wma',
  ].contains(ext)) {
    return '音频';
  }
  if (ext == 'pdf') return 'PDF';
  if (['zip', '7z', 'rar', 'tar', 'gz', 'xz'].contains(ext)) return '压缩包';
  if ([
    'txt',
    'md',
    'json',
    'xml',
    'csv',
    'log',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
  ].contains(ext)) {
    return '文档';
  }
  return '文件';
}

class ThumbnailScope extends ChangeNotifier {
  ThumbnailScope(
    this.cache,
    this.backend,
    this.identity, {
    required this.encrypted,
    this.onInvalidated,
  });
  final ThumbnailCache cache;
  final ReaderBackend backend;
  final String identity;
  final bool encrypted;
  final void Function(ReaderFailure)? onInvalidated;
  bool _alive = true;
  bool _active = true;
  int generation = 0;
  bool get available => _alive && _active;
  void setActive(bool value) {
    if (!_alive || value == _active) return;
    _active = value;
    if (!value) cache.cancelScope(this);
    notifyListeners();
  }

  void invalidate() {
    if (!_alive) return;
    _alive = false;
    generation++;
    cache.cancelScope(this);
    cache.evictScope(this);
    notifyListeners();
  }
}

class Thumbnail {
  Thumbnail(this.image, this.duration);
  final ui.Image image;
  final Duration duration;
  Thumbnail clone() => Thumbnail(image.clone(), duration);
  void dispose() => image.dispose();
}

class ThumbnailRequest {
  ThumbnailRequest(this.future, this.cancel);
  final Future<Thumbnail?> future;
  final VoidCallback cancel;
}

class _UnsupportedThumbnail implements Exception {}

class _Job {
  _Job(this.scope, this.path, this.entry, this.key, this.diskKey);
  final ThumbnailScope scope;
  final String path;
  final Map<String, dynamic> entry;
  final String key;
  final String diskKey;
  final done = Completer<Thumbnail?>();
  final stopped = Completer<void>();
  final clock = Stopwatch()..start();
  final cleanups = <Future<void> Function()>[];
  int listeners = 0;
  bool cancelled = false;
  bool timedOut = false;
  bool knownUnavailable = false;
  bool get video => isVideo(entry['name'] as String);
  bool get valid => !cancelled && scope.available;
  void check() {
    if (!valid) throw StateError('Cancelled thumbnail');
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    stopped.complete();
    for (final cleanup in cleanups.toList()) {
      unawaited(cleanup().catchError((Object _) {}));
    }
  }
}

/// One workspace-wide budget and scheduler, including all open images.
class ThumbnailCache extends ChangeNotifier {
  ThumbnailCache({
    this.settings = const CacheSettings(),
    this.directory,
    this.onError,
    this.onTrace,
    @visibleForTesting this.generationTimeout = const Duration(seconds: 8),
    @visibleForTesting this.generator,
    @visibleForTesting this.videoTransport,
    int? memoryLimit,
    this.diskLimit = 256 * 1024 * 1024,
  }) : memoryLimit =
           memoryLimit ??
           ((Platform.isAndroid || Platform.isIOS) ? 24 : 64) * 1024 * 1024;
  CacheSettings settings;
  final Directory? directory;
  final void Function(Object)? onError;
  final void Function(Map<String, dynamic>)? onTrace;
  final Duration generationTimeout;
  final String? videoTransport;
  final Future<Thumbnail?> Function(
    ThumbnailScope,
    String,
    Map<String, dynamic>,
  )?
  generator;
  final int memoryLimit;
  final int diskLimit;
  final _memory = <String, Thumbnail>{};
  final _owners = <String, ThumbnailScope>{};
  final _failures = <String, ({DateTime at, int attempts, bool terminal})>{};
  final _jobs = <String, _Job>{};
  final _queue = Queue<_Job>();
  final _lookupQueue = Queue<_Job>();
  int _lookups = 0;
  int _bytes = 0;
  int _running = 0;
  int _videos = 0;
  int _retiring = 0;
  int _diskEpoch = 0;
  bool _disposed = false;
  Future<void> _diskTail = Future.value();
  Future<T> _disk<T>(Future<T> Function() action) {
    final result = _diskTail.then((_) => action());
    _diskTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Directory>? _rootFuture;
  Future<Directory> _root() => _rootFuture ??= _findRoot();
  Future<Directory> _findRoot() async =>
      directory ??
      Directory('${(await getApplicationCacheDirectory()).path}/thumbnails-v1');
  Map<String, ({int size, DateTime used})>? _diskEntries;
  int _diskBytes = 0;
  void _forgetDisk(String key) {
    final old = _diskEntries?.remove(key);
    if (old != null) _diskBytes -= old.size;
  }

  Future<void> _indexDisk(Directory root) async {
    if (_diskEntries != null) return;
    final entries = <String, ({int size, DateTime used})>{};
    var bytes = 0;
    await for (final file in root.list(followLinks: false)) {
      if (file is! File) continue;
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) continue;
      entries[file.uri.pathSegments.last] = (
        size: stat.size,
        used: stat.modified,
      );
      bytes += stat.size;
    }
    _diskEntries = entries;
    _diskBytes = bytes;
  }

  Future<void> _trimDisk(Directory root) async {
    if (_diskBytes <= diskLimit && _diskEntries!.length <= 10000) return;
    final entries = _diskEntries!.entries.toList()
      ..sort((a, b) => a.value.used.compareTo(b.value.used));
    for (final entry in entries) {
      if (_diskBytes <= diskLimit && _diskEntries!.length <= 10000) break;
      final file = File('${root.path}/${entry.key}');
      if (await file.exists()) await file.delete();
      _forgetDisk(entry.key);
    }
  }

  bool _persistent(ThumbnailScope scope) => scope.encrypted
      ? settings.bitLockerThumbnailDisk
      : settings.thumbnailDisk;

  Future<void> configure(CacheSettings value) async {
    final old = settings;
    settings = value;
    _diskEpoch++;
    // Revisit visible thumbnails under the new policy, including memory hits
    // generated before the user opted into persistent caching.
    for (final key in _memory.keys.toList()) {
      _evict(key);
    }
    _failures.clear();
    if (old.bitLockerThumbnailDisk && !value.bitLockerThumbnailDisk) {
      await clearDisk(encrypted: true);
    }
    if (old.thumbnailDisk && !value.thumbnailDisk) {
      await clearDisk(encrypted: false);
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> clearDisk({bool? encrypted}) => _disk(() async {
    final root = await _root();
    _diskEntries = null;
    _diskBytes = 0;
    if (!await root.exists()) return;
    await for (final file in root.list(followLinks: false)) {
      if (file is File &&
          (encrypted == null ||
              file.uri.pathSegments.last.startsWith(encrypted ? 'b-' : 'p-'))) {
        await file.delete();
      }
    }
  });
  Future<void> clear() async {
    _diskEpoch++;
    for (final job in _jobs.values) {
      job.cancel();
    }
    for (final value in _memory.values) {
      value.dispose();
    }
    _memory.clear();
    _owners.clear();
    _failures.clear();
    _bytes = 0;
    await clearDisk();
    if (!_disposed) notifyListeners();
  }

  void cancelScope(ThumbnailScope scope) {
    for (final job in _jobs.values) {
      if (identical(job.scope, scope)) job.cancel();
    }
  }

  void evictScope(ThumbnailScope scope) {
    for (final key
        in _owners.keys
            .where((key) => identical(_owners[key], scope))
            .toList()) {
      _evict(key);
    }
  }

  void _evict(String key) {
    final value = _memory.remove(key);
    _owners.remove(key);
    if (value != null) {
      _bytes -= value.image.width * value.image.height * 4;
      value.dispose();
    }
  }

  String _hash(ThumbnailScope scope, String path, Map<String, dynamic> entry) {
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'thumb-320-v1',
              scope.identity,
              path,
              entry['size'],
              entry['modified_unix_ms'],
            ]),
          ),
        )
        .toString();
  }

  String _key(ThumbnailScope scope, String hash) =>
      '${identityHashCode(scope)}:${scope.generation}:$hash';

  String _diskKey(ThumbnailScope scope, String hash) =>
      '${scope.encrypted ? 'b' : 'p'}-$hash.thumb';

  Duration? retryDelay(
    ThumbnailScope scope,
    String path,
    Map<String, dynamic> entry,
  ) {
    if (_disposed || !scope.available) return null;
    final failure = _failures[_diskKey(scope, _hash(scope, path, entry))];
    if (failure == null || failure.terminal || failure.attempts >= 3) {
      return null;
    }
    final wait =
        Duration(seconds: failure.attempts == 1 ? 1 : 3) -
        DateTime.now().difference(failure.at);
    return wait.isNegative ? Duration.zero : wait;
  }

  ThumbnailRequest request(
    ThumbnailScope scope,
    String path,
    Map<String, dynamic> entry,
  ) {
    if (_disposed || !scope.available) {
      return ThumbnailRequest(Future.value(), () {});
    }
    final hash = _hash(scope, path, entry);
    final key = _key(scope, hash);
    final hit = _memory.remove(key);
    if (hit != null) {
      _memory[key] = hit;
      return ThumbnailRequest(Future.value(hit.clone()), () {});
    }
    final failure = _failures[_diskKey(scope, hash)];
    if (failure != null &&
        (failure.terminal ||
            DateTime.now().difference(failure.at) <
                Duration(
                  seconds: failure.attempts >= 3
                      ? 30
                      : failure.attempts == 1
                      ? 1
                      : 3,
                ))) {
      return ThumbnailRequest(Future.value(), () {});
    }
    var job = _jobs[key];
    if (job == null || job.cancelled) {
      job = _Job(scope, path, entry, key, _diskKey(scope, hash));
      _jobs[key] = job;
      _lookupQueue.add(job);
      scheduleMicrotask(_pump);
    }
    final current = job;
    current.listeners++;
    var cancelled = false;
    return ThumbnailRequest(
      current.done.future.then(
        (value) => cancelled || !current.valid ? null : value?.clone(),
      ),
      () {
        if (cancelled) return;
        cancelled = true;
        if (--current.listeners == 0) current.cancel();
      },
    );
  }

  void _pump() {
    if (_disposed) return;
    // Cached videos must never wait for an unrelated decoder. Limit cache
    // reads separately so a large directory cannot decode all PNGs at once.
    while (_lookups < 2 && _lookupQueue.isNotEmpty) {
      final job = _lookupQueue.removeFirst();
      _lookups++;
      unawaited(
        _lookup(job).whenComplete(() {
          _lookups--;
          if (job.done.isCompleted && identical(_jobs[job.key], job)) {
            _jobs.remove(job.key);
          }
          _pump();
        }),
      );
    }
    while (_running < 2 && _retiring < 2) {
      final choices = _queue.where((job) => !job.video || _videos == 0);
      if (choices.isEmpty) break;
      final job = choices.first;
      _queue.remove(job);
      if (!job.valid) {
        job.done.complete();
        if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
        continue;
      }
      _running++;
      if (job.video) _videos++;
      unawaited(
        _run(job).whenComplete(() {
          _running--;
          if (job.video) _videos--;
          if (identical(_jobs[job.key], job)) _jobs.remove(job.key);
          _pump();
        }),
      );
    }
  }

  Future<void> _lookup(_Job job) async {
    Thumbnail? value;
    try {
      job.check();
      value = await _readDisk(job);
      job.check();
      if (value != null) {
        _publish(job, value);
        value = null;
      } else if (job.knownUnavailable) {
        job.done.complete();
      } else {
        _queue.add(job);
      }
    } catch (_) {
      if (!job.done.isCompleted) job.done.complete();
    } finally {
      value?.dispose();
    }
  }

  void _publish(_Job job, Thumbnail value) {
    final size = value.image.width * value.image.height * 4;
    while (_memory.isNotEmpty && _bytes + size > memoryLimit) {
      _evict(_memory.keys.first);
    }
    _memory[job.key] = value;
    _owners[job.key] = job.scope;
    _bytes += size;
    _failures.remove(job.diskKey);
    job.done.complete(value);
  }

  Future<void> _run(_Job job) async {
    Thumbnail? value;
    var outcome = 'failed';
    final queuedMs = job.clock.elapsedMilliseconds;
    final timer = Timer(generationTimeout, () {
      job.timedOut = true;
      job.cancel();
    });
    try {
      var abandoned = false;
      var finished = false;
      Thumbnail? produced;
      final generation = (generator == null
          ? _generate(job)
          : generator!(job.scope, job.path, job.entry));
      final guarded = generation
          .then((result) {
            if (abandoned) {
              result?.dispose();
              return null;
            }
            produced = result;
            return result;
          })
          .whenComplete(() {
            finished = true;
            if (abandoned) {
              _retiring--;
              _pump();
            }
          });
      try {
        value = await Future.any<Thumbnail?>([
          guarded,
          job.stopped.future.then<Thumbnail?>(
            (_) => throw StateError('Cancelled thumbnail'),
          ),
        ]);
        produced = null; // Ownership transferred to value.
      } finally {
        if (finished) {
          produced?.dispose();
        }
        if (!finished) {
          abandoned = true;
          _retiring++;
        }
      }
      job.check();
      if (value != null) {
        // Display the decoded frame before encoding/writing a persistent copy.
        // The extra handle remains valid even if the memory cache is evicted.
        timer.cancel();
        final persistent = value.clone();
        _publish(job, value);
        outcome = 'ready';
        value = null;
        try {
          await _writeDisk(job, persistent);
        } finally {
          persistent.dispose();
        }
      } else {
        _recordFailure(job, terminal: true);
        job.done.complete();
      }
    } catch (error) {
      if (job.valid) onError?.call(error);
      if (error is ReaderFailure && error.invalidated && job.scope._alive) {
        job.scope.invalidate();
        job.scope.onInvalidated?.call(error);
      }
      if (!job.done.isCompleted &&
          (job.valid || (job.timedOut && job.scope.available))) {
        _recordFailure(job, terminal: job.timedOut || _terminalFailure(error));
      }
      if (!job.done.isCompleted) job.done.complete();
    } finally {
      timer.cancel();
      value?.dispose();
      _trace(job, {
        'phase': 'generation',
        'outcome': outcome,
        'queue_ms': queuedMs,
        'elapsed_ms': job.clock.elapsedMilliseconds,
        'timed_out': job.timedOut,
        'cancelled': job.cancelled,
      });
    }
  }

  void _trace(_Job job, Map<String, dynamic> value) {
    try {
      onTrace?.call({'key': job.key, ...value});
    } catch (_) {}
  }

  bool _terminalFailure(Object error) {
    // Device/session/queue failures do not establish that a file is undecodable.
    if (error is ReaderFailure) {
      return !error.invalidated &&
          const {
            'unsupported',
            'thumbnail_read_budget',
            'thumbnail_deadline',
          }.contains(error.code);
    }
    return true; // Decoder/format failure, including _UnsupportedThumbnail.
  }

  void _recordFailure(_Job job, {required bool terminal}) {
    _rememberFailure(job.diskKey, terminal: terminal);
    if (terminal) {
      unawaited(_writeDiskEntry(job, {'unavailable': true}, failure: true));
    }
  }

  void _rememberFailure(String key, {bool terminal = false}) {
    final previous = _failures[key];
    final now = DateTime.now();
    _failures[key] = (
      terminal: terminal,
      at: now,
      attempts: previous == null || now.difference(previous.at).inSeconds >= 30
          ? 1
          : previous.attempts + 1,
    );
    while (_failures.length > 256) {
      _failures.remove(_failures.keys.first);
    }
  }

  Future<Thumbnail?> _readDisk(_Job job) async {
    if (!_persistent(job.scope)) return null;
    try {
      final epoch = _diskEpoch;
      final data = await _disk(() async {
        job.check();
        if (epoch != _diskEpoch || !_persistent(job.scope)) return null;
        final file = File('${(await _root()).path}/${job.diskKey}');
        final stat = await file.stat();
        if (stat.type != FileSystemEntityType.file || stat.size > 1024 * 1024) {
          _forgetDisk(job.diskKey);
          return null;
        }
        final result = jsonDecode(await file.readAsString()) as Map;
        final now = DateTime.now();
        if (_diskEntries != null) {
          _forgetDisk(job.diskKey);
          _diskEntries![job.diskKey] = (size: stat.size, used: now);
          _diskBytes += stat.size;
        }
        // Persist approximate LRU age, without a metadata write on every hit.
        if (now.difference(stat.modified).inSeconds >= 60) {
          try {
            await file.setLastModified(now);
          } on FileSystemException {
            /* Read-only caches still serve hits. */
          }
        }
        return result;
      });
      job.check();
      if (data == null || epoch != _diskEpoch || !_persistent(job.scope)) {
        return null;
      }
      if (data['unavailable'] == true) {
        job.knownUnavailable = true;
        _rememberFailure(job.diskKey, terminal: true);
        return null;
      }
      final image = await _decode(base64Decode(data['png'] as String));
      return Thumbnail(image, Duration(milliseconds: data['duration'] as int));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(_Job job, Thumbnail value) async {
    if (!_persistent(job.scope)) return;
    final epoch = _diskEpoch;
    final bytes = await value.image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null || epoch != _diskEpoch) return;
    await _writeDiskEntry(job, {
      'png': base64Encode(bytes.buffer.asUint8List()),
      'duration': value.duration.inMilliseconds,
    });
  }

  Future<void> _writeDiskEntry(
    _Job job,
    Map<String, dynamic> data, {
    bool failure = false,
  }) async {
    if (!_persistent(job.scope)) return;
    final epoch = _diskEpoch;
    bool current() =>
        !_disposed &&
        job.scope.available &&
        (!job.cancelled || (failure && job.timedOut)) &&
        epoch == _diskEpoch &&
        _persistent(job.scope);
    try {
      await _disk(() async {
        if (!current()) return;
        final root = await _root();
        await root.create(recursive: true);
        await _indexDisk(root);
        final destination = File('${root.path}/${job.diskKey}');
        if (_diskEntries!.containsKey(job.diskKey)) return;
        final temporary = File('${destination.path}.tmp');
        try {
          final encoded = jsonEncode(data);
          await temporary.writeAsString(encoded);
          if (!current()) return;
          await temporary.rename(destination.path);
          _diskEntries![job.diskKey] = (
            size: encoded.length,
            used: DateTime.now(),
          );
          _diskBytes += encoded.length;
          await _trimDisk(root);
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      });
    } catch (_) {
      /* Cache failures must not prevent browsing. */
    }
  }

  static Future<ui.Image> _decode(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width * descriptor.height > 40 * 1000 * 1000) {
        throw StateError('Image too large');
      }
      final factor = math.min(
        1.0,
        320 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * factor).round()),
        targetHeight: math.max(1, (descriptor.height * factor).round()),
      );
      return (await codec.getNextFrame()).image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<Thumbnail?> _generate(_Job job) async {
    if (job.video) {
      final control = MediaOpenControl();
      Future<void> abort() async {
        control.cancel();
      }

      // Install BEFORE task creation/media_open, including cancellation while
      // the Rust worker is opening the file or mpv is initializing its output.
      job.cleanups.add(abort);
      final clock = Stopwatch()..start();
      var openMs = 0;
      var screenshotMs = 0;
      int? firstFrameMs;
      MediaPreviewSource? media;
      try {
        job.check();
        media = await MediaPreviewSource.open(
          job.scope.backend,
          job.path,
          thumbnail: true,
          transport: videoTransport,
          cancellation: control,
          onReadTrace: onTrace == null
              ? null
              : (stats) => _trace(job, {'phase': 'reads', ...stats}),
          onDiagnostic: onError,
        );
        openMs = clock.elapsedMilliseconds;
        job.check();
        unawaited(
          media.controller.waitUntilFirstFrameRendered.then((_) {
            firstFrameMs ??= clock.elapsedMilliseconds;
          }),
        );
        await media.player.pause();
        while (true) {
          job.check();
          if (media.error != null) throw _UnsupportedThumbnail();
          final stats = await media.statistics();
          final budget = stats['thumbnail'] as Map?;
          if (budget != null && budget['reason'] != 'active') {
            throw ReaderFailure('thumbnail_${budget['reason']}', '缩略图达到限制。');
          }
          final shot = Stopwatch()..start();
          final bytes = await media.player.screenshot(format: 'image/jpeg');
          screenshotMs += shot.elapsedMilliseconds;
          if (bytes != null) {
            job.check();
            firstFrameMs ??= clock.elapsedMilliseconds;
            return Thumbnail(await _decode(bytes), media.duration);
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      } finally {
        control.cancel();
        final closing = Stopwatch()..start();
        if (media != null) {
          media.dispose();
          await media.closed;
        }
        job.cleanups.remove(abort);
        _trace(job, {
          'phase': 'video',
          'open_ms': openMs,
          'first_frame_ms': firstFrameMs,
          'screenshot_ms': screenshotMs,
          'close_ms': closing.elapsedMilliseconds,
        });
      }
    }
    if (!isImage(job.entry['name'] as String) ||
        (job.entry['size'] as int) > 16 * 1024 * 1024) {
      return null;
    }
    final reader = await BackendRangeReader.open(job.scope.backend, job.path);
    job.cleanups.add(reader.close);
    try {
      job.check();
      if (reader.size > 16 * 1024 * 1024) return null;
      final output = BytesBuilder(copy: false);
      for (var offset = 0; offset < reader.size;) {
        job.check();
        final buffer = Uint8List(math.min(64 * 1024, reader.size - offset));
        final count = await reader.read(buffer, offset, buffer.length);
        if (count == 0) return null;
        output.add(buffer);
        offset += count;
      }
      job.check();
      return Thumbnail(await _decode(output.takeBytes()), Duration.zero);
    } finally {
      job.cleanups.remove(reader.close);
      await reader.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _diskEpoch++;
    for (final job in _jobs.values) {
      job.cancel();
      if (!job.done.isCompleted) job.done.complete();
    }
    for (final value in _memory.values) {
      value.dispose();
    }
    _memory.clear();
    _owners.clear();
    _queue.clear();
    _lookupQueue.clear();
    _bytes = 0;
    super.dispose();
  }
}

class FileThumbnail extends StatefulWidget {
  const FileThumbnail({
    super.key,
    required this.entry,
    required this.path,
    required this.size,
    this.scope,
  });
  final Map<String, dynamic> entry;
  final String path;
  final Size size;
  final ThumbnailScope? scope;
  @override
  State<FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<FileThumbnail> {
  ThumbnailRequest? _request;
  Thumbnail? _value;
  Timer? _delay;
  int _revision = 0;
  @override
  void initState() {
    super.initState();
    widget.scope?.addListener(_reload);
    widget.scope?.cache.addListener(_reload);
    _load();
  }

  @override
  void didUpdateWidget(FileThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope ||
        oldWidget.path != widget.path ||
        oldWidget.entry['size'] != widget.entry['size'] ||
        oldWidget.entry['modified_unix_ms'] !=
            widget.entry['modified_unix_ms'] ||
        oldWidget.entry['directory'] != widget.entry['directory']) {
      oldWidget.scope?.removeListener(_reload);
      oldWidget.scope?.cache.removeListener(_reload);
      widget.scope?.addListener(_reload);
      widget.scope?.cache.addListener(_reload);
      _load();
    }
  }

  void _reload() {
    if (mounted) setState(_load);
  }

  void _load() {
    final revision = ++_revision;
    _delay?.cancel();
    _request?.cancel();
    _value?.dispose();
    _value = null;
    final scope = widget.scope;
    final name = widget.entry['name'] as String;
    if (scope == null ||
        !scope.available ||
        widget.entry['directory'] == true ||
        (!isImage(name) && !isVideo(name))) {
      return;
    }
    _delay = Timer(
      const Duration(milliseconds: 100),
      () => _requestValue(scope, revision),
    );
  }

  Future<void> _requestValue(ThumbnailScope scope, int revision) async {
    if (!mounted || revision != _revision || !scope.available) return;
    final request = scope.cache.request(scope, widget.path, widget.entry);
    _request = request;
    final value = await request.future;
    if (!mounted || revision != _revision || !scope.available) {
      value?.dispose();
      return;
    }
    setState(() {
      _value?.dispose();
      _value = value;
    });
    if (value == null) {
      final retry = scope.cache.retryDelay(scope, widget.path, widget.entry);
      if (retry != null) {
        _delay = Timer(retry, () => _requestValue(scope, revision));
      }
    }
  }

  @override
  void dispose() {
    _revision++;
    _delay?.cancel();
    _request?.cancel();
    _value?.dispose();
    widget.scope?.removeListener(_reload);
    widget.scope?.cache.removeListener(_reload);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final folder = widget.entry['directory'] == true;
    final type = folder ? '文件夹' : friendlyType(widget.entry['name'] as String);
    final (icon, color) = switch (type) {
      '文件夹' => (Icons.folder_rounded, const Color(0xffd7a33f)),
      '图片' => (Icons.image_outlined, const Color(0xff389a78)),
      '视频' => (Icons.movie_outlined, const Color(0xff8c65c5)),
      '音频' => (Icons.music_note_rounded, const Color(0xffd8798c)),
      'PDF' => (Icons.picture_as_pdf_outlined, const Color(0xffcc6464)),
      '压缩包' => (Icons.folder_zip_outlined, const Color(0xffb68a48)),
      '文档' => (Icons.description_outlined, const Color(0xff5688c1)),
      _ => (Icons.insert_drive_file_outlined, const Color(0xff8696aa)),
    };
    final value = widget.scope?.available == true ? _value : null;
    return SizedBox.fromSize(
      size: widget.size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: ColoredBox(
          color: color.withValues(alpha: 0.09),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (value != null)
                RawImage(image: value.image, fit: BoxFit.cover)
              else
                Center(
                  child: Icon(
                    icon,
                    color: color,
                    size: math.min(widget.size.height * .65, 42),
                  ),
                ),
              if (value != null && type == '视频')
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 3,
                      vertical: 1,
                    ),
                    color: Colors.black54,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.play_arrow,
                          color: Colors.white,
                          size: 14,
                        ),
                        if (value.duration.inSeconds > 0)
                          Text(
                            '${value.duration.inMinutes}:${(value.duration.inSeconds % 60).toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
