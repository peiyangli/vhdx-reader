import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pdf_preview.dart';
import 'media_preview.dart';
import 'screen_layout.dart';
import 'window_chrome.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String extension(String name) =>
    name.contains('.') ? name.split('.').last.toLowerCase() : '';
bool isText(String name) => [
  'txt',
  'md',
  'log',
  'json',
  'xml',
  'csv',
  'yaml',
  'yml',
  'ini',
  'toml',
  'rs',
  'dart',
  'py',
  'c',
  'h',
  'cpp',
  'js',
  'ts',
  'html',
  'css',
  'srt',
  'vtt',
].contains(extension(name));
bool isImage(String name) =>
    ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'].contains(extension(name));
bool isVideo(String name) => [
  'mp4',
  'mkv',
  'mov',
  'avi',
  'webm',
  'm4v',
  'wmv',
  'flv',
  'ts',
  'mts',
  'm2ts',
  '3gp',
].contains(extension(name));
IconData fileIcon(String name, bool directory) {
  if (directory) return Icons.folder_rounded;
  if (isImage(name)) return Icons.image_outlined;
  if (extension(name) == 'pdf') return Icons.picture_as_pdf_outlined;
  if (isVideo(name)) {
    return Icons.movie_outlined;
  }
  if (['mp3', 'flac', 'wav', 'm4a', 'ogg'].contains(extension(name))) {
    return Icons.audio_file_outlined;
  }
  return Icons.description_outlined;
}

class PreviewData {
  PreviewData(
    this.name,
    this.size,
    this.bytes, {
    this.notice,
    this.pdf,
    this.media,
  });
  final String name;
  final int size;
  final Uint8List? bytes;
  final String? notice;
  final PdfPreviewSource? pdf;
  final MediaPreviewSource? media;
  void dispose() {
    pdf?.dispose();
    media?.dispose();
  }
}

class PreviewPane extends StatefulWidget {
  const PreviewPane({
    super.key,
    required this.data,
    required this.onExport,
    this.active = true,
    this.onBack,
    this.onPrevious,
    this.onNext,
    this.busy = false,
    this.message,
  });
  final PreviewData? data;
  final VoidCallback? onExport;
  final bool active;
  final VoidCallback? onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final bool busy;
  final String? message;
  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> {
  String _encoding = '自动';
  @override
  void didUpdateWidget(covariant PreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) _encoding = '自动';
  }

