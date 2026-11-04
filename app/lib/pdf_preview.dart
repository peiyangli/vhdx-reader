import 'dart:async';
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'range_reader.dart';
import 'backend.dart';

class PdfPreviewSource {
  PdfPreviewSource(this.reader, {this.onFailure}) {
    document = PdfDocumentRefCustom(
      fileSize: reader.size,
      read: reader.read,
      sourceName: 'vhdx-pdf-${_nextId++}',
      // Keep file access random even for small PDFs; never create a plaintext file.
      maxSizeToCacheOnMemory: 0,
      useProgressiveLoading: true,
    );
  }
  static int _nextId = 0;
  final BackendRangeReader reader;
  final void Function(ReaderFailure)? onFailure;
  late final PdfDocumentRef document;
  void dispose() {
    unawaited(reader.close());
  }
}

class PdfPreview extends StatefulWidget {
  const PdfPreview({super.key, required this.source, required this.active});
  final PdfPreviewSource source;
  final bool active;
  @override
  State<PdfPreview> createState() => _PdfPreviewState();
}

class _PdfPreviewState extends State<PdfPreview> {
  final _viewer = PdfViewerController();
  final _page = TextEditingController(text: '1');
  int _current = 1;
  int _count = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.source.reader.onError = (error) {
      widget.source.onFailure?.call(error);
      if (mounted) setState(() => _error = error.message);
    };
  }

  @override
  void dispose() {
    widget.source.reader.onError = null;
    _page.dispose();
    super.dispose();
  }

  Future<void> _go(int page) async {
    if (!_viewer.isReady || page < 1 || page > _count) {
      _page.text = '$_current';
      return;
    }
    await _viewer.goToPage(pageNumber: page, anchor: PdfPageAnchor.top);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          children: [
            IconButton(
              tooltip: '上一页',
              onPressed: _current > 1 ? () => _go(_current - 1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            SizedBox(
              width: 60,
              child: TextField(
                key: const Key('pdf-page-input'),
                controller: _page,
                enabled: _count > 0,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.all(9),
                ),
                onSubmitted: (value) => _go(int.tryParse(value) ?? _current),
              ),
            ),
            Text('/ $_count', key: const Key('pdf-page-count')),
            IconButton(
              tooltip: '下一页',
              onPressed: _current < _count ? () => _go(_current + 1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
            const SizedBox(width: 12),
            IconButton(
              tooltip: '缩小 PDF',
              onPressed: _count > 0 ? () => _viewer.zoomDown() : null,
              icon: const Icon(Icons.zoom_out),
            ),
            IconButton(
              tooltip: '放大 PDF',
              onPressed: _count > 0 ? () => _viewer.zoomUp() : null,
              icon: const Icon(Icons.zoom_in),
            ),
            TextButton(
              onPressed: _count > 0
                  ? () => _viewer.goTo(
                      _viewer.calcMatrixForFit(pageNumber: _current),
                    )
                  : null,
              child: const Text('适合页面'),
            ),
          ],
        ),
      ),
      Expanded(
        child: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                ),
              )
            : PdfViewer(
                widget.source.document,
                controller: _viewer,
                params: PdfViewerParams(
                  isVisible: widget.active,
                  backgroundColor: const Color(0xffe8edf4),
                  pageAnchorEnd: PdfPageAnchor.top,
                  sizeDelegateProvider:
                      const PdfViewerSizeDelegateProviderLegacy(
                        useAlternativeFitScaleAsMinScale: true,
                      ),
                  maxImageBytesCachedOnMemory: 32 * 1024 * 1024,
                  onViewerReady: (document, controller) {
                    if (mounted) setState(() => _count = document.pages.length);
                  },
                  onPageChanged: (page) {
                    if (mounted && page != null) {
                      setState(() {
                        _current = page;
                        _page.text = '$page';
                      });
                    }
                  },
                  errorBannerBuilder: (context, error, stack, document) =>
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            '无法打开 PDF。文件可能损坏，或需要单独的 PDF 密码；可导出后查看。',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  linkHandlerParams: PdfLinkHandlerParams(
                    enableAutoLinkDetection: false,
                    onLinkTap: (link) {
                      if (link.dest != null) {
                        unawaited(_viewer.goToDest(link.dest));
                      }
                    },
                  ),
                ),
              ),
      ),
    ],
  );
}
