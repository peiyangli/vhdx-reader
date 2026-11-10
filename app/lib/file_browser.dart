import 'dart:ui' show PointerDeviceKind;
import 'dart:math' as math;
import 'file_order.dart';
export 'file_order.dart';
import 'package:flutter/material.dart';
import 'preview.dart';
import 'thumbnails.dart';
import 'screen_layout.dart';

String fileType(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1
      ? ''
      : name.substring(dot + 1).toLowerCase();
}

String fileDate(Object? value) {
  if (value is! int) return '—';
  final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}/${two(date.month)}/${two(date.day)}  ${two(date.hour)}:${two(date.minute)}';
}

class FileContents extends StatefulWidget {
  const FileContents({
    super.key,
    required this.entries,
    required this.grid,
    required this.sort,
    required this.descending,
    this.onRefresh,
    required this.onOpen,
    required this.storageKey,
    this.selected,
    this.thumbnailScope,
    this.directory = '/',
    this.order,
    this.loading = false,
    this.incomplete = false,
  });

  /// Immutable entry snapshot; replace the list when metadata changes.
  final List<Map<String, dynamic>> entries;
  final FileOrderSnapshot? order;
  final bool loading;
  final bool incomplete;
  final bool grid;
  final FileSort sort;
  final bool descending;
  final Future<void> Function()? onRefresh;
  final ValueChanged<Map<String, dynamic>>? onOpen;
  final String storageKey;
  final String? selected;
  final ThumbnailScope? thumbnailScope;
  final String directory;
  Widget _thumbnail(Map<String, dynamic> file, Size size) => FileThumbnail(
    key: ValueKey('thumb-${file['name']}'),
    entry: file,
    scope: thumbnailScope,
    path: directory == '/' ? "/${file['name']}" : "$directory/${file['name']}",
    size: size,
  );

  @override
  State<FileContents> createState() => FileContentsState();

  Widget _contents(
    BuildContext context,
    BoxConstraints constraints,
    FileOrderSnapshot order,
    ScrollController scroll,
  ) {
    final layout = ScreenLayout(context);
    final inline = constraints.maxWidth >= 600 && layout.textScale < 1.4;
    final compact = layout.compact;
    final files = order.entries;
    Widget contents;
    if (files.isEmpty) {
      contents = CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.folder_open_outlined,
                    size: 44,
                    color: Color(0xffb4bdc9),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    loading
                        ? '正在读取目录…'
                        : incomplete
                        ? '目录未读完，请下拉刷新'
                        : '此文件夹为空',
                    style: TextStyle(color: Color(0xff7b8492)),
                  ),
                  if (onRefresh != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '下拉刷新',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xff98a1ad),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    } else if (grid) {
      contents = GridView.builder(
        key: PageStorageKey('$storageKey-grid'),
        controller: scroll,
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? order.indexOf(key.value) : null,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          mainAxisExtent:
              (compact ? 124 : 162) + (layout.textScale - 1).clamp(0, 2) * 40,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: files.length,
        itemBuilder: (context, i) {
          final file = files[i];
          final name = file['name'] as String;
          return _item(
            file,
            Tooltip(
              message: '$name\n${fileDate(file['modified_unix_ms'])}',
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    SizedBox(height: compact ? 0 : 8),
                    _thumbnail(file, Size(128, compact ? 48 : 70)),
                    SizedBox(height: compact ? 6 : 12),
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } else {
      contents = ListView.builder(
        key: PageStorageKey('$storageKey-list'),
        controller: scroll,
        findChildIndexCallback: (key) =>
            key is ValueKey<String> ? order.indexOf(key.value) : null,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        itemExtent: inline ? 48 : 62 + (layout.textScale - 1).clamp(0, 2) * 36,
        itemCount: files.length,
        itemBuilder: (context, i) {
          final file = files[i];
          final name = file['name'] as String;
          final folder = file['directory'] == true;
          return _item(
            file,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _thumbnail(file, const Size(44, 40)),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Tooltip(
                          message: name,
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        if (!inline) const SizedBox(height: 4),
                        if (!inline)
                          Text(
                            '${folder ? '文件夹' : friendlyType(name)} · ${fileDate(file['modified_unix_ms'])}${folder ? '' : ' · ${formatBytes(file['size'] as int)}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xff8a929f),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (inline)
                    Padding(
                      padding: const EdgeInsets.only(left: 16, right: 8),
                      child: Text(
                        '${folder ? '文件夹' : friendlyType(name)} · ${fileDate(file['modified_unix_ms'])}${folder ? '' : ' · ${formatBytes(file['size'] as int)}'}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xff8a929f),
                        ),
                      ),
                    ),
                  if (folder)
                    const Icon(
                      Icons.chevron_right,
                      size: 17,
                      color: Color(0xffa5adb8),
                    ),
                ],
              ),
            ),
          );
        },
      );
    }
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
        },
      ),
      child: RefreshIndicator(
        onRefresh: onRefresh ?? () async {},
        child: contents,
      ),
    );
  }

  Widget _item(Map<String, dynamic> file, Widget child) => Material(
    key: ValueKey(file['name'] as String),
    color: selected == file['name']
        ? const Color(0xffeaf1fc)
        : Colors.transparent,
    borderRadius: BorderRadius.circular(6),
    child: InkWell(
      key: ValueKey('file-${file['name']}'),
      borderRadius: BorderRadius.circular(6),
      onTap: onOpen == null ? null : () => onOpen!(file),
      child: child,
    ),
  );
}

