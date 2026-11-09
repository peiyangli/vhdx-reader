import 'disk_cache_settings.dart';
import 'playback_buffer_settings.dart';
import 'package:flutter/material.dart';
import 'platform_storage.dart';
import 'recent_images.dart';
import 'window_chrome.dart';
import 'screen_layout.dart';
import 'cache_settings.dart';
import 'browser_settings.dart';
import 'package:flutter/services.dart';

class DiskDrawer extends StatelessWidget {
  const DiskDrawer({
    super.key,
    required this.images,
    required this.activeImageId,
    required this.onSelect,
    required this.onAdd,
    required this.onSettings,
    required this.actions,
    this.recents = const [],
    this.onRecent,
    this.onRemoveRecent,
    this.onClearRecents,
  });
  final Map<int, String> images;
  final int? activeImageId;
  final ValueChanged<int> onSelect;
  final VoidCallback? onAdd;
  final VoidCallback onSettings;
  final List<Widget> actions;
  final List<RecentImage> recents;
  final ValueChanged<RecentImage>? onRecent;
  final ValueChanged<RecentImage>? onRemoveRecent;
  final VoidCallback? onClearRecents;

  @override
  Widget build(BuildContext context) => Drawer(
    width: (MediaQuery.sizeOf(context).width * 0.88).clamp(0.0, 340.0),
    backgroundColor: Colors.white,
    child: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              ScreenLayout(context).compact ? 8 : 24,
              24,
              8,
            ),
            child: const Text(
              '磁盘',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                ListTile(
                  key: const Key('open-image'),
                  leading: const Icon(Icons.add),
                  title: const Text('添加镜像'),
                  enabled: onAdd != null,
                  onTap: onAdd,
                ),
                const Divider(),
                const Padding(
                  padding: EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Text(
                    '已加载磁盘',
                    style: TextStyle(fontSize: 12, color: Color(0xff718098)),
                  ),
                ),
                if (images.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '尚未添加镜像',
                      style: TextStyle(color: Color(0xff8590a0)),
                    ),
                  ),
                for (final image in images.entries)
                  ListTile(
                    key: ValueKey('image-tab-${image.key}'),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    selected: image.key == activeImageId,
                    selectedTileColor: const Color(0xffedf2ff),
                    leading: const Icon(Icons.storage_outlined),
                    title: Text(
                      PlatformStorage.displayName(image.value),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: image.key == activeImageId
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () => onSelect(image.key),
                  ),
                if (actions.isNotEmpty) ...[
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Text(
                      '当前磁盘',
                      style: TextStyle(fontSize: 12, color: Color(0xff718098)),
                    ),
                  ),
                  ...actions,
                ],
                if (recents.isNotEmpty) ...[
                  const Divider(height: 24),
                  RecentImagesList(
                    items: recents,
                    onOpen: onRecent,
                    onRemove: onRemoveRecent,
                    onClear: onClearRecents,
                  ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: ListTile(
              key: const Key('settings-nav'),
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              trailing: const Icon(Icons.chevron_right, size: 20),
              onTap: onSettings,
            ),
          ),
        ],
      ),
    ),
  );
}

class RecentImagesList extends StatelessWidget {
  const RecentImagesList({
    super.key,
    required this.items,
    this.onOpen,
    this.onRemove,
    this.onClear,
  });
  final List<RecentImage> items;
  final ValueChanged<RecentImage>? onOpen;
  final ValueChanged<RecentImage>? onRemove;
  final VoidCallback? onClear;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          const Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: 12),
              child: Text(
                '最近打开',
                style: TextStyle(fontSize: 13, color: Color(0xff718098)),
              ),
            ),
          ),
          TextButton(
            key: const Key('clear-recents'),
            onPressed: onClear,
            child: const Text('清空记录'),
          ),
        ],
      ),
      for (final item in items)
        ListTile(
          key: ValueKey('recent-image-${item.path}'),
          leading: const Icon(Icons.history),
          title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: PlatformStorage.isDocument(item.path)
              ? null
              : Text(
                  item.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11),
                ),
          enabled: onOpen != null,
          onTap: onOpen == null ? null : () => onOpen!(item),
          trailing: IconButton(
            tooltip: '移除记录',
            onPressed: onRemove == null ? null : () => onRemove!(item),
            icon: const Icon(Icons.close, size: 18),
          ),
        ),
    ],
  );
}

