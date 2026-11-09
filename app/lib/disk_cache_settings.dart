class DiskCacheSettings {
  const DiskCacheSettings({
    this.enabled = false,
    this.maxGiB = 8,
    this.retentionDays = 7,
  });
  static const capacityOptions = [1, 2, 4, 8, 16, 32, 64, 128];
  static const retentionOptions = [0, 1, 7, 30];
  final bool enabled;
  final int maxGiB;
  final int retentionDays;
  bool get valid =>
      capacityOptions.contains(maxGiB) &&
      retentionOptions.contains(retentionDays);
  String get retentionLabel =>
      retentionDays == 0 ? '永久（不按时间清理）' : '$retentionDays 天未使用后清理';
  DiskCacheSettings copyWith({
    bool? enabled,
    int? maxGiB,
    int? retentionDays,
  }) => DiskCacheSettings(
    enabled: enabled ?? this.enabled,
    maxGiB: maxGiB ?? this.maxGiB,
    retentionDays: retentionDays ?? this.retentionDays,
  );
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'max_gib': maxGiB,
    'retention_days': retentionDays,
  };
  factory DiskCacheSettings.fromJson(dynamic value) {
    if (value is! Map) return const DiskCacheSettings();
    return DiskCacheSettings(
      enabled: value['enabled'] == true,
      maxGiB:
          value['max_gib'] is int && capacityOptions.contains(value['max_gib'])
          ? value['max_gib'] as int
          : 8,
      retentionDays:
          value['retention_days'] is int &&
              retentionOptions.contains(value['retention_days'])
          ? value['retention_days'] as int
          : 7,
    );
  }
}
