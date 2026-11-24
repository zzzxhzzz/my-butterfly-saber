import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pdf_canvas_reflow_service.dart';
import 'pdf_reading_models.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';
import 'ying_pdf_theme.dart';

Future<void> showPdfOverviewDialog(BuildContext context) async {
  final docBloc = context.read<DocumentBloc>();
  final transformCubit = context.read<TransformCubit>();
  final studyCubit = maybeStudyModeCubit(context);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => MultiBlocProvider(
      providers: [
        BlocProvider<DocumentBloc>.value(value: docBloc),
        BlocProvider<TransformCubit>.value(value: transformCubit),
        if (studyCubit != null)
          BlocProvider<StudyModeCubit>.value(value: studyCubit),
      ],
      child: const PdfOverviewDialog(),
    ),
  );
}

class PdfOverviewDialog extends StatefulWidget {
  const PdfOverviewDialog({super.key});

  @override
  State<PdfOverviewDialog> createState() => _PdfOverviewDialogState();
}

class _PdfOverviewDialogState extends State<PdfOverviewDialog> {
  static const int _maxThumbCache = 72;

  final TextEditingController _jumpCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  String? _selectedSource;
  PdfDocument? _cachedPdfDoc;
  String? _cachedPdfSource;
  final Map<int, ui.Image> _thumbCache = {};
  final Set<int> _pendingThumbs = {};
  final List<int> _thumbLru = [];

  double _tileExtent = 168.0;
  bool _applyCropPreview = true;
  bool _scrolledInitial = false;
  bool _initializedJump = false;

  @override
  void dispose() {
    _jumpCtrl.dispose();
    _scrollController.dispose();
    _clearThumbCache(deferDispose: false);
    super.dispose();
  }

  void _clearThumbCache({bool deferDispose = true}) {
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
    for (final s in summaries) {
      if (s.source == _selectedSource) return s;
    }
    return summaries.first;
  }