class ReaderSettingsPage extends StatelessWidget {
  const ReaderSettingsPage({
    super.key,
    required this.showSystem,
    this.direction,
    this.onDirection,
    this.showShake = false,
    this.shakeEnabled = false,
    this.shakeAvailable = false,
    this.onShake,
    this.windowsChrome = false,
    required this.busy,
    required this.onShowSystem,
    required this.onCredentials,
    required this.onBack,
    this.cacheSettings = const CacheSettings(),
    this.onCacheSettings,
    this.onClearThumbnails,
    this.onClearFileDiskCache,
    this.diskCacheError,
    this.seekSeconds = 5,
    this.onSeekSeconds,
  });
  final int seekSeconds;
  final ValueChanged<int>? onSeekSeconds;
  final Future<void> Function()? onClearThumbnails;
  final Future<void> Function()? onClearFileDiskCache;
  final String? diskCacheError;
  final CacheSettings cacheSettings;
  final ValueChanged<CacheSettings>? onCacheSettings;
  final bool showShake;
  final bool shakeEnabled;
  final bool shakeAvailable;
  final ValueChanged<bool>? onShake;
  final ScreenDirection? direction;
  final ValueChanged<ScreenDirection>? onDirection;
  final bool windowsChrome;
  final bool showSystem;
  final bool busy;
  final ValueChanged<bool> onShowSystem;
  final VoidCallback onCredentials;
  final VoidCallback onBack;

