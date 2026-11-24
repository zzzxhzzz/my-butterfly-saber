import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'ai_tutor_tab.dart';
import 'mistake_bank_tab.dart';
import 'ocr_cubit.dart';
import 'pdf_crop_tab.dart';
import 'pdf_overview_dialog.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';

class PdfStudyPanel extends StatefulWidget {
  const PdfStudyPanel({super.key});

  @override
  State<PdfStudyPanel> createState() => _PdfStudyPanelState();
}

class _PdfStudyPanelState extends State<PdfStudyPanel> {
  static const _maxThumbCache = 24;

  final TextEditingController _jumpCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();

  String? _selectedSource;
  String? _loadedOutlineSource;
  Future<List<PdfOutlineNode>>? _outlineFuture;
  PdfDocument? _cachedPdfDoc;
  String? _cachedPdfSource;

  final Map<int, ui.Image> _thumbCache = {};
  final Set<int> _pendingThumbs = {};
  final List<int> _thumbLru = [];

  bool _searching = false;
  int _searchProgress = 0;
  int _searchTotal = 0;
  int _searchGeneration = 0;
  List<PdfSearchHit> _searchHits = const [];

  @override
  void dispose() {
    _searchGeneration++;
    _jumpCtrl.dispose();
    _searchCtrl.dispose();
    _clearThumbCache();
    super.dispose();
  }

