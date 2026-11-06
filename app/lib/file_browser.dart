import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'preview.dart';
import 'thumbnails.dart';
import 'screen_layout.dart';

enum FileSort { name, size, modified, type }

List<Map<String, dynamic>> sortedFiles(
  List<Map<String, dynamic>> source,
  FileSort sort,
  bool descending,
) => [...source]
  ..sort((a, b) {
    final folders =
        (b['directory'] == true ? 1 : 0) - (a['directory'] == true ? 1 : 0);
    if (folders != 0) return folders;
    var result = 0;
    if (sort == FileSort.modified) {
      final left = a['modified_unix_ms'] as int?;
      final right = b['modified_unix_ms'] as int?;
      // Unknown dates stay at the end in both directions.
      if (left == null && right != null) return 1;
      if (left != null && right == null) return -1;
      if (left != null && right != null) result = left.compareTo(right);
    }
    if (a['directory'] != true) {
      if (sort == FileSort.size) {
        result = (a['size'] as int).compareTo(b['size'] as int);
      } else if (sort == FileSort.type) {
        result = friendlyTypeOrder(
          a['name'] as String,
        ).compareTo(friendlyTypeOrder(b['name'] as String));
      }
    }
    if (result == 0) {
      result = compareFileNames(a['name'] as String, b['name'] as String);
    }
    return descending ? -result : result;
  });

/// Neighbours follow the visible directory's sort order and never wrap.
Map<String, dynamic>? adjacentVideo(
  List<Map<String, dynamic>> entries,
  String? current,
  int step,
  FileSort sort,
  bool descending,
) {
  final videos = sortedFiles(entries, sort, descending)
      .where((e) => e['directory'] != true && isVideo(e['name'] as String))
      .toList();
  final index = videos.indexWhere((e) => e['name'] == current);
  final next = index + step;
  return index < 0 || next < 0 || next >= videos.length ? null : videos[next];
}

String fileType(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1
      ? ''
      : name.substring(dot + 1).toLowerCase();
}

int compareFileNames(String a, String b) {
  final pieces = RegExp(r'\d+|\D+');
  final left = pieces.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final right = pieces.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = left[i];
    final y = right[i];
    final nx = BigInt.tryParse(x);
    final ny = BigInt.tryParse(y);
    final order = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (order != 0) return order;
  }
  final length = left.length.compareTo(right.length);
  return length != 0 ? length : a.compareTo(b);
}

String fileDate(Object? value) {
  if (value is! int) return '—';
  final date = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}/${two(date.month)}/${two(date.day)}  ${two(date.hour)}:${two(date.minute)}';
}

class FileContents extends StatelessWidget {
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
  });
  final List<Map<String, dynamic>> entries;
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _contents(context, constraints),
  );

  Widget _contents(BuildContext context, BoxConstraints constraints) {
    final layout = ScreenLayout(context);
    final inline = constraints.maxWidth >= 600 && layout.textScale < 1.4;
    final compact = layout.compact;
    final files = sortedFiles(entries, sort, descending);
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
                  const Text(
                    '此文件夹为空',
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
