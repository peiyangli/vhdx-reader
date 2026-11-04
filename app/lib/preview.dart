import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'pdf_preview.dart';
import 'media_preview.dart';

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
  });
  final PreviewData? data;
  final VoidCallback? onExport;
  final bool active;
  final VoidCallback? onBack;
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
    final onBackAvailable = widget.onBack != null;
    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const Icon(
                  Icons.preview_outlined,
                  size: 20,
                  color: Color(0xff64748b),
                ),
                const SizedBox(width: 8),
                const Text(
                  '文件预览',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (onBackAvailable)
                  TextButton.icon(
                    onPressed: widget.onBack,
                    icon: const Icon(Icons.arrow_back, size: 18),
                    label: const Text('返回文件列表'),
                  ),
                if (data != null)
                  IconButton(
                    tooltip: '导出文件',
                    onPressed: widget.onExport,
                    icon: const Icon(Icons.download_outlined),
                  ),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    formatBytes(data.size),
                    style: const TextStyle(color: Color(0xff64748b)),
                  ),
                  if (data.notice != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        data.notice!,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xffb45309),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (data.media != null)
              Expanded(
                child: MediaPreview(
                  key: ObjectKey(data.media),
                  source: data.media!,
                  active: widget.active,
                ),
              )
            else if (data.pdf != null)
              Expanded(
                child: PdfPreview(
                  key: ObjectKey(data.pdf),
                  source: data.pdf!,
                  active: widget.active,
                ),
              )
            else if (data.bytes != null && isText(data.name)) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: DropdownButton<String>(
                  value: _encoding,
                  isExpanded: true,
                  items: ['自动', 'UTF-8', 'UTF-16 LE', 'UTF-16 BE']
                      .map(
                        (e) => DropdownMenuItem(
                          value: e,
                          child: Text(e, style: const TextStyle(fontSize: 12)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => _encoding = v!),
                ),
              ),
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
