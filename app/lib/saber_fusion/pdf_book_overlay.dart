import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'color_filters.dart';
import 'pdf_canvas_reflow_service.dart';
import 'pdf_overview_dialog.dart';
import 'pdf_reading_models.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';

class PdfBookNavigationBar extends StatelessWidget {
  const PdfBookNavigationBar({super.key});

  String _spreadLabel(
    List<PdfPagePlacement> spread,
    int totalPages,
  ) {
    if (spread.isEmpty) return '';
    if (spread.length == 1) {
      return '第 ${spread.first.pdfPageIndex + 1} / $totalPages 页';
    }
    return '第 ${spread.first.pdfPageIndex + 1}-${spread.last.pdfPageIndex + 1} / $totalPages 页';
  }

  @override
  Widget build(BuildContext context) {
    final studyCubit = maybeStudyModeCubit(context);
    if (studyCubit == null) return const SizedBox.shrink();

    return BlocBuilder<StudyModeCubit, StudyModeState>(
      bloc: studyCubit,
      buildWhen: (prev, curr) =>
          prev.pdfCrop != curr.pdfCrop ||
          prev.studyToolbarMode != curr.studyToolbarMode,
      builder: (context, studyState) {
        final config = studyState.pdfCrop;
        if (config.layoutMode == PdfViewLayoutMode.singlePage) {
          return const SizedBox.shrink();
        }
        return BlocBuilder<DocumentBloc, DocumentState>(
          builder: (context, docState) {
            if (docState is! DocumentLoadSuccess) {
              return const SizedBox.shrink();
            }
            final summaries = PdfStudyService.indexDocumentPdfs(docState);
            if (summaries.isEmpty) return const SizedBox.shrink();
            final summary = summaries.first;
            if (!PdfCanvasReflowService.isSingleCanvasMultiPagePdf(
              docState,
              summary,
            )) {
              return const SizedBox.shrink();
            }

            final spreads = PdfCanvasReflowService.buildSpreads(
              summary.placements,
              config.layoutMode,
            );
            if (spreads.isEmpty) return const SizedBox.shrink();
            final currentPdfIdx = PdfCanvasReflowService.detectCurrentPageIndex(
              context,
              summary,
            );
            final spreadIdx = PdfCanvasReflowService.findSpreadIndexForPdfPage(
              spreads,
              currentPdfIdx,
            );
            final currentSpread = spreads[spreadIdx];

            return SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: studyState.studyToolbarMode ? 76.0 : 12.0,
                  ),
                  child: Card.outlined(
                    elevation: 6,
                    margin: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '上一跨页',
                            visualDensity: VisualDensity.compact,
                            onPressed: spreadIdx > 0
                                ? () => PdfCanvasReflowService.navigateToSpread(
                                    context,
                                    spreads[spreadIdx - 1],
                                    config,
                                  )
                                : null,
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.caretLeft,
                              size: 18,
                            ),
                          ),
                          TextButton(
                            onPressed: () =>
                                unawaited(showPdfOverviewDialog(context)),
                            child: Text(
                              _spreadLabel(
                                currentSpread,
                                summary.placements.length,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '下一跨页',
                            visualDensity: VisualDensity.compact,
                            onPressed: spreadIdx < spreads.length - 1
                                ? () => PdfCanvasReflowService.navigateToSpread(
                                    context,
                                    spreads[spreadIdx + 1],
                                    config,
                                  )
                                : null,
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.caretRight,
                              size: 18,
                            ),
                          ),
                          const SizedBox(
                            height: 20,
                            child: VerticalDivider(width: 8),
                          ),
                          IconButton(
                            tooltip: '居中适配双页',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                PdfCanvasReflowService.navigateToSpread(
                                  context,
                                  currentSpread,
                                  config,
                                ),
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.frameCorners,
                              size: 18,
                            ),
                          ),
                          IconButton(
                            tooltip: '全屏页面总览',
                            visualDensity: VisualDensity.compact,
                            onPressed: () =>
                                unawaited(showPdfOverviewDialog(context)),
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.squaresFour,
                              size: 18,
                            ),
                          ),
                          IconButton(
                            tooltip: '切回单页连续视图',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              final next = config.copyWith(
                                layoutMode: PdfViewLayoutMode.singlePage,
                              );
                              studyCubit.updatePdfCrop(next, persist: true);
                              unawaited(
                                PdfCanvasReflowService.reflowCurrentPage(
                                  context,
                                  summary,
                                  next,
                                ),
                              );
                            },
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.rows,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Interactive book spread / seamless long-document viewer used automatically
/// when a PDF was imported across separate Butterfly pages (`spreadToPages`).
class SplitPageBookReaderOverlay extends StatefulWidget {
  const SplitPageBookReaderOverlay({super.key});

  @override
  State<SplitPageBookReaderOverlay> createState() =>
      _SplitPageBookReaderOverlayState();
}

class _SplitPageBookReaderOverlayState
    extends State<SplitPageBookReaderOverlay> {
  static const int _maxCache = 24;

  PdfDocument? _pdfDoc;
  String? _pdfSource;
  final Map<int, ui.Image> _cache = {};
  final Set<int> _pending = {};
  final List<int> _lru = [];
  int _spreadIdx = 0;

  @override
  void dispose() {
    _clearCache(deferDispose: false);
    super.dispose();
  }

  void _clearCache({bool deferDispose = true}) {
    final imgs = _cache.values.toList();
    _cache.clear();
    _pending.clear();
    _lru.clear();
    if (imgs.isEmpty) return;
    if (deferDispose) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final i in imgs) {
          i.dispose();
        }
      });
    } else {
      for (final i in imgs) {
        i.dispose();
      }
    }
  }

  Future<void> _ensureDoc(
    DocumentLoadSuccess docState,
    String source,
  ) async {
    if (_pdfSource == source) return;
    _clearCache(deferDispose: true);
    _pdfSource = source;
    _pdfDoc = null;
    final loaded = await docState.assetService.getPdfDocument(
      source,
      docState.data,
    );
    if (!mounted || _pdfSource != source) return;
    setState(() => _pdfDoc = loaded);
  }

  ui.Image? _imageFor(int pageIdx) {
    final cached = _cache[pageIdx];
    if (cached != null) {
      _lru.remove(pageIdx);
      _lru.add(pageIdx);
      return cached;
    }
    _requestPage(pageIdx);
    return null;
  }

  void _requestPage(int pageIdx) {
    final doc = _pdfDoc;
    if (doc == null ||
        _pending.contains(pageIdx) ||
        pageIdx < 0 ||
        pageIdx >= doc.pages.length) {
      return;
    }
    _pending.add(pageIdx);
    () async {
      try {
        final page = doc.pages[pageIdx];
        final scale = min(2.0, 1400.0 / max(page.width, page.height));
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
        if (!mounted || !identical(doc, _pdfDoc)) {
          image.dispose();
          return;
        }
        _cache[pageIdx] = image;
        _lru.remove(pageIdx);
        _lru.add(pageIdx);
        while (_lru.length > _maxCache) {
          final evicted = _lru.removeAt(0);
          final old = _cache.remove(evicted);
          if (old != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
        }
        setState(() {});
      } catch (_) {
      } finally {
        _pending.remove(pageIdx);
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final studyCubit = maybeStudyModeCubit(context);
    if (studyCubit == null) return const SizedBox.shrink();

    return BlocBuilder<StudyModeCubit, StudyModeState>(
      bloc: studyCubit,
      buildWhen: (prev, curr) =>
          prev.pdfCrop != curr.pdfCrop || prev.colorMode != curr.colorMode,
      builder: (context, studyState) {
        final config = studyState.pdfCrop;
        if (config.layoutMode == PdfViewLayoutMode.singlePage) {
          return const SizedBox.shrink();
        }

        return BlocBuilder<DocumentBloc, DocumentState>(
          builder: (context, docState) {
            if (docState is! DocumentLoadSuccess) {
              return const SizedBox.shrink();
            }
            final summaries = PdfStudyService.indexDocumentPdfs(docState);
            if (summaries.isEmpty) return const SizedBox.shrink();
            final summary = summaries.first;
            if (PdfCanvasReflowService.isSingleCanvasMultiPagePdf(
              docState,
              summary,
            )) {
              return const SizedBox.shrink();
            }

            unawaited(_ensureDoc(docState, summary.source));
            final spreads = PdfCanvasReflowService.buildSpreads(
              summary.placements,
              config.layoutMode,
            );
            if (spreads.isEmpty) return const SizedBox.shrink();

            final currentByNote = summary.placements
                .where((p) => p.butterflyPageName == docState.pageName)
                .firstOrNull;
            if (currentByNote != null &&
                _spreadIdx >= spreads.length) {
              _spreadIdx = PdfCanvasReflowService.findSpreadIndexForPdfPage(
                spreads,
                currentByNote.pdfPageIndex,
              );
            }
            final safeSpreadIdx = _spreadIdx.clamp(0, spreads.length - 1);
            final spread = spreads[safeSpreadIdx];
            final filter = canvasColorFilterFor(studyState.colorMode);
            final spineGap = config.effectiveBookSpineGap;

            Widget content = Center(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 66, 24, 72),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < spread.length; i++) ...[
                      if (i > 0 && spineGap > 0) SizedBox(width: spineGap),
                      Flexible(
                        child: _buildBookPage(
                          context,
                          placement: spread[i],
                          config: config,
                          isLeft: spread.length > 1 && i == 0,
                          isRight: spread.length > 1 && i == 1,
                          onAnnotate: () {
                            studyCubit.setPdfLayoutMode(
                              PdfViewLayoutMode.singlePage,
                            );
                            PdfStudyService.navigateToPdfPage(
                              context,
                              spread[i],
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
            if (filter != null) {
              content = ColorFiltered(colorFilter: filter, child: content);
            }

            return Container(
              color: ColorScheme.of(context).surfaceDim,
              child: Stack(
                children: [
                  Positioned.fill(child: content),
                  SafeArea(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: studyState.studyToolbarMode ? 76.0 : 12.0,
                        ),
                        child: Card.outlined(
                          elevation: 6,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '上一跨页',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: safeSpreadIdx > 0
                                      ? () => setState(
                                          () => _spreadIdx = safeSpreadIdx - 1,
                                        )
                                      : null,
                                  icon: const PhosphorIcon(
                                    PhosphorIconsLight.caretLeft,
                                    size: 18,
                                  ),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      unawaited(showPdfOverviewDialog(context)),
                                  child: Text(
                                    spread.length == 1
                                        ? '第 ${spread.first.pdfPageIndex + 1} / ${summary.placements.length} 页'
                                        : '第 ${spread.first.pdfPageIndex + 1}-${spread.last.pdfPageIndex + 1} / ${summary.placements.length} 页',
                                  ),
                                ),
                                IconButton(
                                  tooltip: '下一跨页',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: safeSpreadIdx < spreads.length - 1
                                      ? () => setState(
                                          () => _spreadIdx = safeSpreadIdx + 1,
                                        )
                                      : null,
                                  icon: const PhosphorIcon(
                                    PhosphorIconsLight.caretRight,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(
                                  height: 20,
                                  child: VerticalDivider(width: 8),
                                ),
                                IconButton(
                                  tooltip: '页面总览',
                                  visualDensity: VisualDensity.compact,
                                  onPressed: () =>
                                      unawaited(showPdfOverviewDialog(context)),
                                  icon: const PhosphorIcon(
                                    PhosphorIconsLight.squaresFour,
                                    size: 18,
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () {
                                    studyCubit.setPdfLayoutMode(
                                      PdfViewLayoutMode.singlePage,
                                    );
                                    PdfStudyService.navigateToPdfPage(
                                      context,
                                      spread.first,
                                    );
                                  },
                                  icon: const PhosphorIcon(
                                    PhosphorIconsLight.pencilSimpleLine,
                                    size: 16,
                                  ),
                                  label: const Text('切回单页批注'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBookPage(
    BuildContext context, {
    required PdfPagePlacement placement,
    required PdfMarginCropConfig config,
    required bool isLeft,
    required bool isRight,
    required VoidCallback onAnnotate,
  }) {
    final idx = placement.pdfPageIndex;
    final img = _imageFor(idx);
    final l = config.effectiveLeftForPage(idx);
    final r = config.effectiveRightForPage(idx);
    final t = config.top;
    final b = config.bottom;
    final fullAspect =
        placement.bounds.height > 0 && placement.bounds.width > 0
            ? placement.bounds.width / placement.bounds.height
            : 0.707;
    final visAspect =
        fullAspect * ((1.0 - l - r) / (1.0 - t - b)).clamp(0.3, 3.0);

    return AspectRatio(
      aspectRatio: visAspect,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: config.effectiveShowShadow
              ? Border.all(color: const Color(0x22000000))
              : null,
          boxShadow: config.effectiveShowShadow
              ? const [
                  BoxShadow(
                    color: Color(0x28000000),
                    blurRadius: 12,
                    offset: Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (img == null)
              const Center(child: CircularProgressIndicator())
            else
              CustomPaint(
                painter: _BookPagePainter(
                  image: img,
                  left: l,
                  top: t,
                  right: r,
                  bottom: b,
                  showCreaseLeft: isRight && config.effectiveShowShadow,
                  showCreaseRight: isLeft && config.effectiveShowShadow,
                ),
                child: const SizedBox.expand(),
              ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Tooltip(
                message: '切至该页画布进行手写批注',
                child: ActionChip(
                  label: Text('P${idx + 1} 批注'),
                  avatar: const PhosphorIcon(
                    PhosphorIconsLight.pen,
                    size: 14,
                  ),
                  onPressed: onAnnotate,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BookPagePainter extends CustomPainter {
  final ui.Image image;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final bool showCreaseLeft;
  final bool showCreaseRight;

  const _BookPagePainter({
    required this.image,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.showCreaseLeft,
    required this.showCreaseRight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final src = Rect.fromLTRB(
      image.width * left,
      image.height * top,
      image.width * (1.0 - right),
      image.height * (1.0 - bottom),
    );
    final dst = Offset.zero & size;
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );
    final creaseWidth = min(20.0, size.width * 0.045);
    if (showCreaseRight && creaseWidth > 0) {
      final rect = Rect.fromLTWH(
        size.width - creaseWidth,
        0,
        creaseWidth,
        size.height,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            rect.centerLeft,
            rect.centerRight,
            const [Color(0x00000000), Color(0x26000000)],
          ),
      );
    } else if (showCreaseLeft && creaseWidth > 0) {
      final rect = Rect.fromLTWH(0, 0, creaseWidth, size.height);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(
            rect.centerLeft,
            rect.centerRight,
            const [Color(0x26000000), Color(0x00000000)],
          ),
      );
    }
  }

  @override
  bool shouldRepaint(_BookPagePainter oldDelegate) =>
      !identical(image, oldDelegate.image) ||
      left != oldDelegate.left ||
      top != oldDelegate.top ||
      right != oldDelegate.right ||
      bottom != oldDelegate.bottom ||
      showCreaseLeft != oldDelegate.showCreaseLeft ||
      showCreaseRight != oldDelegate.showCreaseRight;
}