  Widget _cacheOption(BuildContext context, {required String kind}) {
    final (title, current, options, format) = switch (kind) {
      'plaintext' => (
        '文件读取缓存（内存）',
        cacheSettings.plaintextMiB,
        CacheSettings.plaintextOptions,
        CacheSettings.formatMiB,
      ),
      'plaintext-page' => (
        '文件缓存分块大小',
        cacheSettings.plaintextPageKiB,
        CacheSettings.plaintextPageOptions,
        CacheSettings.formatKiB,
      ),
      _ => (
        'BitLocker 密文缓存',
        cacheSettings.ciphertextMiB,
        CacheSettings.ciphertextOptions,
        CacheSettings.formatMiB,
      ),
    };
    return ListTile(
      key: ValueKey('cache-$kind'),
      leading: Icon(
        kind == 'ciphertext'
            ? Icons.enhanced_encryption_outlined
            : Icons.memory_outlined,
      ),
      title: Text(title),
      subtitle: Text(
        kind == 'plaintext-page'
            ? '${format(current)} / 块 · 最多 ${cacheSettings.plaintextPageCount} 块'
            : '${format(current)} / 卷',
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      enabled: onCacheSettings != null,
      onTap: () async {
        final selected = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(title),
            children: [
              for (final size in options)
                SimpleDialogOption(
                  key: ValueKey('cache-$kind-$size'),
                  onPressed: () => Navigator.pop(context, size),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          size == current
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            '${format(size)}${size == options.first ? '（默认）' : ''}',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
        if (selected != null && selected != current) {
          onCacheSettings?.call(switch (kind) {
            'plaintext' => cacheSettings.copyWith(plaintextMiB: selected),
            'plaintext-page' => cacheSettings.copyWith(
              plaintextPageKiB: selected,
            ),
            _ => cacheSettings.copyWith(ciphertextMiB: selected),
          });
        }
      },
    );
  }

  Widget _diskOption(BuildContext context, {required bool capacity}) {
    final settings = cacheSettings.disk;
    final name = capacity ? 'capacity' : 'retention';
    final title = capacity ? '磁盘缓存最大容量' : '磁盘缓存自动清理';
    final current = capacity ? settings.maxGiB : settings.retentionDays;
    String label(int value) => capacity
        ? '$value GiB'
        : value == 0
        ? '永久（不按时间清理）'
        : '$value 天未使用后清理';
    return ListTile(
      key: ValueKey('file-disk-$name'),
      title: Text(title),
      subtitle: Text('${label(current)}${capacity ? ' / 所有镜像共用' : ''}'),
      leading: Icon(
        capacity ? Icons.storage_outlined : Icons.auto_delete_outlined,
      ),
      trailing: const Icon(Icons.chevron_right, size: 20),
      enabled: onCacheSettings != null,
      onTap: () async {
        final selected = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: Text(title),
            children: [
              for (final value
                  in capacity
                      ? DiskCacheSettings.capacityOptions
                      : DiskCacheSettings.retentionOptions)
                SimpleDialogOption(
                  key: ValueKey('file-disk-$name-$value'),
                  onPressed: () => Navigator.pop(context, value),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '${label(value)}${value == current ? ' ✓' : ''}',
                    ),
                  ),
                ),
            ],
          ),
        );
        if (selected != null && selected != current) {
          onCacheSettings?.call(
            cacheSettings.copyWith(
              disk: capacity
                  ? settings.copyWith(maxGiB: selected)
                  : settings.copyWith(retentionDays: selected),
            ),
          );
        }
      },
    );
  }

  Widget _playbackOption(
    BuildContext context, {
    required String name,
    required String title,
    required String unit,
    required int current,
    required int defaultValue,
    required List<int> options,
    required PlaybackBufferSettings Function(int) update,
  }) => ListTile(
    key: ValueKey('playback-$name'),
    leading: const Icon(Icons.slow_motion_video_outlined),
    title: Text(title),
    subtitle: Text('$current $unit'),
    trailing: const Icon(Icons.chevron_right, size: 20),
    enabled: onCacheSettings != null,
    onTap: () async {
      final selected = await showDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(title),
          children: [
            for (final value in options)
              SimpleDialogOption(
                key: ValueKey('playback-$name-$value'),
                onPressed: () => Navigator.pop(context, value),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        value == current
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          '$value $unit${value == defaultValue ? '（默认）' : ''}',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
      if (selected != null && selected != current) {
        onCacheSettings?.call(
          cacheSettings.copyWith(playback: update(selected)),
        );
      }
    },
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): onBack},
    child: Focus(
      autofocus: true,
      child: Scaffold(
        appBar: AppBar(
          title: windowsChrome
              ? Row(
                  children: [
                    const Text('设置'),
                    const Expanded(
                      child: SizedBox(height: 60, child: WindowDragArea()),
                    ),
                  ],
                )
              : const Text('设置'),
          centerTitle: false,
          toolbarHeight: ScreenLayout(context).toolbarHeight,
          systemOverlayStyle: readerSystemStyle,
          actions: [if (windowsChrome) const WindowButtons()],
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            key: const Key('settings-back'),
            tooltip: '返回文件',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: SafeArea(
          top: false,
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                children: [
                  if (direction != null) ...[
                    ListTile(
                      key: const Key('screen-direction'),
                      leading: const Icon(Icons.screen_rotation_outlined),
                      title: const Text('屏幕方向'),
                      subtitle: Text(direction!.label),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      enabled: onDirection != null,
                      onTap: () async {
                        final selected = await showDialog<ScreenDirection>(
                          context: context,
                          builder: (context) => SimpleDialog(
                            title: const Text('屏幕方向'),
                            children: [
                              for (final value in ScreenDirection.values)
                                SimpleDialogOption(
                                  key: ValueKey('direction-${value.name}'),
                                  onPressed: () =>
                                      Navigator.pop(context, value),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          value == direction
                                              ? Icons.radio_button_checked
                                              : Icons.radio_button_unchecked,
                                          color: value == direction
                                              ? const Color(0xff2563eb)
                                              : null,
                                        ),
                                        const SizedBox(width: 12),
                                        Flexible(child: Text(value.label)),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                        if (selected != null) onDirection?.call(selected);
                      },
                    ),
                    if (showShake)
                      SwitchListTile.adaptive(
                        key: const Key('shake-rotation'),
                        title: const Text('摇晃确认旋转'),
                        subtitle: Text(
                          !shakeAvailable
                              ? '此设备不支持'
                              : direction != ScreenDirection.automatic
                              ? '仅在屏幕方向为自动时生效'
                              : '保持目标方向，摇晃两三下后拿稳；关闭后恢复跟随系统',
                        ),
                        value: shakeEnabled,
                        onChanged: onShake,
                      ),
                    const Divider(),
                  ],
                  if (onSeekSeconds != null) ...[
                    ListTile(
                      key: const Key('playback-seek-seconds'),
                      leading: const Icon(Icons.keyboard_outlined),
                      title: const Text('快进 / 快退步长'),
                      subtitle: Text('$seekSeconds 秒'),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                      onTap: () async {
                        final selected = await showDialog<int>(
                          context: context,
                          builder: (context) => SimpleDialog(
                            title: const Text('快进 / 快退步长'),
                            children: [
                              for (final seconds in BrowserSettings.seekOptions)
                                SimpleDialogOption(
                                  key: ValueKey('seek-seconds-$seconds'),
                                  onPressed: () =>
                                      Navigator.pop(context, seconds),
                                  child: Text(
                                    '$seconds 秒${seconds == seekSeconds ? ' ✓' : ''}',
                                  ),
                                ),
                            ],
                          ),
                        );
                        if (selected != null) onSeekSeconds!(selected);
                      },
                    ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: Text(
                        '视频快捷键：空格 播放 / 暂停；← / → 快退 / 快进；\n'
                        'PageUp / PageDown 上一个 / 下一个；Ctrl + M 静音；Esc 返回列表。',
                      ),
                    ),
                    const Divider(),
                  ],
                  SwitchListTile.adaptive(
                    key: const Key('show-system'),
                    title: const Text('显示隐藏和系统文件'),
                    subtitle: const Text('应用于所有已加载磁盘'),
                    value: showSystem,
                    onChanged: busy ? null : onShowSystem,
                  ),
                  const Divider(),
                  _playbackOption(
                    context,
                    name: 'buffer-mib',
                    title: '播放器缓冲容量',
                    unit: 'MiB / 视频',
                    current: cacheSettings.playback.forwardMiB,
                    defaultValue: const PlaybackBufferSettings().forwardMiB,
                    options: PlaybackBufferSettings.forwardOptions,
                    update: (value) =>
                        cacheSettings.playback.copyWith(forwardMiB: value),
                  ),
                  _playbackOption(
                    context,
                    name: 'read-ahead-seconds',
                    title: '播放预读时长',
                    unit: '秒',
                    current: cacheSettings.playback.readAheadSeconds,
                    defaultValue:
                        const PlaybackBufferSettings().readAheadSeconds,
                    options: PlaybackBufferSettings.readAheadOptions,
                    update: (value) => cacheSettings.playback.copyWith(
                      readAheadSeconds: value,
                    ),
                  ),
                  _playbackOption(
                    context,
                    name: 'resume-seconds',
                    title: '恢复播放缓冲时长',
                    unit: '秒',
                    current: cacheSettings.playback.resumeSeconds,
                    defaultValue: const PlaybackBufferSettings().resumeSeconds,
                    options: PlaybackBufferSettings.resumeOptions,
                    update: (value) =>
                        cacheSettings.playback.copyWith(resumeSeconds: value),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Text(
                      '播放器缓冲用于应对外接盘读取和视频码率波动，仅保存在内存。预读同时受容量和时长限制。每个打开的视频单独计量，与下方文件读取缓存分别占用内存。\n'
                      '恢复播放缓冲时长是开始播放、拖动或卡顿后希望攒够的视频时长，并非固定等待时间；调大可能减少反复卡顿，也可能延长等待。修改后下次打开视频生效。',
                      style: TextStyle(fontSize: 12, color: Color(0xff718098)),
                    ),
                  ),
                  const Divider(),
                  SwitchListTile.adaptive(
                    key: const Key('file-cache-enabled'),
                    title: const Text('文件缓存总开关'),
                    subtitle: const Text(
                      '统一控制文件内存、BitLocker 密文和文件磁盘缓存；播放器缓冲独立设置',
                    ),
                    value: cacheSettings.enabled,
                    onChanged: onCacheSettings == null
                        ? null
                        : (value) => onCacheSettings!(
                            cacheSettings.copyWith(enabled: value),
                          ),
                  ),
                  SwitchListTile.adaptive(
                    key: const Key('file-disk-enabled'),
                    title: const Text('文件磁盘缓存'),
                    subtitle: const Text('将读取过的数据缓存到本机内部存储，重开后可复用'),
                    value: cacheSettings.disk.enabled,
                    onChanged: onCacheSettings == null
                        ? null
                        : (value) => onCacheSettings!(
                            cacheSettings.copyWith(
                              disk: cacheSettings.disk.copyWith(enabled: value),
                            ),
                          ),
                  ),
                  _diskOption(context, capacity: true),
                  _diskOption(context, capacity: false),
                  ListTile(
                    key: const Key('clear-file-disk-cache'),
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('立即清空文件磁盘缓存'),
                    onTap: onClearFileDiskCache,
                  ),
                  if (diskCacheError != null)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(diskCacheError!),
                    ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Text(
                      '与内存缓存分别计量，磁盘容量由所有镜像共用。按需写入，容量满时淘汰最久未使用的数据；启动、读写和修改设置时检查过期数据。“永久”不按时间清理，容量满时仍会淘汰。\n'
                      'BitLocker 解密后的数据以明文保存在本机。关闭开关会停止使用磁盘缓存，已有文件保留，可手动清空。分块大小使用下方“文件缓存分块大小”；修改磁盘选项立即生效。',
                      style: TextStyle(fontSize: 12, color: Color(0xff718098)),
                    ),
                  ),
                  const Divider(),
                  _cacheOption(context, kind: 'plaintext'),
                  _cacheOption(context, kind: 'plaintext-page'),
                  _cacheOption(context, kind: 'ciphertext'),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Text(
                      '读取缓存仅保存在内存，按需分块填充，达到上限后淘汰最久未访问的块。容量越大，可保留的已读数据越多；分块越大，小范围读取时也可能读入更多无关数据。\n'
                      '容量按每个已解锁卷计算，多个卷会累加，并与播放器缓冲分别占用内存。GiB 档位请按设备可用内存选择，不会立即分配全部容量。BitLocker 密文缓存继续使用独立的 64 KiB 分块。\n修改后重新解锁或重新打开镜像生效。',
                      style: TextStyle(fontSize: 12, color: Color(0xff718098)),
                    ),
                  ),
                  const Divider(),
                  ListTile(
                    key: const Key('credential-manager'),
                    leading: const Icon(Icons.key_outlined),
                    title: const Text('已保存的解锁信息'),
                    trailing: const Icon(Icons.chevron_right, size: 20),
                    enabled: !busy,
                    onTap: onCredentials,
                  ),
                  const Divider(),
                  SwitchListTile.adaptive(
                    key: const Key('thumbnail-disk'),
                    title: const Text('普通卷缩略图缓存到本机'),
                    subtitle: const Text('加快再次浏览；本地缩略图缓存总上限 256 MiB'),
                    value: cacheSettings.thumbnailDisk,
                    onChanged: onCacheSettings == null
                        ? null
                        : (value) => onCacheSettings!(
                            cacheSettings.copyWith(thumbnailDisk: value),
                          ),
                  ),
                  SwitchListTile.adaptive(
                    key: const Key('bitlocker-thumbnail-disk'),
                    title: const Text('BitLocker 缩略图缓存到本机'),
                    subtitle: const Text(
                      '默认关闭。开启后会在设备上保存未加密的图片和视频缩略图；锁定卷后应用不再显示，但本地文件仍保留。关闭此项会删除已有缓存。',
                    ),
                    value: cacheSettings.bitLockerThumbnailDisk,
                    onChanged: onCacheSettings == null
                        ? null
                        : (value) => onCacheSettings!(
                            cacheSettings.copyWith(
                              bitLockerThumbnailDisk: value,
                            ),
                          ),
                  ),
                  ListTile(
                    key: const Key('clear-thumbnails'),
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('清空缩略图缓存'),
                    onTap: onClearThumbnails,
                  ),
                  const Divider(),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
