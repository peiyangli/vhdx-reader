import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'platform_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'backend.dart';
import 'preview.dart';
import 'pdf_preview.dart';
import 'range_reader.dart';
import 'media_preview.dart';
import 'credential_manager.dart';
import 'file_browser.dart';
import 'window_chrome.dart';
import 'reader_navigation.dart';
import 'screen_layout.dart';
import 'cache_settings.dart';
import 'file_disk_cache.dart';
import 'thumbnails.dart';
import 'recent_images.dart';
import 'browser_settings.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid || Platform.isIOS) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(readerSystemStyle);
  }
  final cacheSettings = await const CacheSettingsStore().load();
  final browserStore = BrowserSettingsStore();
  final browserSettings = await browserStore.load();
  final recents = RecentImagesStore();
  await recents.load();
  runApp(
    _Bootstrap(
      initialImage: args.isEmpty ? null : args.first,
      cacheSettings: cacheSettings,
      browserSettings: browserSettings,
      saveBrowserSettings: browserStore.save,
      recents: recents,
    ),
  );
}

ThemeData readerTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff2563eb),
    brightness: Brightness.light,
  ),
  scaffoldBackgroundColor: Colors.white,
  fontFamily: 'Microsoft YaHei UI',
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xffdce3ee)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: Color(0xffdce3ee)),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    ),
  ),
);

class _Bootstrap extends StatefulWidget {
  const _Bootstrap({
    this.initialImage,
    required this.cacheSettings,
    required this.recents,
    required this.browserSettings,
    required this.saveBrowserSettings,
  });
  final RecentImagesStore recents;
  final BrowserSettings browserSettings;
  final Future<void> Function(BrowserSettings) saveBrowserSettings;
  final String? initialImage;
  final CacheSettings cacheSettings;
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  late Future<NativeBackend> _backend = NativeBackend.start();
  @override
  Widget build(BuildContext context) => FutureBuilder<NativeBackend>(
    future: _backend,
    builder: (context, snapshot) {
      if (snapshot.hasData) {
        return ReaderApp(
          backend: snapshot.data!,
          initialImage: widget.initialImage,
          cacheSettings: widget.cacheSettings,
          browserSettings: widget.browserSettings,
          saveBrowserSettings: widget.saveBrowserSettings,
          recents: widget.recents,
        );
      }
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: readerTheme(),
        home: Scaffold(
          body: Center(
            child: snapshot.hasError
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 40),
                      const SizedBox(height: 20),
                      Text('${snapshot.error}'),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () =>
                            setState(() => _backend = NativeBackend.start()),
                        child: const Text('重试'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        ),
      );
    },
  );
}

class ReaderApp extends StatelessWidget {
  const ReaderApp({
    super.key,
    required this.backend,
    this.initialImage,
    this.createBackend,
    this.pickImages,
    this.platform,
    this.cacheSettings = const CacheSettings(),
    this.fileDiskCache = const FileDiskCache(),
    this.saveCacheSettings,
    this.browserSettings = const BrowserSettings(),
    this.saveBrowserSettings,
    this.recents,
  });
  final BrowserSettings browserSettings;
  final Future<void> Function(BrowserSettings)? saveBrowserSettings;
  final RecentImagesStore? recents;
  final CacheSettings cacheSettings;
  final FileDiskCache fileDiskCache;
  final Future<void> Function(CacheSettings)? saveCacheSettings;
  final TargetPlatform? platform;
  final ReaderBackend backend;
  final String? initialImage;
  final Future<ReaderBackend> Function()? createBackend;
  final Future<List<String>> Function()? pickImages;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'VHDX Reader',
    debugShowCheckedModeBanner: false,
    theme: readerTheme().copyWith(platform: platform),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: _ReaderWorkspace(
      backend: backend,
      initialImage: initialImage,
      createBackend: createBackend ?? NativeBackend.start,
      pickImages: pickImages,
      platform: platform ?? readerTheme().platform,
      cacheSettings: cacheSettings,
      saveCacheSettings: saveCacheSettings ?? const CacheSettingsStore().save,
      fileDiskCache: fileDiskCache,
      recents: recents,
      browserSettings: browserSettings,
      saveBrowserSettings: saveBrowserSettings,
    ),
  );
}

class _ImageTab {
  _ImageTab(this.id, this.backend, this.path);
  final int id;
  final ReaderBackend backend;
  final String? path;
  bool busy = false;
  final home = GlobalKey<_ReaderHomeState>();
}

class _ReaderWorkspace extends StatefulWidget {
  const _ReaderWorkspace({
    required this.backend,
    required this.createBackend,
    this.initialImage,
    this.pickImages,
    required this.platform,
    required this.cacheSettings,
    required this.saveCacheSettings,
    required this.fileDiskCache,
    required this.browserSettings,
    this.saveBrowserSettings,
    this.recents,
  });
  final CacheSettings cacheSettings;
  final Future<void> Function(CacheSettings) saveCacheSettings;
  final FileDiskCache fileDiskCache;
  final BrowserSettings browserSettings;
  final Future<void> Function(BrowserSettings)? saveBrowserSettings;
  final RecentImagesStore? recents;
  final TargetPlatform platform;
  final ReaderBackend backend;
  final String? initialImage;
  final Future<ReaderBackend> Function() createBackend;
  final Future<List<String>> Function()? pickImages;
  @override
  State<_ReaderWorkspace> createState() => _ReaderWorkspaceState();
}