  void _clearThumbCache({bool deferDispose = false}) {
    final images = _thumbCache.values.toList();
    _thumbCache.clear();
    _pendingThumbs.clear();
    _thumbLru.clear();
    if (images.isEmpty) return;
    if (deferDispose) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final img in images) {
          img.dispose();
        }
      });
    } else {
      for (final img in images) {
        img.dispose();
      }
    }
  }

  PdfSourceSummary? _resolveSummary(List<PdfSourceSummary> summaries) {
    if (summaries.isEmpty) return null;
    for (final summary in summaries) {
      if (summary.source == _selectedSource) return summary;
    }
    return summaries.first;
  }

  void _syncPdfContext(
    DocumentLoadSuccess docState,
    PdfSourceSummary? summary,
  ) {
    final source = summary?.source;
    if (source == null) {
      _loadedOutlineSource = null;
      _outlineFuture = null;
      return;
    }
    if (_loadedOutlineSource != source) {
      _loadedOutlineSource = source;
      _outlineFuture = PdfStudyService.loadOutline(
        docState.assetService,
        docState.data,
        source,
      );
      unawaited(_ensurePdfDoc(docState, source));
    }
  }

  Future<void> _ensurePdfDoc(
    DocumentLoadSuccess docState,
    String source,
  ) async {
    if (_cachedPdfSource == source && _cachedPdfDoc != null) return;
    _clearThumbCache(deferDispose: true);
    _cachedPdfSource = source;
    _cachedPdfDoc = null;
    final loaded = await docState.assetService.getPdfDocument(
      source,
      docState.data,
    );
    if (!mounted || _cachedPdfSource != source) return;
    _cachedPdfDoc = loaded;
    setState(() {});
  }

  void _jumpToPdfPage(PdfSourceSummary summary, int pdfPageIndex) {
    final exact = summary.placements
        .where((p) => p.pdfPageIndex == pdfPageIndex)
        .firstOrNull;
    if (exact != null) {
      PdfStudyService.navigateToPdfPage(context, exact);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('该 PDF 第 ${pdfPageIndex + 1} 页尚未导入当前笔记'),
      ),
    );
  }

  Future<void> _runSearch(
    DocumentLoadSuccess docState,
    PdfSourceSummary summary,
  ) async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;
    final gen = ++_searchGeneration;
    setState(() {
      _searching = true;
      _searchProgress = 0;
      _searchTotal = 0;
      _searchHits = const [];
    });

    final hits = await PdfStudyService.searchPdfText(
      docState.assetService,
      docState.data,
      summary.source,
      query,
      isCancelled: () => !mounted || gen != _searchGeneration,
      ocrPages: maybeOcrCubit(context)?.state.pages,
      onProgress: (current, total) {
        if (!mounted || gen != _searchGeneration) return;
        setState(() {
          _searchProgress = current;
          _searchTotal = total;
        });
      },
    );
    if (!mounted || gen != _searchGeneration) return;
    setState(() {
      _searching = false;
      _searchHits = hits;
    });
  }

  ui.Image? _thumbnailFor(int pdfPageIndex) {
    final cached = _thumbCache[pdfPageIndex];
    if (cached != null) {
      _thumbLru.remove(pdfPageIndex);
      _thumbLru.add(pdfPageIndex);
      return cached;
    }
    _requestThumbnail(pdfPageIndex);
    return null;
  }

  void _requestThumbnail(int pdfPageIndex) {
    final doc = _cachedPdfDoc;
    if (doc == null ||
        _pendingThumbs.contains(pdfPageIndex) ||
        pdfPageIndex < 0 ||
        pdfPageIndex >= doc.pages.length) {
      return;
    }
    _pendingThumbs.add(pdfPageIndex);
    () async {
      try {
        final page = doc.pages[pdfPageIndex];
        final scale = min(1.0, 320 / max(page.width, page.height));
        final w = max(1, (page.width * scale).round());
        final h = max(1, (page.height * scale).round());
        final raster = await page.render(
          width: w,
          height: h,
          fullWidth: w.toDouble(),
          fullHeight: h.toDouble(),
        );
        if (raster == null) return;
        ui.Image? image;
        try {
          image = await raster.createImage();
        } finally {
          raster.dispose();
        }
        if (!mounted || !identical(doc, _cachedPdfDoc)) {
          image.dispose();
          return;
        }
        _thumbCache[pdfPageIndex] = image;
        _thumbLru.remove(pdfPageIndex);
        _thumbLru.add(pdfPageIndex);
        while (_thumbLru.length > _maxThumbCache) {
          final evicted = _thumbLru.removeAt(0);
          _thumbCache.remove(evicted)?.dispose();
        }
        setState(() {});
      } catch (_) {
      } finally {
        _pendingThumbs.remove(pdfPageIndex);
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final panelWidth = min(356.0, screenW * 0.92);

    return SizedBox(
      width: panelWidth,
      child: Card(
        margin: const EdgeInsets.all(8),
        elevation: 8,
        clipBehavior: Clip.antiAlias,
        child: BlocBuilder<StudyModeCubit, StudyModeState>(
          builder: (context, studyState) {
            return BlocBuilder<DocumentBloc, DocumentState>(
              builder: (context, docState) {
                final summaries = docState is DocumentLoadSuccess
                    ? PdfStudyService.indexDocumentPdfs(docState)
                    : const <PdfSourceSummary>[];
                final summary = _resolveSummary(summaries);
                if (docState is DocumentLoadSuccess) {
                  _syncPdfContext(docState, summary);
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(context, summaries, summary),
                    _buildTabBar(context, studyState.activeTab),
                    const Divider(height: 1),
                    Expanded(
                      child: switch (studyState.activeTab) {
                        StudyPanelTab.toc => _buildTocTab(docState, summary),
                        StudyPanelTab.thumbnails =>
                          _buildThumbnailsTab(docState, summary),
                        StudyPanelTab.search =>
                          _buildSearchTab(docState, summary),
                        StudyPanelTab.crop => PdfCropTab(
                          summary: summary,
                          pdfDocument: _cachedPdfDoc,
                        ),
                        StudyPanelTab.aiTutor => const AiTutorTab(),
                        StudyPanelTab.mistakes => const MistakeBankTab(),
                      },
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(
    BuildContext context,
    List<PdfSourceSummary> summaries,
    PdfSourceSummary? summary,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
      child: Row(
        children: [
          const PhosphorIcon(PhosphorIconsLight.bookOpen, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: summaries.length > 1 && summary != null
                ? DropdownButton<String>(
                    value: summary.source,
                    isExpanded: true,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final item in summaries)
                        DropdownMenuItem(
                          value: item.source,
                          child: Text(
                            item.displayName,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedSource = value;
                        _searchHits = const [];
                      });
                    },
                  )
                : Text(
                    summary?.displayName ?? '教材与 AI 学习中心',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextTheme.of(context).titleSmall,
                  ),
          ),
          IconButton(
            tooltip: '关闭学习面板',
            onPressed: () => context.read<StudyModeCubit>().closeStudyPanel(),
            icon: const PhosphorIcon(PhosphorIconsLight.x, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(BuildContext context, StudyPanelTab active) {
    final colorScheme = ColorScheme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          for (final tab in StudyPanelTab.values) ...[
            ChoiceChip(
              label: Text(tab.label),
              selected: active == tab,
              showCheckmark: false,
              selectedColor: colorScheme.primaryContainer,
              onSelected: (_) =>
                  context.read<StudyModeCubit>().openStudyPanel(tab),
            ),
            const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildNoPdfPlaceholder() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          '当前文档尚未导入 PDF。\n可通过工具栏「+ -> 导入」加入教材或试卷 PDF，即可使用目录、页码缩略图与全文搜题。',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _buildTocTab(DocumentState docState, PdfSourceSummary? summary) {
    if (docState is! DocumentLoadSuccess || summary == null) {
      return _buildNoPdfPlaceholder();
    }
    return FutureBuilder<List<PdfOutlineNode>>(
      future: _outlineFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final nodes = snapshot.data ?? const <PdfOutlineNode>[];
        if (nodes.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                '该 PDF 文件内未嵌入书签目录（TOC）。\n可切换到「页码」缩略图或「搜题」标签页快速定位。',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            for (final node in nodes) _buildOutlineNode(summary, node, 0),
          ],
        );
      },
    );
  }

  Widget _buildOutlineNode(
    PdfSourceSummary summary,
    PdfOutlineNode node,
    int depth,
  ) {
    final destPage = node.dest?.pageNumber;
    final pageText = destPage != null ? 'P$destPage' : '';
    if (node.children.isEmpty) {
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.only(left: 14.0 + depth * 14.0, right: 12),
        title: Text(
          node.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: pageText.isEmpty
            ? null
            : Text(pageText, style: TextTheme.of(context).labelSmall),
        onTap: destPage == null
            ? null
            : () => _jumpToPdfPage(summary, destPage - 1),
      );
    }
    return ExpansionTile(
      tilePadding: EdgeInsets.only(left: 14.0 + depth * 14.0, right: 8),
      title: Text(
        node.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextTheme.of(context).bodyMedium,
      ),
      trailing: destPage != null
          ? TextButton(
              onPressed: () => _jumpToPdfPage(summary, destPage - 1),
              child: Text(pageText),
            )
          : null,
      children: [
        for (final child in node.children)
          _buildOutlineNode(summary, child, depth + 1),
      ],
    );
  }

  Widget _buildThumbnailsTab(
    DocumentState docState,
    PdfSourceSummary? summary,
  ) {
    if (docState is! DocumentLoadSuccess || summary == null) {
      return _buildNoPdfPlaceholder();
    }
    final placements = summary.placements;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _jumpCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '页码 (1~${placements.length})',
                    isDense: true,
                    filled: true,
                  ),
                  onSubmitted: (_) => _handleJumpSubmit(placements),
                ),
              ),
              const SizedBox(width: 6),
              FilledButton.tonal(
                onPressed: () => _handleJumpSubmit(placements),
                child: const Text('跳转'),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: '全屏总览网格',
                onPressed: () => unawaited(showPdfOverviewDialog(context)),
                icon: const PhosphorIcon(
                  PhosphorIconsLight.squaresFour,
                  size: 18,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.72,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
            ),
            itemCount: placements.length,
            itemBuilder: (context, index) {
              final placement = placements[index];
              final thumb = _thumbnailFor(placement.pdfPageIndex);
              return Card.outlined(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () =>
                      PdfStudyService.navigateToPdfPage(context, placement),
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          color: Colors.white,
                          width: double.infinity,
                          child: thumb == null
                              ? const Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : RawImage(image: thumb, fit: BoxFit.contain),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '第 ${placement.pdfPageIndex + 1} 页',
                          style: TextTheme.of(context).labelSmall,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _handleJumpSubmit(List<PdfPagePlacement> placements) {
    final target = int.tryParse(_jumpCtrl.text.trim());
    if (target == null || target < 1) return;
    final byPdfPage = placements
        .where((p) => p.pdfPageIndex == target - 1)
        .firstOrNull;
    if (byPdfPage != null) {
      PdfStudyService.navigateToPdfPage(context, byPdfPage);
      return;
    }
    if (target <= placements.length) {
      PdfStudyService.navigateToPdfPage(context, placements[target - 1]);
    }
  }

  Widget _buildSearchTab(DocumentState docState, PdfSourceSummary? summary) {
    if (docState is! DocumentLoadSuccess || summary == null) {
      return _buildNoPdfPlaceholder();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  decoration: const InputDecoration(
                    hintText: '搜索 PDF 内文字 / 定理 / 题号',
                    isDense: true,
                    filled: true,
                  ),
                  onSubmitted: (_) => _runSearch(docState, summary),
                ),
              ),
              const SizedBox(width: 6),
              if (_searching)
                TextButton(
                  onPressed: () {
                    _searchGeneration++;
                    setState(() => _searching = false);
                  },
                  child: const Text('停止'),
                )
              else
                IconButton.filled(
                  tooltip: '搜索',
                  onPressed: () => _runSearch(docState, summary),
                  icon: const PhosphorIcon(
                    PhosphorIconsLight.magnifyingGlass,
                    size: 18,
                  ),
                ),
            ],
          ),
        ),
        if (_searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: _searchTotal > 0 ? _searchProgress / _searchTotal : null,
                ),
                const SizedBox(height: 4),
                Text(
                  '正在检索 $_searchProgress / $_searchTotal 页...',
                  style: TextTheme.of(context).labelSmall,
                ),
              ],
            ),
          ),
        Expanded(
          child: _searchHits.isEmpty && !_searching
              ? Center(
                  child: Text(
                    _searchCtrl.text.trim().isEmpty
                        ? '输入关键词检索教材全文'
                        : '未找到匹配内容（纯扫描版图片 PDF 无内嵌文字）',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _searchHits.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final hit = _searchHits[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '第 ${hit.pdfPageIndex + 1} 页',
                        style: TextTheme.of(context).labelMedium,
                      ),
                      subtitle: Text(
                        hit.snippet,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _jumpToPdfPage(summary, hit.pdfPageIndex),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