  String _decode(Uint8List bytes) {
    final bomLe = bytes.length >= 2 && bytes[0] == 255 && bytes[1] == 254;
    final bomBe = bytes.length >= 2 && bytes[0] == 254 && bytes[1] == 255;
    final little = _encoding == 'UTF-16 LE' || (_encoding == '自动' && bomLe);
    final big = _encoding == 'UTF-16 BE' || (_encoding == '自动' && bomBe);
    if (little || big) {
      final start = bomLe || bomBe ? 2 : 0;
      return String.fromCharCodes([
        for (var i = start; i + 1 < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    }
    return utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst(RegExp('^\uFEFF'), '');
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    if (data?.media != null) {
      return MediaPreview(
        key: ObjectKey(data!.media),
        source: data.media!,
        active: widget.active,
        onExit: widget.onBack ?? () {},
        onPrevious: widget.onPrevious,
        onNext: widget.onNext,
        switching: widget.busy,
        message: widget.message,
      );
    }
    final onBackAvailable = widget.onBack != null;
    final compact = ScreenLayout(context).compact;
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: data == null
                        ? '文件预览'
                        : '${data.name} · ${formatBytes(data.size)}',
                    child: Text(
                      data?.name ?? '文件预览',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                if (Theme.of(context).platform == TargetPlatform.windows)
                  const SizedBox(
                    width: 72,
                    height: 40,
                    child: WindowDragArea(),
                  ),
                if (data?.bytes != null && isText(data!.name))
                  PopupMenuButton<String>(
                    tooltip: '文本编码',
                    icon: const Icon(Icons.text_fields, size: 20),
                    initialValue: _encoding,
                    onSelected: (value) => setState(() => _encoding = value),
                    itemBuilder: (_) =>
                        ['自动', 'UTF-8', 'UTF-16 LE', 'UTF-16 BE']
                            .map(
                              (e) => CheckedPopupMenuItem(
                                value: e,
                                checked: e == _encoding,
                                child: Text(e),
                              ),
                            )
                            .toList(),
                  ),
                if (data != null)
                  IconButton(
                    tooltip: '导出文件',
                    onPressed: widget.onExport,
                    icon: const Icon(Icons.download_outlined, size: 20),
                  ),
                if (onBackAvailable)
                  IconButton(
                    key: const Key('navigate-back'),
                    tooltip: '关闭预览',
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.close, size: 20),
                  ),
                if (Theme.of(context).platform == TargetPlatform.windows) const WindowButtons(),
              ],
            ),
          ),
          const Divider(height: 1),
          if (data == null)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.touch_app_outlined,
                      size: 36,
                      color: Color(0xff94a3b8),
                    ),
                    SizedBox(height: 12),
                    Text(
                      '选择文件，查看内容',
                      style: TextStyle(color: Color(0xff64748b)),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            if (data.notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(
                  data.notice!,
                  maxLines: compact ? 1 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xffb45309),
                  ),
                ),
              ),
            if (data.pdf != null)
              Expanded(
                child: PdfPreview(
                  key: ObjectKey(data.pdf),
                  source: data.pdf!,
                  active: widget.active,
                ),
              )
            else if (data.bytes != null && isText(data.name)) ...[
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: SelectableText(
                    _decode(data.bytes!),
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
            ] else if (data.bytes != null && isImage(data.name))
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: InteractiveViewer(
                    minScale: 0.5,
                    maxScale: 6,
                    child: Center(
                      child: Image(
                        image: ResizeImage(
                          MemoryImage(data.bytes!),
                          width: 2048,
                          height: 2048,
                          policy: ResizeImagePolicy.fit,
                        ),
                        fit: BoxFit.contain,
                        errorBuilder: (_, error, stack) =>
                            const Text('无法解码这张图片，请导出后查看。'),
                      ),
                    ),
                  ),
                ),
              )
            else
              const Expanded(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '此格式暂未接入预览。\n可以导出到本机后打开。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xff64748b), height: 1.8),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Occupies the entire workspace; the browser remains mounted underneath.
class PreviewScreen extends StatefulWidget {
  const PreviewScreen({
    super.key,
    required this.data,
    required this.active,
    required this.onBack,
    this.onExport,
    this.error,
    this.busy = false,
    this.onPrevious,
    this.onNext,
  });
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final PreviewData data;
  final bool active;
  final VoidCallback onBack;
  final VoidCallback? onExport;
  final String? error;
  final bool busy;
  @override
  State<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends State<PreviewScreen> {
  void _systemMode(bool full) {
    if (Platform.isAndroid || Platform.isIOS) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          full ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
      if (!full) SystemChrome.setSystemUIOverlayStyle(readerSystemStyle);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.active) _systemMode(true);
  }

  @override
  void didUpdateWidget(covariant PreviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) _systemMode(widget.active);
  }

  @override
  void dispose() {
    if (widget.active) _systemMode(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.data.media != null;
    final pane = PreviewPane(
      data: widget.data,
      active: widget.active,
      onExport: widget.onExport,
      onBack: widget.onBack,
      onPrevious: widget.onPrevious,
      onNext: widget.onNext,
      busy: widget.busy,
      message: widget.error,
    );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: video
          ? SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              systemNavigationBarContrastEnforced: false,
            )
          : readerSystemStyle,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): widget.onBack,
        },
        child: Focus(
          autofocus: true,
          child: Material(
            color: video ? Colors.transparent : Colors.white,
            child: video
                ? pane
                : SafeArea(
                    child: Column(
                      children: [
                        if (widget.busy)
                          const LinearProgressIndicator(minHeight: 2),
                        if (widget.error != null)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              widget.error!,
                              style: const TextStyle(color: Colors.red),
                            ),
                          ),
                        Expanded(child: pane),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