  Future<void> _ensurePdfDoc(
    DocumentLoadSuccess docState,
    String source,
  ) async {
    if (_cachedPdfSource == source) return;
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
        final scale = min(1.0, 260.0 / max(page.width, page.height));
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
          final old = _thumbCache.remove(evicted);
          if (old != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
        }
        setState(() {});
      } catch (_) {
      } finally {
        _pendingThumbs.remove(pdfPageIndex);
      }
    }();
  }

  void _jumpToPdfPage(
    PdfSourceSummary summary,
    int targetOneBased,
    PdfMarginCropConfig config,
  ) {
    if (summary.placements.isEmpty) return;
    final clamped = targetOneBased.clamp(1, summary.placements.length);
    final byPdfPage = summary.placements
        .where((p) => p.pdfPageIndex == clamped - 1)
        .firstOrNull;
    final placement = byPdfPage ?? summary.placements[clamped - 1];
    PdfCanvasReflowService.navigateToPageRespectingMode(
      context,
      summary,
      placement.pdfPageIndex,
      config,
    );
    Navigator.of(context).pop();
  }

  void _scrollToInitialItem(int itemIndex, int crossAxisCount) {
    if (_scrolledInitial || itemIndex < 0) return;
    _scrolledInitial = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final row = itemIndex ~/ max(1, crossAxisCount);
      final estimatedRowH = (_tileExtent / 0.72) + 14.0;
      final maxScroll = _scrollController.position.maxScrollExtent;
      final targetOffset = (row * estimatedRowH - 80.0).clamp(0.0, maxScroll);
      _scrollController.jumpTo(targetOffset);
    });
  }

  @override
  Widget build(BuildContext context) {
    final docState = context.watch<DocumentBloc>().state;
    final studyState = maybeStudyModeCubit(context)?.state;
    final pdfCrop = studyState?.pdfCrop ?? const PdfMarginCropConfig();
    final colorScheme = ColorScheme.of(context);

    if (docState is! DocumentLoadSuccess) {
      return Dialog(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('当前文档尚未加载'),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    }

    final summaries = PdfStudyService.indexDocumentPdfs(docState);
    final summary = _resolveSummary(summaries);
    if (summary != null) {
      unawaited(_ensurePdfDoc(docState, summary.source));
    }

    final screenSize = MediaQuery.sizeOf(context);
    final currentPdfIdx = summary != null
        ? PdfCanvasReflowService.detectCurrentPageIndex(context, summary)
        : 0;
    if (!_initializedJump && summary != null) {
      _initializedJump = true;
      _jumpCtrl.text = '${currentPdfIdx + 1}';
    }

    final totalCount = summary != null
        ? summary.placements.length
        : docState.data.getPages(true).length;

    return Dialog(
      insetPadding: EdgeInsets.all(screenSize.width > 720 ? 18 : 6),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: screenSize.width,
        height: screenSize.height,
        child: Column(
          children: [
            _buildTopBar(
              context,
              summaries: summaries,
              summary: summary,
              totalCount: totalCount,
              pdfCrop: pdfCrop,
              docState: docState,
            ),
            const Divider(height: 1),
            Expanded(
              child: Container(
                color: colorScheme.surfaceContainerLow,
                child: summary != null
                    ? _buildPdfGrid(
                        context,
                        summary: summary,
                        currentPdfIdx: currentPdfIdx,
                        pdfCrop: pdfCrop,
                      )
                    : _buildNotePagesGrid(context, docState),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(
    BuildContext context, {
    required List<PdfSourceSummary> summaries,
    required PdfSourceSummary? summary,
    required int totalCount,
    required PdfMarginCropConfig pdfCrop,
    required DocumentLoadSuccess docState,
  }) {
    final studyCubit = maybeStudyModeCubit(context);
    final isSingleCanvas =
        summary != null &&
        PdfCanvasReflowService.isSingleCanvasMultiPagePdf(docState, summary);
    final isTwoPage = pdfCrop.layoutMode != PdfViewLayoutMode.singlePage;

    return Material(
      color: ColorScheme.of(context).surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const PhosphorIcon(PhosphorIconsLight.squaresFour, size: 20),
                const SizedBox(width: 8),
                Text(
                  '页面总览',
                  style: TextTheme.of(context).titleMedium,
                ),
              ],
            ),
            const SizedBox(
              height: 20,
              child: VerticalDivider(width: 12),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('跳转到'),
                const SizedBox(width: 6),
                SizedBox(
                  width: 68,
                  child: TextField(
                    controller: _jumpCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                      filled: true,
                    ),
                    onSubmitted: (raw) {
                      final n = int.tryParse(raw.trim());
                      if (n != null && summary != null) {
                        _jumpToPdfPage(summary, n, pdfCrop);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 6),
                const Text('页'),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: summary == null
                      ? null
                      : () {
                          final n = int.tryParse(_jumpCtrl.text.trim());
                          if (n != null) {
                            _jumpToPdfPage(summary, n, pdfCrop);
                          }
                        },
                  child: const Text('跳转'),
                ),
                const SizedBox(width: 12),
                Text(
                  '共 $totalCount 页',
                  style: TextTheme.of(context).bodyMedium?.copyWith(
                    color: ColorScheme.of(context).onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (summaries.length > 1 && summary != null)
              DropdownButton<String>(
                value: summary.source,
                underline: const SizedBox.shrink(),
                items: [
                  for (final item in summaries)
                    DropdownMenuItem(
                      value: item.source,
                      child: Text(item.displayName),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() {
                    _selectedSource = value;
                    _scrolledInitial = false;
                  });
                },
              ),
            if (studyCubit != null)
              ChoiceChip(
                avatar: const PhosphorIcon(PhosphorIconsLight.columns, size: 16),
                label: const Text('书本双页'),
                selected: isTwoPage,
                showCheckmark: false,
                onSelected: (_) {
                  final nextMode = isTwoPage
                      ? PdfViewLayoutMode.singlePage
                      : PdfViewLayoutMode.twoPageBook;
                  final next = pdfCrop.copyWith(layoutMode: nextMode);
                  studyCubit.updatePdfCrop(next, persist: true);
                  if (isSingleCanvas) {
                    unawaited(
                      PdfCanvasReflowService.reflowCurrentPage(
                        context,
                        summary,
                        next,
                      ),
                    );
                  }
                },
              ),
            if (pdfCrop.hasCrop)
              ChoiceChip(
                avatar: const PhosphorIcon(PhosphorIconsLight.crop, size: 16),
                label: const Text('裁剪预览'),
                selected: _applyCropPreview,
                showCheckmark: false,
                onSelected: (v) => setState(() => _applyCropPreview = v),
              ),
            SegmentedButton<double>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment<double>(value: 145.0, label: Text('小')),
                ButtonSegment<double>(value: 168.0, label: Text('中')),
                ButtonSegment<double>(value: 225.0, label: Text('大')),
              ],
              selected: {_tileExtent},
              onSelectionChanged: (sel) =>
                  setState(() => _tileExtent = sel.first),
            ),
            IconButton(
              tooltip: '关闭总览',
              onPressed: () => Navigator.of(context).pop(),
              icon: const PhosphorIcon(PhosphorIconsLight.x),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPdfGrid(
    BuildContext context, {
    required PdfSourceSummary summary,
    required int currentPdfIdx,
    required PdfMarginCropConfig pdfCrop,
  }) {
    final placements = summary.placements;
    final currentPosInList = placements.indexWhere(
      (p) => p.pdfPageIndex == currentPdfIdx,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = max(1, (constraints.maxWidth / _tileExtent).floor());
        _scrollToInitialItem(currentPosInList, cols);

        return GridView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: _tileExtent,
            childAspectRatio: 0.69,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
          ),
          itemCount: placements.length,
          itemBuilder: (context, index) {
            final placement = placements[index];
            final pageIdx = placement.pdfPageIndex;
            final pageNum = pageIdx + 1;
            final isCurrent = pageIdx == currentPdfIdx;
            final thumb = _thumbnailFor(pageIdx);
            final l = _applyCropPreview ? pdfCrop.effectiveLeftForPage(pageIdx) : 0.0;
            final r = _applyCropPreview ? pdfCrop.effectiveRightForPage(pageIdx) : 0.0;
            final t = _applyCropPreview ? pdfCrop.top : 0.0;
            final b = _applyCropPreview ? pdfCrop.bottom : 0.0;

            final isYing =
                maybeStudyModeCubit(context)?.state.yingPdfStyle == true;
            final highlightColor = isYing
                ? YingPdfPalette.of(context).accentBerry
                : const Color(0xFFD32F2F);
            return Tooltip(
              message: '第 $pageNum 页',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _jumpToPdfPage(summary, index + 1, pdfCrop),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(
                            color: isCurrent
                                ? highlightColor
                                : ColorScheme.of(context).outlineVariant,
                            width: isCurrent ? 2.5 : 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isCurrent
                                  ? highlightColor.withValues(alpha: 0.24)
                                  : const Color(0x1F000000),
                              blurRadius: isCurrent ? 10 : 5,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: thumb == null
                            ? const Center(
                                child: SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : CustomPaint(
                                painter: _CroppedThumbPainter(
                                  image: thumb,
                                  left: l,
                                  top: t,
                                  right: r,
                                  bottom: b,
                                ),
                                child: const SizedBox.expand(),
                              ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$pageNum',
                      textAlign: TextAlign.center,
                      style: TextTheme.of(context).labelMedium?.copyWith(
                        fontWeight:
                            isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent
                            ? (maybeStudyModeCubit(context)
                                        ?.state
                                        .yingPdfStyle ==
                                    true
                                ? YingPdfPalette.of(context).accentBerry
                                : const Color(0xFFD32F2F))
                            : ColorScheme.of(context).onSurface,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildNotePagesGrid(
    BuildContext context,
    DocumentLoadSuccess docState,
  ) {
    final pages = docState.data.getPages(true);
    if (pages.isEmpty) {
      return const Center(
        child: Text('当前文档暂无可预览的页面'),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: _tileExtent,
        childAspectRatio: 0.78,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: pages.length,
      itemBuilder: (context, index) {
        final realName = pages[index];
        final displayName = NoteData.getPageNameFromRealName(realName);
        final label = displayName.isEmpty ? '第 ${index + 1} 页' : displayName;
        final isCurrent = realName == docState.pageName;
        return Tooltip(
          message: label,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () {
              context.read<DocumentBloc>().add(PageChanged(realName));
              Navigator.of(context).pop();
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: ColorScheme.of(context).surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isCurrent
                            ? const Color(0xFFD32F2F)
                            : ColorScheme.of(context).outlineVariant,
                        width: isCurrent ? 2.5 : 1.0,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x1A000000),
                          blurRadius: 6,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PhosphorIcon(
                            PhosphorIconsLight.fileText,
                            size: 32,
                            color: isCurrent
                                ? const Color(0xFFD32F2F)
                                : ColorScheme.of(context).primary,
                          ),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              label,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextTheme.of(context).bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${index + 1}',
                  textAlign: TextAlign.center,
                  style: TextTheme.of(context).labelMedium?.copyWith(
                    color: isCurrent ? const Color(0xFFD32F2F) : null,
                    fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CroppedThumbPainter extends CustomPainter {
  final ui.Image image;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const _CroppedThumbPainter({
    required this.image,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTRB(
      image.width * left,
      image.height * top,
      image.width * (1.0 - right),
      image.height * (1.0 - bottom),
    );
    if (src.width <= 0 || src.height <= 0 || size.isEmpty) return;

    final scale = min(size.width / src.width, size.height / src.height);
    final dstW = src.width * scale;
    final dstH = src.height * scale;
    final dst = Rect.fromLTWH(
      (size.width - dstW) / 2,
      (size.height - dstH) / 2,
      dstW,
      dstH,
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_CroppedThumbPainter oldDelegate) =>
      !identical(image, oldDelegate.image) ||
      left != oldDelegate.left ||
      top != oldDelegate.top ||
      right != oldDelegate.right ||
      bottom != oldDelegate.bottom;
}
