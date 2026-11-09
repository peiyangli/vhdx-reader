/// Packet buffering for newly opened videos, independent of volume caches.
class PlaybackBufferSettings {
  const PlaybackBufferSettings({
    this.forwardMiB = 64,
    this.readAheadSeconds = 30,
    this.resumeSeconds = 3,
  });

  static const forwardOptions = [8, 16, 32, 64, 128, 256];
  static const readAheadOptions = [5, 15, 30, 60, 120];
  static const resumeOptions = [1, 3, 5];

  final int forwardMiB;
  final int readAheadSeconds;
  final int resumeSeconds;

  bool get valid =>
      forwardOptions.contains(forwardMiB) &&
      readAheadOptions.contains(readAheadSeconds) &&
      resumeOptions.contains(resumeSeconds);

  PlaybackBufferSettings copyWith({
    int? forwardMiB,
    int? readAheadSeconds,
    int? resumeSeconds,
  }) => PlaybackBufferSettings(
    forwardMiB: forwardMiB ?? this.forwardMiB,
    readAheadSeconds: readAheadSeconds ?? this.readAheadSeconds,
    resumeSeconds: resumeSeconds ?? this.resumeSeconds,
  );

  Map<String, dynamic> toJson() => {
    'forward_mib': forwardMiB,
    'read_ahead_seconds': readAheadSeconds,
    'resume_seconds': resumeSeconds,
  };

  factory PlaybackBufferSettings.fromJson(dynamic value) {
    if (value is! Map) return const PlaybackBufferSettings();
    int option(String name, List<int> options, int fallback) {
      final selected = value[name];
      return selected is int && options.contains(selected)
          ? selected
          : fallback;
    }

    return PlaybackBufferSettings(
      forwardMiB: option('forward_mib', forwardOptions, 64),
      readAheadSeconds: option('read_ahead_seconds', readAheadOptions, 30),
      resumeSeconds: option('resume_seconds', resumeOptions, 3),
    );
  }
}