class FileContentsState extends State<FileContents> {
  final _cache = FileOrderCache();
  final _listScroll = ScrollController();
  final _gridScroll = ScrollController();
  FileOrderSnapshot? _lastOrder;
  FileSort? _lastSort;
  bool? _lastDescending;
  bool? _lastGrid;
  String? _lastStorageKey;
  double _stride = 1;
  double _padding = 0;
  int _columns = 1;
  int _anchorRevision = 0;

  /// The same snapshot is reused across selection and layout-only rebuilds.
  FileOrderSnapshot get currentOrder => _lastOrder!;

  @override
  void dispose() {
    _anchorRevision++;
    _listScroll.dispose();
    _gridScroll.dispose();
    super.dispose();
  }

  Widget _build(BuildContext context, BoxConstraints constraints) {
    final order =
        widget.order ??
        _cache.resolve(widget.entries, widget.sort, widget.descending);
    final scroll = widget.grid ? _gridScroll : _listScroll;
    final layout = ScreenLayout(context);
    final inline = constraints.maxWidth >= 600 && layout.textScale < 1.4;
    final columns = widget.grid
        ? math.max(1, ((constraints.maxWidth - 32) / 168).ceil())
        : 1;
    final stride = widget.grid
        ? (layout.compact ? 124.0 : 162.0) +
              (layout.textScale - 1).clamp(0, 2) * 40 +
              8
        : (inline ? 48.0 : 62.0 + (layout.textScale - 1).clamp(0, 2) * 36);
    final padding = widget.grid ? 16.0 : 8.0;
    final old = _lastOrder;
    if (old != null &&
        scroll.hasClients &&
        _lastStorageKey == widget.storageKey &&
        _lastGrid == widget.grid) {
      final sortingChanged =
          _lastSort != widget.sort || _lastDescending != widget.descending;
      if (sortingChanged) {
        _restore(scroll, 0, scroll.offset);
      } else if (!identical(old, order) &&
          old.entries.isNotEmpty &&
          scroll.offset > _padding &&
          columns == _columns &&
          stride == _stride) {
        final row = ((scroll.offset - _padding) / _stride).floor();
        final index = (row * _columns).clamp(0, old.entries.length - 1);
        final next = order.indexOf(old.entries[index]['name'] as String);
        if (next != null) {
          final within = scroll.offset - _padding - row * _stride;
          _restore(
            scroll,
            padding + (next ~/ columns) * stride + within,
            scroll.offset,
          );
        }
      }
    }
    _lastOrder = order;
    _lastSort = widget.sort;
    _lastDescending = widget.descending;
    _lastGrid = widget.grid;
    _lastStorageKey = widget.storageKey;
    _columns = columns;
    _stride = stride;
    _padding = padding;
    return widget._contents(context, constraints, order, scroll);
  }

  void _restore(ScrollController scroll, double target, double original) {
    final revision = ++_anchorRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _anchorRevision || !scroll.hasClients) return;
      // Do not fight a user gesture that moved after this build.
      if ((scroll.offset - original).abs() > 0.5) return;
      final position = scroll.position;
      final offset = target.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((scroll.offset - offset).abs() > 0.5) scroll.jumpTo(offset);
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: _build);
}
