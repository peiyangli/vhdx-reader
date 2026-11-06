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
    this.seekSeconds = 5,
    this.onSeekSeconds,
  });
  final int seekSeconds;
  final ValueChanged<int>? onSeekSeconds;
  final Future<void> Function()? onClearThumbnails;
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

  Widget _cacheOption(BuildContext context, {required bool plaintext}) {
    final title = plaintext ? '文件读取缓存' : 'BitLocker 密文缓存';
    final current = plaintext
        ? cacheSettings.plaintextMiB
        : cacheSettings.ciphertextMiB;
    final options = plaintext
        ? CacheSettings.plaintextOptions
        : CacheSettings.ciphertextOptions;
    final name = plaintext ? 'plaintext' : 'ciphertext';
    return ListTile(
      key: ValueKey('cache-$name'),
      leading: Icon(
        plaintext ? Icons.memory_outlined : Icons.enhanced_encryption_outlined,
      ),
      title: Text(title),
      subtitle: Text('$current MiB / 卷'),
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
                  key: ValueKey('cache-$name-$size'),
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
                            '$size MiB${size == options.first ? '（默认）' : ''}',
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
            cacheSettings.copyWith(
              plaintextMiB: plaintext ? selected : cacheSettings.plaintextMiB,
              ciphertextMiB: plaintext ? cacheSettings.ciphertextMiB : selected,
            ),
          );
        }
      },
    );
  }

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
                        'Shift + ← / → 上一个 / 下一个；Ctrl + M 静音；Esc 返回列表。',
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
                  _cacheOption(context, plaintext: true),
                  _cacheOption(context, plaintext: false),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Text(
                      '以上两项读取缓存仅保存在内存。文件读取缓存有利于重复读取和来回拖动；密文缓存用于合并 BitLocker 小读取。\n'
                      '按每个已解锁卷分别计算，多个卷会累加。修改后重新解锁或重新打开镜像生效。',
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
