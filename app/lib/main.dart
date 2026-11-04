import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'platform_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'backend.dart';
import 'preview.dart';
import 'pdf_preview.dart';
import 'range_reader.dart';
import 'media_preview.dart';
import 'credential_manager.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(_Bootstrap(initialImage: args.isEmpty ? null : args.first));
}

ThemeData readerTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff2563eb),
    brightness: Brightness.light,
  ),
  scaffoldBackgroundColor: const Color(0xfff5f7fb),
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
  const _Bootstrap({this.initialImage});
  final String? initialImage;
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
  });
  final ReaderBackend backend;
  final String? initialImage;
  final Future<ReaderBackend> Function()? createBackend;
  final Future<List<String>> Function()? pickImages;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'VHDX Reader',
    debugShowCheckedModeBanner: false,
    theme: readerTheme(),
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: _ReaderWorkspace(
      backend: backend,
      initialImage: initialImage,
      createBackend: createBackend ?? NativeBackend.start,
      pickImages: pickImages,
    ),
  );
}

class _ImageTab {
  _ImageTab(this.id, this.backend, this.path);
  final int id;
  final ReaderBackend backend;
  final String? path;
  bool busy = false;
}

class _ReaderWorkspace extends StatefulWidget {
  const _ReaderWorkspace({
    required this.backend,
    required this.createBackend,
    this.initialImage,
    this.pickImages,
  });
  final ReaderBackend backend;
  final String? initialImage;
  final Future<ReaderBackend> Function() createBackend;
  final Future<List<String>> Function()? pickImages;
  @override
  State<_ReaderWorkspace> createState() => _ReaderWorkspaceState();
}

class _ReaderWorkspaceState extends State<_ReaderWorkspace> {
  late final List<_ImageTab> _tabs = [
    _ImageTab(0, widget.backend, widget.initialImage),
  ];
  int _active = 0;
  int _nextId = 1;
  bool _opening = false;

  String _identity(String path) {
    if (PlatformStorage.isDocument(path)) return path;
    final absolute = File(path).absolute.uri.normalizePath().toFilePath();
    return Platform.isWindows ? absolute.toLowerCase() : absolute;
  }