class _ReaderWorkspaceState extends State<_ReaderWorkspace>
    with WidgetsBindingObserver {
  late final List<_ImageTab> _tabs = [
    _ImageTab(0, widget.backend, widget.initialImage),
  ];
  int _active = 0;
  int _nextId = 1;
  bool _opening = false;
  Future<void> _openTail = Future.value();
  late final _recents = widget.recents ?? RecentImagesStore.memory();
  void _recentsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _rememberRecent(String path) async {
    if (!mounted) return;
    try {
      await _recents.record(path, PlatformStorage.displayName(path));
      final bookmark = await PlatformStorage.bookmarkRecent(path);
      if (mounted && bookmark != null) {
        await _recents.attachBookmark(path, bookmark);
      }
    } catch (_) {
      /* History/bookmark failures do not invalidate an open image. */
    }
  }

  void _removeRecent(RecentImage item) {
    unawaited(_recents.remove(item.path).catchError((Object _) {}));
  }

  void _clearRecents() {
    unawaited(_recents.clear().catchError((Object _) {}));
  }

  bool _settingsOpen = false;
  bool _windowVisible = true;
  bool _foreground = true;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => _foreground = readerIsForeground(widget.platform, state));
    }
  }

  bool _quitting = false;
  late final _thumbnails = ThumbnailCache(settings: widget.cacheSettings);

  Future<dynamic> _windowEvent(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'openImages':
        final paths =
            (call.arguments as List?)
                ?.whereType<String>()
                .where((p) => p.toLowerCase().endsWith('.vhdx'))
                .toList() ??
            <String>[];
        if (paths.isNotEmpty) await _enqueueOpen(() => _addPaths(paths));
      case 'hidden':
        setState(() => _windowVisible = false);
      case 'shown':
        setState(() => _windowVisible = true);
      case 'settings':
        setState(() {
          _settingsOpen = true;
          _windowVisible = true;
        });
      case 'lockAll':
        for (final tab in _tabs.toList()) {
          final home = tab.home.currentState;
          if (home == null || home._currentPartition?['kind'] != 'BitLocker') {
            continue;
          }
          tab.backend.cancel();
          for (var i = 0; tab.busy && i < 100; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          if (home.mounted && !tab.busy) {
            await home._lock();
          } else if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('仍有磁盘操作未结束，部分卷尚未锁定，请稍后重试。')),
            );
          }
        }
      case 'requestQuit':
        await _quit();
    }
  }

  Future<void> _quit() async {
    if (_quitting) return;
    _quitting = true;
    if (_opening || _tabs.any((tab) => tab.busy)) {
      final quit = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('退出应用？'),
          content: const Text('仍有操作正在进行，退出会取消未完成的读取或导出。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('继续使用'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('退出'),
            ),
          ],
        ),
      );
      if (quit != true) {
        _quitting = false;
        await windowAction('cancelQuit');
        return;
      }
    }
    for (final tab in _tabs) {
      tab.home.currentState?._clearFiles();
      tab.backend.cancel();
    }
    await Future.wait(_tabs.map((tab) => tab.backend.dispose()));
    await _browserSave;
    await windowAction('quit');
  }

  Future<void> _clearThumbnails() async {
    try {
      await _thumbnails.clear();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('缩略图缓存已清空。')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法完全清空缩略图缓存，请重试。')));
      }
    }
  }

  late BrowserSettings _browserSettings = widget.browserSettings;
  bool get _showSystem => _browserSettings.showSystem;
  Future<void> _browserSave = Future.value();

  void _setBrowserSettings(BrowserSettings value) {
    setState(() => _browserSettings = value);
    final save = widget.saveBrowserSettings;
    if (save == null) return;
    _browserSave = Future.sync(() => save(value)).catchError((Object _) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(content: Text('无法保存文件列表设置，本次显示仍生效，请重试。')),
          );
      }
    });
  }

  ScreenDirection _direction = ScreenDirection.automatic;
  bool _directionBusy = true;
  bool _shakeEnabled = false;
  bool _shakeAvailable = false;
  bool _shakeBusy = false;
  late CacheSettings _cacheSettings = widget.cacheSettings;
  bool _cacheSettingsBusy = false;
  bool _diskCacheReady = false;
  String? _diskCacheError;
  Future<void> _initializeDiskCache() async {
    try {
      await widget.fileDiskCache.configure(
        widget.backend,
        _cacheSettings.disk,
        cacheEnabled: _cacheSettings.enabled,
      );
    } catch (_) {
      _diskCacheError = '磁盘缓存暂不可用，文件仍可读取。请检查本机存储后重新保存设置。';
    } finally {
      if (mounted) setState(() => _diskCacheReady = true);
    }
  }

  Future<void> _clearFileDiskCache() async {
    if (_cacheSettingsBusy) return;
    setState(() => _cacheSettingsBusy = true);
    try {
      await widget.fileDiskCache.clear(
        widget.backend,
        _cacheSettings.disk,
        cacheEnabled: _cacheSettings.enabled,
      );
      if (!mounted) return;
      setState(() => _diskCacheError = null);
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('文件磁盘缓存已清空。开启缓存时，后续读取会重新缓存。')),
        );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(content: Text('无法完全清空文件磁盘缓存，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _cacheSettingsBusy = false);
    }
  }

  Future<void> _setCacheSettings(CacheSettings value) async {
    if (_cacheSettingsBusy) return;
    final diskChanged =
        value.enabled != _cacheSettings.enabled ||
        value.disk.enabled != _cacheSettings.disk.enabled ||
        value.disk.maxGiB != _cacheSettings.disk.maxGiB ||
        value.disk.retentionDays != _cacheSettings.disk.retentionDays ||
        _diskCacheError != null;
    final thumbnailsChanged =
        value.thumbnailDisk != _cacheSettings.thumbnailDisk ||
        value.bitLockerThumbnailDisk != _cacheSettings.bitLockerThumbnailDisk;
    final playbackChanged =
        value.playback.forwardMiB != _cacheSettings.playback.forwardMiB ||
        value.playback.readAheadSeconds !=
            _cacheSettings.playback.readAheadSeconds ||
        value.playback.resumeSeconds != _cacheSettings.playback.resumeSeconds;
    setState(() => _cacheSettingsBusy = true);
    try {
      if (diskChanged) {
        await widget.fileDiskCache.configure(
          widget.backend,
          value.disk,
          cacheEnabled: value.enabled,
        );
      }
      if (thumbnailsChanged) await _thumbnails.configure(value);
      await widget.saveCacheSettings(value);
      if (!mounted) return;
      setState(() {
        _cacheSettings = value;
        _diskCacheError = null;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              diskChanged
                  ? '已保存。文件缓存开关与磁盘策略已生效，已有磁盘文件保留，可手动清空。'
                  : playbackChanged
                  ? '已保存。播放器缓冲下次打开视频时生效。'
                  : '已保存。缩略图设置立即生效，读取缓存重新解锁或打开镜像后生效。',
            ),
          ),
        );
    } catch (_) {
      if (diskChanged) {
        try {
          await widget.fileDiskCache.configure(
            widget.backend,
            _cacheSettings.disk,
            cacheEnabled: _cacheSettings.enabled,
          );
        } catch (_) {
          _diskCacheError = '磁盘缓存暂不可用，请检查本机存储后重试。';
        }
      }
      if (thumbnailsChanged) await _thumbnails.configure(_cacheSettings);
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(const SnackBar(content: Text('无法保存缓存设置，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _cacheSettingsBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_initializeDiskCache());
    setDesktopWindowHandler(_windowEvent);
    _recents.addListener(_recentsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(windowAction('ready'));
    });
    WidgetsBinding.instance.addObserver(this);
    if (widget.platform == TargetPlatform.android ||
        widget.platform == TargetPlatform.iOS) {
      unawaited(_loadDirection());
    } else {
      _directionBusy = false;
    }
  }

  Future<void> _loadDirection() async {
    try {
      final value = await ScreenDirection.load();
      await value.apply();
      if (mounted) setState(() => _direction = value);
      if (widget.platform != TargetPlatform.android) return;
      final shake = await ShakeRotation.load();
      if (mounted) {
        setState(() {
          _shakeEnabled = shake['enabled'] == true;
          _shakeAvailable = shake['available'] == true;
        });
      }
    } on MissingPluginException {
      // Widget tests and platforms without the Android preferences bridge.
    } on PlatformException {
      // Keep the default; a subsequent explicit save reports failures.
    } finally {
      if (mounted) setState(() => _directionBusy = false);
    }
  }

  Future<void> _setDirection(ScreenDirection value) async {
    if (_directionBusy) return;
    setState(() => _directionBusy = true);
    try {
      await value.save();
      if (mounted) setState(() => _direction = value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法保存屏幕方向，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _directionBusy = false);
    }
  }

  Future<void> _setShakeRotation(bool value) async {
    if (_shakeBusy) return;
    setState(() => _shakeBusy = true);
    try {
      await ShakeRotation.save(value);
      if (mounted) setState(() => _shakeEnabled = value);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法保存摇晃旋转设置，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _shakeBusy = false);
    }
  }

  Future<void> _enqueueOpen(Future<void> Function() action) {
    final operation = _openTail.then((_) async {
      if (!mounted || _quitting) return;
      setState(() => _opening = true);
      try {
        await action();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('无法加载镜像，请确认设备已连接，或重新选择文件授权。'),
              action: SnackBarAction(
                label: '重新选择',
                onPressed: () => unawaited(_openImages()),
              ),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _opening = false);
      }
    });
    _openTail = operation;
    return operation;
  }

  Future<void> _openImages() {
    if (_opening) return Future.value();
    return _enqueueOpen(() async {
      final paths = widget.pickImages != null
          ? await widget.pickImages!()
          : await PlatformStorage.chooseImages();
      await _addPaths(paths);
    });
  }

  Future<void> _openRecent(RecentImage item) => _enqueueOpen(() async {
    final existing = _tabs.any(
      (tab) =>
          tab.path != null &&
          imageIdentity(tab.path!) == imageIdentity(item.path),
    );
    final path = existing
        ? item.path
        : await PlatformStorage.restoreRecent(item.path, item.bookmark);
    await _addPaths([path]);
  });

  Future<void> _addPaths(List<String> paths) async {
    for (final path in paths) {
      if (!mounted) break;
      final existing = _tabs.indexWhere(
        (tab) =>
            tab.path != null && imageIdentity(tab.path!) == imageIdentity(path),
      );
      if (existing >= 0) {
        setState(() {
          _active = existing;
          _settingsOpen = false;
        });
        final home = _tabs[existing].home.currentState;
        if (home != null && home._image == null && !home._busy) {
          await home._open(path);
        } else if (home?._image != null) {
          unawaited(_rememberRecent(path));
        }
        continue;
      }
      final empty = _tabs.indexWhere((tab) => tab.path == null);
      final backend = empty >= 0
          ? _tabs[empty].backend
          : await widget.createBackend();
      if (!mounted) {
        if (empty < 0) await backend.dispose();
        break;
      }
      setState(() {
        _settingsOpen = false;
        final tab = _ImageTab(_nextId++, backend, path);
        if (empty >= 0) {
          _tabs[empty] = tab;
          _active = empty;
        } else {
          _tabs.add(tab);
          _active = _tabs.length - 1;
        }
      });
    }
  }

  Future<void> _closeTab(_ImageTab tab) async {
    if (tab.busy || _opening) return;
    setState(() => tab.busy = true);
    tab.backend.beginOperation();
    tab.home.currentState?._invalidateThumbnails();
    try {
      await tab.backend.request({'op': 'close'});
    } catch (_) {
      if (mounted) {
        setState(() => tab.busy = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('关闭镜像失败，请稍后重试。')));
      }
      return;
    }
    if (!mounted) return;
    final index = _tabs.indexOf(tab);
    final last = _tabs.length == 1;
    setState(() {
      if (last) {
        _tabs[0] = _ImageTab(_nextId++, tab.backend, null);
        _active = 0;
      } else {
        _tabs.removeAt(index);
        if (index < _active) _active--;
        if (_active >= _tabs.length) _active = _tabs.length - 1;
      }
    });
    if (!last) await tab.backend.dispose();
  }

  @override
  void dispose() {
    setDesktopWindowHandler(null);
    _recents.removeListener(_recentsChanged);
    if (widget.recents == null) _recents.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _thumbnails.dispose();
    for (final tab in _tabs) {
      unawaited(tab.backend.dispose());
    }
    super.dispose();
  }

  Future<void> _credentials() async {
    if (_opening || _tabs.any((tab) => tab.busy)) return;
    final backend = _tabs[_active].backend;
    backend.beginOperation();
    await showDialog<void>(
      context: context,
      builder: (_) => CredentialManager(backend: backend),
    );
  }

  Widget _homes() => IndexedStack(
    index: _active,
    children: [
      for (final tab in _tabs)
        ReaderHome(
          key: tab.home,
          backend: tab.backend,
          platform: widget.platform,
          cacheSettings: _cacheSettings,
          thumbnails: _thumbnails,
          recents: _recents.items,
          onRecent: _opening ? null : (item) => unawaited(_openRecent(item)),
          onRemoveRecent: _removeRecent,
          onClearRecents: _clearRecents,
          onImageOpened: (path) => unawaited(_rememberRecent(path)),
          initialImage: tab.path,
          active:
              tab == _tabs[_active] &&
              !_settingsOpen &&
              _windowVisible &&
              _foreground,
          onSettings: () => setState(() => _settingsOpen = true),
          browserSettings: _browserSettings,
          onBrowserSettings: _setBrowserSettings,
          images: {
            for (final image in _tabs)
              if (image.path != null) image.id: image.path!,
          },
          activeImageId: tab.id,
          workspaceBusy: _opening || _tabs.any((tab) => tab.busy),
          onSelectImage: (id) {
            final index = _tabs.indexWhere((image) => image.id == id);
            if (index >= 0) setState(() => _active = index);
          },
          onCredentials: _credentials,
          onOpenImages: _openImages,
          onClose: () => _closeTab(tab),
          onBusyChanged: (busy) {
            if (mounted && _tabs.contains(tab)) setState(() => tab.busy = busy);
          },
        ),
    ],
  );

  Widget _workspace() => Column(
    children: [
      if (widget.platform == TargetPlatform.windows) const DesktopTitleBar(),
      Expanded(child: _workspaceBody()),
    ],
  );

  Widget _workspaceBody() => PopScope(
    canPop: !_settingsOpen,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _settingsOpen) {
        setState(() => _settingsOpen = false);
      }
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: readerSystemStyle,
      child: ColoredBox(
        color: Colors.white,
        child: IndexedStack(
          index: _settingsOpen ? 1 : 0,
          children: [
            if (_diskCacheReady)
              _homes()
            else
              const Center(child: CircularProgressIndicator()),
            if (_settingsOpen)
              ReaderSettingsPage(
                key: const Key('reader-settings-page'),
                seekSeconds: _browserSettings.seekSeconds,
                onSeekSeconds: isDesktopPlatform(widget.platform)
                    ? (value) => _setBrowserSettings(
                        _browserSettings.copyWith(seekSeconds: value),
                      )
                    : null,
                cacheSettings: _cacheSettings,
                onCacheSettings: _cacheSettingsBusy ? null : _setCacheSettings,
                onClearThumbnails: _clearThumbnails,
                onClearFileDiskCache: _cacheSettingsBusy
                    ? null
                    : _clearFileDiskCache,
                diskCacheError: _diskCacheError,
                windowsChrome: false,
                direction:
                    widget.platform == TargetPlatform.android ||
                        widget.platform == TargetPlatform.iOS
                    ? _direction
                    : null,
                onDirection: _directionBusy ? null : _setDirection,
                showShake: widget.platform == TargetPlatform.android,
                shakeEnabled: _shakeEnabled,
                shakeAvailable: _shakeAvailable,
                onShake: _directionBusy || _shakeBusy || !_shakeAvailable
                    ? null
                    : _setShakeRotation,
                showSystem: _showSystem,
                busy: _opening || _tabs.any((tab) => tab.busy),
                onShowSystem: (value) => _setBrowserSettings(
                  _browserSettings.copyWith(showSystem: value),
                ),
                onCredentials: _credentials,
                onBack: () => setState(() => _settingsOpen = false),
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => _workspace();
}

class ReaderHome extends StatefulWidget {
  const ReaderHome({
    super.key,
    required this.backend,
    this.initialImage,
    required this.onOpenImages,
    required this.onClose,
    required this.onBusyChanged,
    required this.active,
    required this.platform,
    required this.browserSettings,
    required this.onBrowserSettings,
    this.workspaceBusy = false,
    this.images = const {},
    this.activeImageId,
    this.onSelectImage,
    this.onCredentials,
    this.onSettings,
    this.cacheSettings = const CacheSettings(),
    this.thumbnails,
    this.recents = const [],
    this.onRecent,
    this.onRemoveRecent,
    this.onClearRecents,
    this.onImageOpened,
  });
  final ThumbnailCache? thumbnails;
  final List<RecentImage> recents;
  final ValueChanged<RecentImage>? onRecent;
  final ValueChanged<RecentImage>? onRemoveRecent;
  final VoidCallback? onClearRecents;
  final ValueChanged<String>? onImageOpened;
  final CacheSettings cacheSettings;
  final TargetPlatform platform;
  final ReaderBackend backend;
  final String? initialImage;
  final Future<void> Function() onOpenImages;
  final Future<void> Function() onClose;
  final ValueChanged<bool> onBusyChanged;
  final bool active;
  final BrowserSettings browserSettings;
  final ValueChanged<BrowserSettings> onBrowserSettings;
  final bool workspaceBusy;
  final Map<int, String> images;
  final int? activeImageId;
  final ValueChanged<int>? onSelectImage;
  final VoidCallback? onSettings;
  final Future<void> Function()? onCredentials;
  @override
  State<ReaderHome> createState() => _ReaderHomeState();
}

class _DirectoryLoad {
  bool cancelled = false;
}

class _ReaderHomeState extends State<ReaderHome> {
  final _password = TextEditingController();
  final _desktopFocus = FocusNode();
  Map<String, dynamic>? _image;
  String? _imagePath;
  int? _partition;
  bool _unlocked = false;
  bool _busy = false;
  bool _showPassword = false;
  bool get _showSystem => widget.browserSettings.showSystem;
  bool get _grid => widget.browserSettings.grid;
  FileSort get _sort => widget.browserSettings.sort;
  bool get _descending => widget.browserSettings.descending;
  String _mode = 'password';
  String? _credentialFile;
  bool get _credentialProtectionRequired =>
      widget.platform == TargetPlatform.android ||
      widget.platform == TargetPlatform.iOS ||
      widget.platform == TargetPlatform.windows ||
      widget.platform == TargetPlatform.macOS;
  String get _credentialVerificationHint => switch (widget.platform) {
    TargetPlatform.windows => '每次使用需通过 Windows Hello PIN、指纹或人脸验证。',
    TargetPlatform.macOS => '每次使用需通过 Touch ID 或 Mac 登录密码验证。',
    _ => '每次使用需通过系统人脸、指纹或锁屏密码验证。',
  };
  bool _remember = false;
  bool _vaultAvailable = false;
  bool _savedCredential = false;
  String? _vaultNote;
  final _autoAttempted = <int>{};
  final _manuallyLocked = <int>{};
  String _status = '';
  String? _error;
  String _path = '/';
  DirectoryOrder _directoryOrder = DirectoryOrder();
  late FileOrderSnapshot _ordered = _directoryOrder.snapshot(
    _sort,
    _descending,
  );
  List<Map<String, dynamic>> get _entries => _ordered.entries;
  _DirectoryLoad? _listing;
  bool get _directoryLoading => _listing != null;
  bool _directoryPartial = false;
  bool _hasDirectory = false;
  bool _reloadDirectoryPending = false;
  Completer<void>? _operationDone;
  String get _directorySummary => _directoryPartial
      ? '已加载 ${_entries.length} 项（未完成）'
      : '${_entries.length} 个项目';
  final _shell = GlobalKey<ScaffoldState>();
  bool _drawerOpen = false;
  Map<String, dynamic>? _selected;
  PreviewData? _preview;
  int _previewRevision = 0;
  ThumbnailScope? _thumbnailScope;
  String _sourceRevision = '';
  void _syncThumbnails() =>
      _thumbnailScope?.setActive(widget.active && !_busy && _preview == null);
  void _invalidateThumbnails() {
    _thumbnailScope?.invalidate();
    _thumbnailScope = null;
  }

  @override
  void initState() {
    super.initState();
    if (widget.initialImage != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _open(widget.initialImage!),
      );
    }
  }

  @override
  void didUpdateWidget(covariant ReaderHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncThumbnails();
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _desktopFocus.requestFocus();
      });
    }
    if (oldWidget.browserSettings.sort != _sort ||
        oldWidget.browserSettings.descending != _descending) {
      _ordered = _directoryOrder.snapshot(_sort, _descending);
    }
    if (oldWidget.browserSettings.showSystem != _showSystem && _unlocked) {
      _reloadDirectoryPending = true;
      if (_directoryLoading) _cancelOperation();
      _reloadWhenIdle();
    }
  }

  @override
  void dispose() {
    _listing?.cancelled = true;
    _listing = null;
    _invalidateThumbnails();
    _preview?.dispose();
    _password.clear();
    _password.dispose();
    _desktopFocus.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _partitions =>
      ((_image?['partitions'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
  Map<String, dynamic>? get _currentPartition {
    for (final p in _partitions) {
      if (p['index'] == _partition) return p;
    }
    return null;
  }

  String _leaf(String path) => PlatformStorage.displayName(path);
  String _join(String name) => _path == '/' ? '/$name' : '$_path/$name';
  void _clearFiles() {
    _previewRevision++;
    _invalidateThumbnails();
    _preview?.dispose();
    _unlocked = false;
    _listing?.cancelled = true;
    _listing = null;
    _directoryOrder = DirectoryOrder();
    _ordered = _directoryOrder.snapshot(_sort, _descending);
    _directoryPartial = false;
    _hasDirectory = false;
    _reloadDirectoryPending = false;
    _selected = null;
    _preview = null;
    _path = '/';
  }

  Future<void> _run(String status, Future<void> Function() operation) async {
    if (_busy) return;
    final done = Completer<void>();
    _operationDone = done;
    widget.backend.beginOperation();
    widget.onBusyChanged(true);
    setState(() {
      _busy = true;
      _status = status;
      _error = null;
    });
    _syncThumbnails();
    try {
      await operation();
    } on ReaderFailure catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          if (e.invalidated) {
            _image = null;
            _imagePath = null;
            _partition = null;
            _clearFiles();
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '操作失败，请检查文件和设备连接后重试。');
    } finally {
      if (mounted) {
        widget.onBusyChanged(false);
        setState(() {
          _busy = false;
          _status = '';
        });
        _syncThumbnails();
        _reloadWhenIdle();
      }
      _operationDone = null;
      done.complete();
    }
  }

  void _cancelOperation() {
    _listing?.cancelled = true;
    widget.backend.cancel();
    if (mounted) setState(() => _status = '正在取消…');
  }

  Future<void> _stopListing() async {
    if (!_directoryLoading) return;
    final done = _operationDone;
    _cancelOperation();
    if (done != null) await done.future;
  }

  void _reloadWhenIdle() {
    if (!_reloadDirectoryPending || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _busy || !_unlocked || !_reloadDirectoryPending) return;
      _reloadDirectoryPending = false;
      unawaited(_run('正在读取目录…', () => _load(_path)));
    });
  }

  Future<void> _chooseImage() => widget.onOpenImages();

  Future<void> _open(String path) => _run('正在打开镜像…', () async {
    _autoAttempted.clear();
    _manuallyLocked.clear();
    setState(() {
      _image = null;
      _imagePath = null;
      _partition = null;
      _clearFiles();
      _password.clear();
      _credentialFile = null;
    });
    final image = await widget.backend.request({'op': 'open', 'path': path});
    _sourceRevision =
        image['source_revision'] as String? ??
        '${DateTime.now().microsecondsSinceEpoch}';
    if (!mounted) return;
    setState(() {
      _image = image;
      _imagePath = path;
    });
    widget.onImageOpened?.call(path);
    final supported = _partitions
        .where((p) => p['kind'] == 'Ntfs' || p['kind'] == 'BitLocker')
        .toList();
    if (supported.isNotEmpty) await _activate(supported.first['index'] as int);
  });
  Future<void> _activate(int index) async {
    setState(() {
      _partition = index;
      _clearFiles();
      _credentialFile = null;
      _password.clear();
      _mode = 'password';
      _remember = false;
      _vaultAvailable = false;
      _savedCredential = false;
      _vaultNote = null;
    });
    if (_currentPartition?['kind'] == 'Ntfs') {
      await widget.backend.request({
        'op': 'unlock',
        'partition': index,
        'mode': 'none',
        'cache': widget.cacheSettings.toJson(),
      });
      if (!mounted) return;
      setState(() => _unlocked = true);
      await _load('/');
    } else if (_currentPartition?['kind'] == 'BitLocker') {
      try {
        final status = await widget.backend.request({
          'op': 'vault_status',
          'partition': index,
        });
        if (!mounted) return;
        final protectionMissing =
            _credentialProtectionRequired &&
            status['available'] == true &&
            status['authentication_required'] != true;
        setState(() {
          _vaultAvailable = status['available'] == true && !protectionMissing;
          _savedCredential = status['saved'] == true && !protectionMissing;
          _vaultNote = protectionMissing
              ? '读取组件尚不支持身份验证，请更新完整应用；当前可手动解锁。'
              : status['reason'] as String?;
        });
        if (_savedCredential &&
            !_manuallyLocked.contains(index) &&
            _autoAttempted.add(index)) {
          await _unlockSaved();
        }
      } on ReaderFailure catch (e) {
        if (e.invalidated) rethrow;
        if (mounted) setState(() => _vaultNote = e.message);
      } catch (_) {
        if (mounted) setState(() => _vaultNote = '安全存储暂不可用，请手动解锁。');
      }
    }
  }

  Future<void> _unlockSaved() async {
    try {
      await widget.backend.request({
        'op': 'unlock_saved',
        'partition': _partition,
        'cache': widget.cacheSettings.toJson(),
      });
      if (!mounted) return;
      setState(() {
        _unlocked = true;
        _vaultNote = null;
      });
      await _load('/');
    } on ReaderFailure catch (e) {
      if (e.invalidated) rethrow;
      if (mounted) {
        setState(
          () => _vaultNote = e.code == 'wrong_credential'
              ? '已保存的密码已失效，请重新输入；勾选记住可在成功后更新。'
              : e.message,
        );
      }
    }
  }

  Future<void> _switchPartition(int index) => _run('正在切换分区…', () async {
    _shell.currentState?.closeDrawer();
    _invalidateThumbnails();
    await widget.backend.request({'op': 'lock'});
    if (mounted) await _activate(index);
  });
  Future<void> _unlock() => _run('正在解锁分区…', () async {
    final request = <String, dynamic>{
      'op': 'unlock',
      'partition': _partition,
      'mode': _mode,
      'cache': widget.cacheSettings.toJson(),
      'remember': _remember && _vaultAvailable,
      'label': '${_leaf(_imagePath ?? '')} · 分区 $_partition',
      if (_credentialFile != null)
        'credential_file': _credentialFile
      else
        'secret': _password.text,
    };
    _password.clear();
    try {
      final result = await widget.backend.request(request);
      if (mounted && result['remembered'] == false) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已解锁，但安全存储保存失败，下次仍需输入密码。')),
        );
      }
      if (result['remembered'] == true) _savedCredential = true;
    } finally {
      request.remove('secret');
    }
    if (!mounted) return;
    setState(() => _unlocked = true);
    await _load('/');
  });
  Future<void> _chooseCredential() async {
    try {
      final path = await PlatformStorage.chooseCredential();
      if (path != null && mounted) {
        setState(() {
          _credentialFile = path;
          _password.clear();
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法打开解锁文件，请重试。');
    }
  }

  Future<void> _load(String path) async {
    if (widget.thumbnails != null && _thumbnailScope == null) {
      _thumbnailScope = ThumbnailScope(
        widget.thumbnails!,
        widget.backend,
        jsonEncode([_imagePath, _sourceRevision, _partition]),
        encrypted: _currentPartition?['kind'] == 'BitLocker',
        onInvalidated: (error) {
          if (!mounted) return;
          setState(() {
            _error = error.message;
            _image = null;
            _imagePath = null;
            _partition = null;
            _clearFiles();
          });
        },
      );
      _syncThumbnails();
    }
    final load = _DirectoryLoad();
    _listing = load;
    final showSystem = _showSystem;
    final directory = DirectoryOrder();
    var published = false;
    final sincePublish = Stopwatch()..start();
    if (!_hasDirectory) _directoryPartial = true;
    int? next = 0;
    bool current() => mounted && identical(_listing, load) && !load.cancelled;
    try {
      do {
        if (!current()) return;
        final data = await widget.backend.request({
          'op': 'list',
          'path': path,
          'start': next,
          'limit': 200,
          'show_system': showSystem,
        });
        if (!current()) return;
        final previous = next!;
        final following = data['next_index'] as int?;
        if (following != null && following <= previous) {
          throw ReaderFailure('invalid_pagination', '目录读取未能继续，请刷新重试。');
        }
        directory.add(
          (data['entries'] as List).map(
            (e) => Map<String, dynamic>.unmodifiable(e as Map),
          ),
        );
        next = following;
        final first = !published;
        if (first ||
            next == null ||
            (_entries.isEmpty && directory.length > 0) ||
            sincePublish.elapsedMilliseconds >= 32) {
          setState(() {
            if (first) {
              _path = path;
              _directoryOrder = directory;
              _hasDirectory = true;
              _previewRevision++;
              _preview?.dispose();
              _selected = null;
              _preview = null;
            }
            _ordered = directory.snapshot(_sort, _descending);
            _directoryPartial = next != null;
            _status = '正在读取目录… ${_entries.length} 项';
          });
          published = true;
          sincePublish.reset();
        }
        if (next != null) {
          // Guarantee the first page can paint even for immediately completed
          // backend futures. Later pages yield to input without one frame per page.
          if (first && widget.active) {
            await WidgetsBinding.instance.endOfFrame;
          } else {
            await Future<void>.delayed(Duration.zero);
          }
        }
      } while (next != null);
    } on ReaderFailure catch (error) {
      if (error.invalidated || !load.cancelled) rethrow;
    } finally {
      if (mounted && identical(_listing, load)) {
        setState(() {
          _listing = null;
          if (published) {
            _ordered = directory.snapshot(_sort, _descending);
            _directoryPartial = next != null;
          }
        });
      }
    }
  }

  Map<String, dynamic>? _videoNeighbour(int step) =>
      _ordered.adjacentVideo(_selected?['name'] as String?, step);

  Future<void> _select(
    Map<String, dynamic> entry, {
    bool replaceVideo = false,
  }) async {
    if (_directoryLoading) {
      final path = _path;
      await _stopListing();
      if (!mounted || path != _path || !_entries.contains(entry)) return;
    }
    if (_busy) return;
    if (entry['directory'] == true) {
      await _run('正在读取目录…', () => _load(_join(entry['name'] as String)));
      return;
    }
    final previous = replaceVideo ? _preview : null;
    final revision = ++_previewRevision;
    await _run('正在读取文件…', () async {
      if (previous != null) {
        await previous.media?.suspend();
      } else {
        setState(() {
          _preview?.dispose();
          _selected = entry;
          _preview = null;
        });
      }
      final name = entry['name'] as String;
      final size = entry['size'] as int;
      Uint8List? bytes;
      String? notice;
      PdfPreviewSource? pdf;
      MediaPreviewSource? media;
      if (isVideo(name)) {
        media = await MediaPreviewSource.open(
          widget.backend,
          _join(name),
          bufferSettings: widget.cacheSettings.playback,
        );
        if (!mounted || revision != _previewRevision) {
          media.dispose();
          return;
        }
        if (previous?.media != null) {
          await media.setVolume(previous!.media!.volume);
        }
      }
      if (extension(name) == 'pdf') {
        final reader = await BackendRangeReader.open(
          widget.backend,
          _join(name),
        );
        if (!mounted) {
          await reader.close();
          return;
        }
        pdf = PdfPreviewSource(
          reader,
          onFailure: (error) {
            if (mounted && error.invalidated) {
              setState(() {
                _error = error.message;
                _image = null;
                _imagePath = null;
                _partition = null;
                _clearFiles();
              });
            }
          },
        );
      }
      if (isText(name) || isImage(name)) {
        final maxSize = isText(name) ? 256 * 1024 : 16 * 1024 * 1024;
        if (isImage(name) && size > maxSize) {
          notice = '图片超过 16 MB，请导出查看。';
        } else if (isImage(name)) {
          final reader = await BackendRangeReader.open(
            widget.backend,
            _join(name),
          );
          try {
            bytes = await reader.readAll(
              limit: maxSize,
              check: () {
                if (!mounted || revision != _previewRevision) {
                  throw ReaderFailure('cancelled', '图片预览已关闭。');
                }
              },
            );
          } finally {
            await reader.close();
          }
        } else {
          final output = BytesBuilder(copy: false);
          final target = size < maxSize ? size : maxSize;
          while (output.length < target) {
            final length = (target - output.length).clamp(0, 1024 * 1024);
            final data = await widget.backend.request({
              'op': 'read',
              'path': _join(name),
              'offset': output.length,
              'length': length,
            });
            final chunk = base64Decode(data['bytes'] as String);
            if (chunk.isEmpty) break;
            output.add(chunk);
          }
          bytes = output.takeBytes();
          if (bytes.length < size) {
            notice = '仅预览前 ${formatBytes(bytes.length)}，完整内容可导出。';
          }
        }
      }
      if (!mounted || revision != _previewRevision) {
        bytes?.fillRange(0, bytes.length, 0);
        media?.dispose();
        pdf?.dispose();
        return;
      }
      setState(() {
        _selected = entry;
        _preview = PreviewData(
          name,
          size,
          bytes,
          notice: notice,
          pdf: pdf,
          media: media,
        );
      });
      previous?.dispose();
    });
    // A failed replacement leaves the previous video paused and usable.
    if (mounted && previous != null && identical(_preview, previous)) {
      previous.media?.setVisible(widget.active);
    }
  }

  Future<void> _export() async {
    final entry = _selected;
    if (entry == null || _busy) return;
    String? destination;
    try {
      destination = await PlatformStorage.createExport(entry['name'] as String);
    } catch (_) {
      if (mounted) setState(() => _error = '无法选择导出位置。');
      return;
    }
    if (destination == null || !mounted) return;
    final output = destination;
    await _run('正在导出文件…', () async {
      try {
        await widget.backend.request({
          'op': 'export',
          'path': _join(entry['name'] as String),
          'output': output,
        });
      } catch (_) {
        if (PlatformStorage.isDocument(output)) {
          try {
            await PlatformStorage.removeExport(output);
          } catch (_) {
            throw ReaderFailure('cleanup', '导出未完成，请在所选目录手动删除残留文件。');
          }
        }
        rethrow;
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('文件已导出。')));
      }
    });
  }

  Future<void> _lock() => _run('正在锁定…', () async {
    if (_partition != null) _manuallyLocked.add(_partition!);
    _shell.currentState?.closeDrawer();
    _invalidateThumbnails();
    await widget.backend.request({'op': 'lock'});
    if (mounted) {
      setState(() {
        _clearFiles();
        _password.clear();
        _credentialFile = null;
      });
    }
  });
  Future<void> _close() async {
    _shell.currentState?.closeDrawer();
    await widget.onClose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop:
        !widget.active ||
        _drawerOpen ||
        (!_busy && _preview == null && _path == '/'),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && widget.active) _goBack();
    },
    child: _browser(),
  );

  Widget _welcome() => Center(
    child: SingleChildScrollView(
      padding: EdgeInsets.all(_compact ? 12 : 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: _compact ? 48 : 90,
            height: _compact ? 48 : 90,
            decoration: BoxDecoration(
              color: const Color(0xffe5edff),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(
              Icons.folder_open_rounded,
              size: _compact ? 30 : 44,
              color: const Color(0xff316ee8),
            ),
          ),
          SizedBox(height: _compact ? 10 : 28),
          Text(
            '打开你的虚拟磁盘',
            style: TextStyle(
              fontSize: _compact ? 22 : 28,
              fontWeight: FontWeight.w700,
              color: const Color(0xff172b46),
            ),
          ),
          SizedBox(height: _compact ? 6 : 14),
          Text(
            '选择本机或外置 SSD 上的 VHDX 文件，\n浏览文件，预览内容，按需导出。',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xff64748b), height: 1.9),
          ),
          SizedBox(height: _compact ? 12 : 30),
          FilledButton.icon(
            onPressed: _busy ? null : _chooseImage,
            icon: const Icon(Icons.folder_open),
            label: const Text('选择 VHDX 文件'),
          ),
          SizedBox(height: _compact ? 8 : 22),
          const Text(
            '支持普通卷和 BitLocker 加密卷',
            style: TextStyle(fontSize: 12, color: Color(0xff94a3b8)),
          ),
          if (widget.recents.isNotEmpty) ...[
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: RecentImagesList(
                items: widget.recents.take(5).toList(),
                onOpen: widget.onRecent,
                onRemove: widget.onRemoveRecent,
                onClear: widget.onClearRecents,
              ),
            ),
          ],
        ],
      ),
    ),
  );
  Widget _unlockView() {
    if (_partition == null || _currentPartition?['kind'] == 'Unknown') {
      return const Center(child: Text('此镜像中没有当前支持的 NTFS 或 BitLocker 分区。'));
    }
    if (_currentPartition?['kind'] == 'Ntfs') {
      return Center(
        child: FilledButton(
          onPressed: _busy
              ? null
              : () => _run('正在读取分区…', () => _activate(_partition!)),
          child: const Text('读取分区'),
        ),
      );
    }
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Icon(
                  Icons.lock_person_outlined,
                  size: 48,
                  color: Color(0xff316ee8),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '解锁 BitLocker 分区',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              const Text(
                '输入密码，或使用 48 位恢复密钥访问文件。',
                style: TextStyle(color: Color(0xff64748b), fontSize: 13),
              ),
              const SizedBox(height: 28),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'password', label: Text('密码')),
                  ButtonSegment(value: 'recovery', label: Text('恢复密钥')),
                ],
                selected: {_mode},
                onSelectionChanged: _busy
                    ? null
                    : (v) => setState(() {
                        _mode = v.single;
                        _password.clear();
                        _credentialFile = null;
                      }),
              ),
              const SizedBox(height: 20),
              if (_credentialFile == null)
                TextField(
                  key: const Key('unlock-secret'),
                  controller: _password,
                  enabled: !_busy,
                  obscureText: !_showPassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) {
                    if (!_busy) unawaited(_unlock());
                  },
                  decoration: InputDecoration(
                    labelText: _mode == 'password'
                        ? 'BitLocker 密码'
                        : '48 位恢复密钥',
                    hintText: _mode == 'password' ? '请输入密码' : '六位数字一组，以短横线分隔',
                    suffixIcon: IconButton(
                      tooltip: _showPassword ? '隐藏' : '显示',
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xffdce3ee)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.description_outlined, size: 22),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _leaf(_credentialFile!),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      IconButton(
                        tooltip: '移除文件',
                        onPressed: _busy
                            ? null
                            : () => setState(() => _credentialFile = null),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _busy ? null : _chooseCredential,
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: Text(_mode == 'password' ? '从密码文件读取' : '导入恢复密钥文件'),
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('unlock-button'),
                onPressed: _busy ? null : _unlock,
                icon: const Icon(Icons.lock_open_outlined, size: 18),
                label: const Text('解锁并浏览'),
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                key: const Key('remember-credential'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _remember,
                onChanged: _busy || !_vaultAvailable
                    ? null
                    : (value) => setState(() => _remember = value ?? false),
                title: Text(
                  _credentialProtectionRequired
                      ? '在此设备记住，验证身份后解锁'
                      : '在此设备记住，下次自动解锁',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  !_vaultAvailable
                      ? '此设备的安全存储或卷身份暂不可用。'
                      : _credentialProtectionRequired
                      ? '仅在解锁成功后保存；$_credentialVerificationHint'
                      : '仅在解锁成功后保存到设备安全存储。',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (_savedCredential)
                TextButton(
                  key: const Key('unlock-saved'),
                  onPressed: _busy
                      ? null
                      : () => _run(
                          _credentialProtectionRequired
                              ? '请完成系统身份验证…'
                              : '正在自动解锁…',
                          _unlockSaved,
                        ),
                  child: Text(
                    _credentialProtectionRequired ? '验证身份并解锁' : '使用已保存信息解锁',
                  ),
                ),
              if (_vaultNote != null)
                Text(
                  _vaultNote!,
                  style: const TextStyle(color: Color(0xffa16207)),
                ),
              const Text(
                '未勾选时仅用于当前会话。已保存记录可在顶部钥匙按钮中删除。',
                style: TextStyle(fontSize: 11, color: Color(0xff94a3b8)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _dismissPreview() => setState(() {
    _previewRevision++;
    _preview?.dispose();
    _preview = null;
    _syncThumbnails();
  });

  final _previewKey = GlobalKey();
  bool get _compact => ScreenLayout(context).compact;

  void _goBack() {
    if (_drawerOpen) {
      _shell.currentState?.closeDrawer();
      return;
    }
    if (_preview?.media != null) {
      if (_busy) _cancelOperation();
      _dismissPreview();
    } else if (_busy) {
      _cancelOperation();
    } else if (_preview != null) {
      _dismissPreview();
    } else if (_path != '/') {
      final parts = _path.split('/').where((p) => p.isNotEmpty).toList();
      unawaited(
        _run(
          '正在读取目录…',
          () => _load(
            parts.length <= 1
                ? '/'
                : '/${parts.take(parts.length - 1).join('/')}',
          ),
        ),
      );
    }
  }

  Future<void> _refresh() async {
    if (_directoryLoading) await _stopListing();
    if (mounted && widget.active && _unlocked && !_busy) {
      await _run('正在刷新…', () => _load(_path));
    }
  }

  Widget _browser() => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.f5): () {
        if (_preview == null) unawaited(_refresh());
      },
    },
    child: Focus(
      focusNode: _desktopFocus,
      autofocus: widget.active,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Offstage(
            offstage: _preview != null && _preview?.media == null,
            child: ExcludeFocus(
              excluding: _preview != null,
              child: ExcludeSemantics(
                excluding: _preview != null,
                child: IgnorePointer(
                  ignoring: _preview != null,
                  child: Scaffold(
                    key: _shell,
                    drawer: _diskDrawer(),
                    onDrawerChanged: (open) =>
                        setState(() => _drawerOpen = open),
                    body: SafeArea(
                      child: Column(
                        children: [
                          _toolbar(),
                          if (_busy)
                            const LinearProgressIndicator(minHeight: 2)
                          else
                            const Divider(height: 2, color: Color(0xffe9ecf1)),
                          if (_error != null)
                            MaterialBanner(
                              content: Text(
                                _error!,
                                style: const TextStyle(fontSize: 13),
                              ),
                              backgroundColor: const Color(0xfffff1f2),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _error = null),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          Expanded(
                            child: _image == null
                                ? _welcome()
                                : !_unlocked
                                ? _unlockView()
                                : _fileList(),
                          ),
                          if (!_compact)
                            Container(
                              height: 30,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                              ),
                              decoration: const BoxDecoration(
                                border: Border(
                                  top: BorderSide(color: Color(0xffe9ecf1)),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      _busy
                                          ? _status
                                          : _unlocked
                                          ? _directorySummary
                                          : '就绪',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xff8590a0),
                                      ),
                                    ),
                                  ),
                                  if (_busy)
                                    TextButton(
                                      onPressed: () {
                                        _cancelOperation();
                                      },
                                      child: const Text('取消'),
                                    ),
                                  const Icon(
                                    Icons.shield_outlined,
                                    size: 12,
                                    color: Color(0xff98a1ad),
                                  ),
                                  const SizedBox(width: 5),
                                  const Text(
                                    '只读',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Color(0xff98a1ad),
                                    ),
                                  ),
                                ],
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
          if (_preview != null)
            Positioned.fill(
              child: PreviewScreen(
                key: _previewKey,
                data: _preview!,
                seekSeconds: widget.browserSettings.seekSeconds,
                active: widget.active,
                onExport: _busy ? null : _export,
                onBack: _goBack,
                error: _error,
                busy: _busy,
                onPrevious: _videoNeighbour(-1) == null
                    ? null
                    : () => unawaited(
                        _select(_videoNeighbour(-1)!, replaceVideo: true),
                      ),
                onNext: _videoNeighbour(1) == null
                    ? null
                    : () => unawaited(
                        _select(_videoNeighbour(1)!, replaceVideo: true),
                      ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _diskDrawer() => DiskDrawer(
    images: widget.images,
    activeImageId: widget.activeImageId,
    onSelect: (id) {
      _shell.currentState?.closeDrawer();
      widget.onSelectImage?.call(id);
    },
    onAdd: widget.workspaceBusy ? null : () => _drawerAction('open-image'),
    onSettings: () {
      _shell.currentState?.closeDrawer();
      widget.onSettings?.call();
    },
    recents: widget.recents,
    onRecent: widget.onRecent == null
        ? null
        : (item) {
            _shell.currentState?.closeDrawer();
            widget.onRecent!(item);
          },
    onRemoveRecent: widget.onRemoveRecent,
    onClearRecents: widget.onClearRecents,
    actions: [
      if (_image != null) ...[
        if (_partitions.length > 1)
          _drawerItem(
            'partition',
            '切换分区',
            Icons.storage_outlined,
            enabled: !_busy,
          ),
        _drawerItem('image-info', '镜像信息', Icons.info_outline),
        if (_unlocked)
          _drawerItem('refresh', '刷新', Icons.refresh, enabled: !_busy),
        if (_unlocked && _currentPartition?['kind'] == 'BitLocker')
          _drawerItem('lock', '锁定分区', Icons.lock_outline, enabled: !_busy),
      ],
      if (_imagePath != null || widget.initialImage != null)
        _drawerItem(
          'close-image',
          '关闭镜像',
          Icons.close,
          enabled: !_busy && !widget.workspaceBusy,
        ),
    ],
  );

  Widget _drawerItem(
    String action,
    String label,
    IconData icon, {
    bool enabled = true,
  }) => ListTile(
    key: ValueKey(action),
    leading: Icon(icon),
    title: Text(label),
    enabled: enabled,
    onTap: () => _drawerAction(action),
  );

  void _drawerAction(String action) {
    _shell.currentState?.closeDrawer();
    unawaited(_menuAction(action));
  }

  Widget _title(String? imagePath) => _compact
      ? Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: imagePath == null
                      ? null
                      : () => showDialog<void>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('当前位置'),
                            content: SelectableText(
                              '${_leaf(imagePath)}\n分区 ${_partition ?? '—'}\n$_path',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('关闭'),
                              ),
                            ],
                          ),
                        ),
                  child: Text(
                    imagePath == null
                        ? 'VHDX Reader'
                        : '${_path == '/' ? '根目录' : _leaf(_path)} · ${_leaf(imagePath)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              if (_unlocked && (!_busy || _directoryLoading))
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    _directorySummary,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff8590a0),
                    ),
                  ),
                ),
            ],
          ),
        )
      : Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                imagePath == null ? 'VHDX Reader' : _leaf(imagePath),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (imagePath != null)
                Text(
                  '分区 ${_partition ?? '—'} · ${_path == '/' ? '根目录' : _path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xff88919e),
                  ),
                ),
            ],
          ),
        );

  Widget _toolbar() {
    final title = _title(_imagePath ?? widget.initialImage);
    return SizedBox(
      height: ScreenLayout(context).toolbarHeight,
      child: Row(
        children: [
          IconButton(
            key: const Key('disk-navigation'),
            tooltip: '磁盘与设置',
            onPressed: () => _shell.currentState?.openDrawer(),
            icon: const Icon(Icons.menu),
          ),
          if (_image != null && (_path != '/' || _preview != null))
            IconButton(
              key: const Key('navigate-back'),
              tooltip: _preview != null ? '返回文件列表' : '上一级',
              onPressed: _busy ? null : _goBack,
              icon: const Icon(Icons.arrow_back, size: 20),
            ),
          Expanded(child: title),
          if (_compact && _busy)
            IconButton(
              tooltip: '取消读取',
              onPressed: () {
                _cancelOperation();
              },
              icon: const Icon(Icons.close),
            ),
          IconButton(
            key: const Key('display-menu'),
            tooltip: '展示',
            onPressed: _unlocked ? _showDisplayMenu : null,
            icon: const Icon(Icons.tune, size: 21),
          ),
        ],
      ),
    );
  }

  Future<void> _showDisplayMenu() async {
    final button = context.findRenderObject();
    if (button == null) return;
    final media = MediaQuery.of(context);
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        media.size.width - media.padding.right - 304,
        media.padding.top + ScreenLayout(context).toolbarHeight,
        media.padding.right + 8,
        0,
      ),
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      constraints: BoxConstraints(
        minWidth: 264,
        maxWidth: 304,
        maxHeight: (media.size.height - media.padding.vertical - 64).clamp(
          96.0,
          500.0,
        ),
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _displayChoice('view-grid', '网格', _grid),
                  _displayChoice('view-list', '列表', !_grid),
                ],
              ),
              const Divider(height: 12),
              Row(
                children: [
                  _displayChoice('sort-name', '名称', _sort == FileSort.name),
                  _displayChoice('sort-size', '大小', _sort == FileSort.size),
                ],
              ),
              Row(
                children: [
                  _displayChoice(
                    'sort-modified',
                    '修改日期',
                    _sort == FileSort.modified,
                  ),
                  _displayChoice('sort-type', '类型', _sort == FileSort.type),
                ],
              ),
              const Divider(height: 12),
              Row(
                children: [
                  _displayChoice('order-ascending', '升序', !_descending),
                  _displayChoice('order-descending', '降序', _descending),
                ],
              ),
            ],
          ),
        ),
      ],
    );
    if (result != null && mounted) await _menuAction(result);
  }

  Widget _displayChoice(String value, String label, bool selected) => Expanded(
    child: Builder(
      builder: (menuContext) => Padding(
        padding: const EdgeInsets.all(2),
        child: Semantics(
          selected: selected,
          child: TextButton(
            key: ValueKey(value),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 44),
              backgroundColor: selected
                  ? const Color(0xffedf2ff)
                  : Colors.transparent,
              foregroundColor: selected
                  ? const Color(0xff2563eb)
                  : const Color(0xff475569),
            ),
            onPressed: () => Navigator.of(menuContext).pop(value),
            child: Text(selected ? '✓ $label' : label),
          ),
        ),
      ),
    ),
  );

  Future<void> _menuAction(String action) async {
    switch (action) {
      case 'view-list':
        widget.onBrowserSettings(widget.browserSettings.copyWith(grid: false));
      case 'view-grid':
        widget.onBrowserSettings(widget.browserSettings.copyWith(grid: true));
      case 'sort-name':
        widget.onBrowserSettings(
          widget.browserSettings.copyWith(sort: FileSort.name),
        );
      case 'sort-modified':
        widget.onBrowserSettings(
          widget.browserSettings.copyWith(sort: FileSort.modified),
        );
      case 'sort-size':
        widget.onBrowserSettings(
          widget.browserSettings.copyWith(sort: FileSort.size),
        );
      case 'sort-type':
        widget.onBrowserSettings(
          widget.browserSettings.copyWith(sort: FileSort.type),
        );
      case 'order-ascending':
        widget.onBrowserSettings(
          widget.browserSettings.copyWith(descending: false),
        );
      case 'order-descending':
        widget.onBrowserSettings(
          widget.browserSettings.copyWith(descending: true),
        );
      case 'open-image':
        await widget.onOpenImages();
      case 'show-system':
        widget.onBrowserSettings(
          widget.browserSettings.copyWith(showSystem: !_showSystem),
        );
      case 'credential-manager':
        await widget.onCredentials?.call();
      case 'refresh':
        await _refresh();
      case 'lock':
        await _lock();
      case 'close-image':
        await _close();
      case 'partition':
        final index = await showDialog<int>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('切换分区'),
            content: SizedBox(
              width: 360,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in _partitions)
                    ListTile(
                      enabled: p['kind'] != 'Unknown',
                      leading: Icon(
                        p['index'] == _partition
                            ? Icons.check
                            : Icons.storage_outlined,
                      ),
                      title: Text('分区 ${p['index']}'),
                      subtitle: Text(
                        '${p['kind']} · ${formatBytes(p['length'] as int)}',
                      ),
                      onTap: () => Navigator.pop(context, p['index'] as int),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
            ],
          ),
        );
        if (mounted && index != null && index != _partition) {
          await _switchPartition(index);
        }
      case 'image-info':
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('镜像信息'),
            content: Text(
              '${_leaf(_imagePath!)}\n${formatBytes(_image!['virtual_size'] as int)} · ${_image!['disk_type'] == 'dynamic' ? '动态磁盘' : '固定磁盘'}\n${_partitions.length} 个分区 · 只读',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('完成'),
              ),
            ],
          ),
        );
    }
  }

  Widget _fileList() {
    return FileContents(
      key: ValueKey('$_imagePath-$_partition-$_path'),
      entries: _entries,
      order: _ordered,
      loading: _directoryLoading,
      incomplete: _directoryPartial,
      grid: _grid,
      sort: _sort,
      descending: _descending,
      selected: _selected?['name'] as String?,
      storageKey: '$_imagePath-$_partition-$_path',
      thumbnailScope: _thumbnailScope,
      directory: _path,
      onRefresh: _refresh,
      onOpen: _busy && !_directoryLoading ? null : _select,
    );
  }
}