  Future<void> _openImages() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final paths = widget.pickImages != null
          ? await widget.pickImages!()
          : await PlatformStorage.chooseImages();
      for (final path in paths) {
        if (!mounted) break;
        final existing = _tabs.indexWhere(
          (tab) => tab.path != null && _identity(tab.path!) == _identity(path),
        );
        if (existing >= 0) {
          setState(() => _active = existing);
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
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法打开镜像选择器或创建读取会话，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _closeTab(_ImageTab tab) async {
    if (tab.busy || _opening) return;
    setState(() => tab.busy = true);
    tab.backend.beginOperation();
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
    for (final tab in _tabs) {
      unawaited(tab.backend.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Material(
            color: const Color(0xffe8edf4),
            child: SizedBox(
              height: 48,
              child: Row(
                children: [
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: _tabs.length,
                      itemBuilder: (context, index) {
                        final tab = _tabs[index];
                        final label = tab.path == null
                            ? '开始'
                            : PlatformStorage.displayName(tab.path!);
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
                          child: Material(
                            color: index == _active
                                ? Colors.white
                                : const Color(0xffe8edf4),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextButton.icon(
                                  key: ValueKey('image-tab-${tab.id}'),
                                  onPressed: () =>
                                      setState(() => _active = index),
                                  icon: Icon(
                                    tab.busy
                                        ? Icons.hourglass_top
                                        : Icons.disc_full_outlined,
                                    size: 16,
                                  ),
                                  label: Tooltip(
                                    message: tab.path ?? '开始',
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 210,
                                      ),
                                      child: Text(
                                        label,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                                if (tab.path != null)
                                  IconButton(
                                    key: ValueKey('close-tab-${tab.id}'),
                                    tooltip: '关闭 $label',
                                    onPressed: tab.busy || _opening
                                        ? null
                                        : () => _closeTab(tab),
                                    icon: const Icon(Icons.close, size: 16),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: '添加镜像（可多选）',
                    onPressed: _opening ? null : _openImages,
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    key: const Key('credential-manager'),
                    tooltip: '已保存的解锁信息',
                    onPressed: _opening || _tabs.any((tab) => tab.busy)
                        ? null
                        : () async {
                            final backend = _tabs[_active].backend;
                            backend.beginOperation();
                            await showDialog<void>(
                              context: context,
                              builder: (_) =>
                                  CredentialManager(backend: backend),
                            );
                          },
                    icon: const Icon(Icons.key_outlined),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _active,
              children: [
                for (final tab in _tabs)
                  ReaderHome(
                    key: ValueKey(tab.id),
                    backend: tab.backend,
                    initialImage: tab.path,
                    active: tab == _tabs[_active],
                    onOpenImages: _openImages,
                    onClose: () => _closeTab(tab),
                    onBusyChanged: (busy) {
                      if (mounted && _tabs.contains(tab)) {
                        setState(() => tab.busy = busy);
                      }
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
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
  });
  final ReaderBackend backend;
  final String? initialImage;
  final Future<void> Function() onOpenImages;
  final Future<void> Function() onClose;
  final ValueChanged<bool> onBusyChanged;
  final bool active;
  @override
  State<ReaderHome> createState() => _ReaderHomeState();
}

class _ReaderHomeState extends State<ReaderHome> {
  final _password = TextEditingController();
  final _filter = TextEditingController();
  Map<String, dynamic>? _image;
  String? _imagePath;
  int? _partition;
  bool _unlocked = false;
  bool _busy = false;
  bool _showPassword = false;
  bool _showSystem = false;
  String _mode = 'password';
  String? _credentialFile;
  bool _remember = false;
  bool _vaultAvailable = false;
  bool _savedCredential = false;
  String? _vaultNote;
  final _autoAttempted = <int>{};
  final _manuallyLocked = <int>{};
  String _status = '';
  String? _error;
  String _path = '/';
  List<Map<String, dynamic>> _entries = [];
  int? _nextIndex;
  final _shell = GlobalKey<ScaffoldState>();
  Map<String, dynamic>? _selected;
  PreviewData? _preview;
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
  void dispose() {
    _preview?.dispose();
    _password.clear();
    _password.dispose();
    _filter.dispose();
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
    _preview?.dispose();
    _unlocked = false;
    _entries = [];
    _selected = null;
    _preview = null;
    _nextIndex = null;
    _path = '/';
    _filter.clear();
  }

  Future<void> _run(String status, Future<void> Function() operation) async {
    if (_busy) return;
    widget.backend.beginOperation();
    widget.onBusyChanged(true);
    setState(() {
      _busy = true;
      _status = status;
      _error = null;
    });
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
      }
    }
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
    if (!mounted) return;
    setState(() {
      _image = image;
      _imagePath = path;
    });
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
        setState(() {
          _vaultAvailable = status['available'] == true;
          _savedCredential = status['saved'] == true;
          _vaultNote = status['reason'] as String?;
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
    await widget.backend.request({'op': 'lock'});
    if (mounted) await _activate(index);
  });
  Future<void> _unlock() => _run('正在解锁分区…', () async {
    final request = <String, dynamic>{
      'op': 'unlock',
      'partition': _partition,
      'mode': _mode,
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

  Future<void> _load(String path, {bool append = false}) async {
    final data = await widget.backend.request({
      'op': 'list',
      'path': path,
      'start': append ? _nextIndex : 0,
      'limit': 200,
      'show_system': _showSystem,
    });
    if (!mounted) return;
    final entries = (data['entries'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    setState(() {
      _path = path;
      _entries = append ? [..._entries, ...entries] : entries;
      _nextIndex = data['next_index'] as int?;
      if (!append) {
        _preview?.dispose();
        _selected = null;
        _preview = null;
        _filter.clear();
      }
    });
  }

  Future<void> _select(Map<String, dynamic> entry) async {
    if (entry['directory'] == true) {
      await _run('正在读取目录…', () => _load(_join(entry['name'] as String)));
      return;
    }
    await _run('正在读取文件…', () async {
      setState(() {
        _preview?.dispose();
        _selected = entry;
        _preview = null;
      });
      final name = entry['name'] as String;
      final size = entry['size'] as int;
      Uint8List? bytes;
      String? notice;
      PdfPreviewSource? pdf;
      MediaPreviewSource? media;
      if (isVideo(name)) {
        media = await MediaPreviewSource.open(widget.backend, _join(name));
        if (!mounted) {
          media.dispose();
          return;
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
      if (!mounted) return;
      setState(
        () => _preview = PreviewData(
          name,
          size,
          bytes,
          notice: notice,
          pdf: pdf,
          media: media,
        ),
      );
    });
    if (mounted &&
        widget.active &&
        _preview != null &&
        _preview!.pdf == null &&
        _preview!.media == null &&
        MediaQuery.sizeOf(context).width < 1080) {
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          child: SizedBox(
            width: 620,
            height: 550,
            child: PreviewPane(
              data: _preview,
              onExport: () {
                Navigator.pop(context);
                unawaited(_export());
              },
            ),
          ),
        ),
      );
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
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1080;
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 700 || size.height < 550;
    return Scaffold(
      key: _shell,
      drawer: compact
          ? Drawer(
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    child: SizedBox(
                      height: constraints.maxHeight < 650
                          ? 650
                          : constraints.maxHeight,
                      child: _sidebar(),
                    ),
                  ),
                ),
              ),
            )
          : null,
      body: Row(
        children: [
          if (!compact) SizedBox(width: wide ? 238 : 200, child: _sidebar()),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: compact ? 68 : 84,
                  padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 28),
                  color: Colors.white,
                  child: Row(
                    children: [
                      if (compact)
                        Builder(
                          builder: (context) => IconButton(
                            tooltip: '镜像和分区',
                            icon: const Icon(Icons.menu),
                            onPressed: () => Scaffold.of(context).openDrawer(),
                          ),
                        ),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '文件浏览',
                              style: TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _image == null
                                  ? '从你的虚拟磁盘开始'
                                  : '${formatBytes(_image!['virtual_size'] as int)} · ${_image!['disk_type'] == 'dynamic' ? '动态磁盘' : '固定磁盘'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xff64748b),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _chooseImage,
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('打开镜像'),
                      ),
                    ],
                  ),
                ),
                if (_busy)
                  const LinearProgressIndicator(minHeight: 2)
                else
                  const Divider(height: 2, color: Color(0xffe8edf4)),
                if (_error != null)
                  Container(
                    margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xfffff1f2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 20,
                          color: Color(0xffbe123c),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Color(0xff9f1239)),
                          ),
                        ),
                        IconButton(
                          onPressed: () => setState(() => _error = null),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: _image == null
                      ? _welcome()
                      : !_unlocked
                      ? _unlockView()
                      : (_preview?.pdf != null || _preview?.media != null)
                      ? PreviewPane(
                          data: _preview,
                          active: widget.active,
                          onExport: _busy ? null : _export,
                          onBack: () => setState(() {
                            _preview?.dispose();
                            _preview = null;
                          }),
                        )
                      : Row(
                          children: [
                            Expanded(child: _fileList()),
                            if (wide) ...[
                              const VerticalDivider(
                                width: 1,
                                color: Color(0xffe8edf4),
                              ),
                              SizedBox(
                                width: 350,
                                child: PreviewPane(
                                  data: _preview,
                                  onExport: _busy ? null : _export,
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
                Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xffe8edf4))),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _busy
                            ? Icons.hourglass_top
                            : Icons.check_circle_outline,
                        size: 14,
                        color: const Color(0xff64748b),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _busy
                              ? _status
                              : _unlocked
                              ? '${_entries.length} 个已加载项目'
                              : '就绪',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xff64748b),
                          ),
                        ),
                      ),
                      if (_busy)
                        TextButton(
                          onPressed: () {
                            widget.backend.cancel();
                            setState(() => _status = '正在取消…');
                          },
                          child: const Text('取消'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sidebar() => Container(
    color: const Color(0xff142339),
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.storage_rounded, color: Color(0xff8eb5ff), size: 28),
            SizedBox(width: 10),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'VHDX Reader',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.only(left: 38),
          child: Text(
            '随身磁盘 · 只读浏览',
            style: TextStyle(fontSize: 11, color: Color(0xff94a8c3)),
          ),
        ),
        const SizedBox(height: 38),
        const Text(
          '当前镜像',
          style: TextStyle(
            fontSize: 11,
            color: Color(0xff94a8c3),
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 14),
        if (_image == null)
          const Text(
            '尚未打开镜像',
            style: TextStyle(color: Color(0xffb6c5da), fontSize: 13),
          )
        else ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xff223650),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.disc_full_outlined, color: Color(0xff9fc1ff)),
                const SizedBox(height: 12),
                Text(
                  _leaf(_imagePath!),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_partitions.length} 个分区',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xffa3b6cf),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: ListView(
              children: _partitions
                  .map(
                    (p) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: p['index'] == _partition
                            ? const Color(0xff2c4b72)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: _busy || p['kind'] == 'Unknown'
                              ? null
                              : () => _switchPartition(p['index'] as int),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              children: [
                                Icon(
                                  p['kind'] == 'BitLocker'
                                      ? Icons.lock_outline
                                      : Icons.folder_outlined,
                                  size: 18,
                                  color: const Color(0xffb5cfff),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '分区 ${p['index']}',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                        ),
                                      ),
                                      Text(
                                        '${p['kind']} · ${formatBytes(p['length'] as int)}',
                                        style: const TextStyle(
                                          color: Color(0xffa3b6cf),
                                          fontSize: 10,
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
                  )
                  .toList(),
            ),
          ),
          if (_unlocked && _currentPartition?['kind'] == 'BitLocker')
            TextButton.icon(
              onPressed: _busy ? null : _lock,
              icon: const Icon(Icons.lock_outline, size: 16),
              label: const Text('锁定分区'),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xffc6d6eb),
              ),
            ),
          TextButton.icon(
            onPressed: _busy ? null : _close,
            icon: const Icon(Icons.eject_outlined, size: 16),
            label: const Text('关闭镜像'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xffc6d6eb),
            ),
          ),
        ],
        if (_image == null) const Spacer(),
        const Divider(color: Color(0xff30425a)),
        const SizedBox(height: 12),
        const Row(
          children: [
            Icon(
              Icons.verified_user_outlined,
              color: Color(0xff8da6c5),
              size: 16,
            ),
            SizedBox(width: 8),
            Text(
              '只读访问 · 原文件不变',
              style: TextStyle(color: Color(0xff8da6c5), fontSize: 11),
            ),
          ],
        ),
      ],
    ),
  );
  Widget _welcome() => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              color: const Color(0xffe5edff),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.folder_open_rounded,
              size: 44,
              color: Color(0xff316ee8),
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            '打开你的虚拟磁盘',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Color(0xff172b46),
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '选择本机或外置 SSD 上的 VHDX 文件，\n浏览文件，预览内容，按需导出。',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xff64748b), height: 1.9),
          ),
          const SizedBox(height: 30),
          FilledButton.icon(
            onPressed: _busy ? null : _chooseImage,
            icon: const Icon(Icons.folder_open),
            label: const Text('选择 VHDX 文件'),
          ),
          const SizedBox(height: 22),
          const Text(
            '支持普通卷和 BitLocker 加密卷',
            style: TextStyle(fontSize: 12, color: Color(0xff94a3b8)),
          ),
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
                title: const Text(
                  '在此设备记住，下次自动解锁',
                  style: TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  _vaultAvailable ? '仅在解锁成功后保存到设备安全存储。' : '此设备的安全存储或卷身份暂不可用。',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (_savedCredential)
                TextButton(
                  key: const Key('unlock-saved'),
                  onPressed: _busy ? null : () => _run('正在自动解锁…', _unlockSaved),
                  child: const Text('使用已保存信息解锁'),
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

  Widget _fileList() {
    final query = _filter.text.toLowerCase();
    final entries =
        _entries
            .where((e) => (e['name'] as String).toLowerCase().contains(query))
            .toList()
          ..sort((a, b) {
            final directories =
                (b['directory'] == true ? 1 : 0) -
                (a['directory'] == true ? 1 : 0);
            return directories != 0
                ? directories
                : (a['name'] as String).toLowerCase().compareTo(
                    (b['name'] as String).toLowerCase(),
                  );
          });
    final parts = _path.split('/').where((p) => p.isNotEmpty).toList();
    final content = Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '上一级',
                onPressed: _busy || parts.isEmpty
                    ? null
                    : () => _run(
                        '正在读取目录…',
                        () => _load(
                          parts.length == 1
                              ? '/'
                              : '/${parts.take(parts.length - 1).join('/')}',
                        ),
                      ),
                icon: const Icon(Icons.arrow_back, size: 18),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _run('正在读取目录…', () => _load('/')),
                        child: const Text('根目录'),
                      ),
                      for (var i = 0; i < parts.length; i++) ...[
                        const Icon(
                          Icons.chevron_right,
                          size: 16,
                          color: Color(0xff94a3b8),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  '正在读取目录…',
                                  () =>
                                      _load('/${parts.take(i + 1).join('/')}'),
                                ),
                          child: Text(parts[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _busy
                    ? null
                    : () => _run('正在刷新…', () => _load(_path)),
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _filter,
            enabled: !_busy,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: '筛选已加载文件',
              prefixIcon: Icon(Icons.search, size: 20),
              isDense: true,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Checkbox(
                value: _showSystem,
                visualDensity: VisualDensity.compact,
                onChanged: _busy
                    ? null
                    : (value) {
                        setState(() => _showSystem = value!);
                        unawaited(_run('正在读取目录…', () => _load(_path)));
                      },
              ),
              const Text(
                '显示隐藏和系统文件',
                style: TextStyle(fontSize: 11, color: Color(0xff64748b)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              color: Color(0xffeaf0f8),
              borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: const Row(
              children: [
                Expanded(
                  child: Text(
                    '名称',
                    style: TextStyle(fontSize: 12, color: Color(0xff64748b)),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: Text(
                    '大小',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: Color(0xff64748b)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: const Color(0xffe8edf4)),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(10),
                ),
              ),
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        '没有可显示的文件',
                        style: TextStyle(color: Color(0xff94a3b8)),
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final name = entry['name'] as String;
                        final directory = entry['directory'] as bool;
                        return Material(
                          color: _selected?['name'] == name
                              ? const Color(0xffedf3ff)
                              : Colors.white,
                          child: InkWell(
                            onTap: _busy ? null : () => _select(entry),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 15,
                              ),
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: Color(0xfff1f4f8)),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    fileIcon(name, directory),
                                    size: 22,
                                    color: directory
                                        ? const Color(0xffdca72c)
                                        : const Color(0xff6083b9),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    width: 80,
                                    child: Text(
                                      directory
                                          ? '文件夹'
                                          : formatBytes(entry['size'] as int),
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xff64748b),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (_nextIndex != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run('正在加载更多…', () => _load(_path, append: true)),
                child: const Text('加载更多'),
              ),
            ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxHeight < 380
          ? SingleChildScrollView(child: SizedBox(height: 380, child: content))
          : content,
    );
  }
}
