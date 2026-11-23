import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pdf_canvas_reflow_service.dart';
import 'pdf_reading_models.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';

class PdfCropTab extends StatefulWidget {
  final PdfSourceSummary? summary;
  final PdfDocument? pdfDocument;

  const PdfCropTab({
    super.key,
    required this.summary,
    required this.pdfDocument,
  });

  @override
  State<PdfCropTab> createState() => _PdfCropTabState();
}

class _PdfCropTabState extends State<PdfCropTab> {
  PdfDocument? _renderedDoc;
  int? _renderedPageIdx;
  bool _loadingPreview = false;
  ui.Image? _previewImage;

  @override
  void dispose() {
    _disposePreview(defer: false);
    super.dispose();
  }

  void _disposePreview({bool defer = true}) {
    final old = _previewImage;
    _previewImage = null;
    if (old == null) return;
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        old.dispose();
      });
    } else {
      old.dispose();
    }
  }

  void _ensurePreview(int pageIndex) {
    final doc = widget.pdfDocument;
    if (doc == null || pageIndex < 0 || pageIndex >= doc.pages.length) {
      if (_previewImage != null) {
        _disposePreview();
      }
      _renderedDoc = null;
      _renderedPageIdx = null;
      return;
    }
    if (identical(_renderedDoc, doc) &&
        _renderedPageIdx == pageIndex &&
        (_previewImage != null || _loadingPreview)) {
      return;
    }
    _renderedDoc = doc;
    _renderedPageIdx = pageIndex;
    _loadingPreview = true;
    unawaited(_renderPreview(doc, pageIndex));
  }

  Future<void> _renderPreview(PdfDocument doc, int pageIndex) async {
    try {
      final page = doc.pages[pageIndex];
      final scale = min(1.0, 340.0 / max(page.width, page.height));
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
      if (!mounted ||
          !identical(doc, _renderedDoc) ||
          _renderedPageIdx != pageIndex) {
        image.dispose();
        return;
      }
      _disposePreview();
      setState(() {
        _previewImage = image;
        _loadingPreview = false;
      });
    } catch (_) {
    } finally {
      if (mounted && _loadingPreview) {
        setState(() => _loadingPreview = false);
      }
    }
  }

  void _commitConfig(
    BuildContext context,
    PdfSourceSummary summary,
    PdfMarginCropConfig nextConfig, {
    bool reflow = true,
  }) {
    final studyCubit = context.read<StudyModeCubit>();
    studyCubit.updatePdfCrop(
      nextConfig.copyWith(showCropGuides: false),
      persist: true,
    );
    if (reflow) {
      unawaited(
        PdfCanvasReflowService.reflowCurrentPage(
          context,
          summary,
          nextConfig.copyWith(showCropGuides: false),
        ),
      );
    } else {
      unawaited(context.read<DocumentBloc>().bake(reset: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = widget.summary;
    if (summary == null || summary.placements.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '当前文档尚未导入 PDF。\n'
            '导入教材或试卷 PDF 后，即可在「页边距裁剪」中去页眉页脚、移除页间距与阴影，或切换书本双页阅读。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final pageIdx = PdfCanvasReflowService.detectCurrentPageIndex(
      context,
      summary,
    );
    _ensurePreview(pageIdx);
    final docState = context.watch<DocumentBloc>().state;
    final isSingleCanvas =
        docState is DocumentLoadSuccess &&
        PdfCanvasReflowService.isSingleCanvasMultiPagePdf(docState, summary);

    return BlocBuilder<StudyModeCubit, StudyModeState>(
      builder: (context, studyState) {
        final studyCubit = context.read<StudyModeCubit>();
        final config = studyState.pdfCrop;
        final colorScheme = ColorScheme.of(context);
        final pageRatio = (_previewImage != null && _previewImage!.height > 0)
            ? _previewImage!.width / _previewImage!.height
            : 0.707;

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 18),
          children: [
            Card.outlined(
              clipBehavior: Clip.antiAlias,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          '实时裁剪预览 · 第 ${pageIdx + 1} 页',
                          style: TextTheme.of(context).labelMedium,
                        ),
                        const Spacer(),
                        if (config.seamlessLongDoc)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '无缝长文档',
                              style: TextTheme.of(context).labelSmall?.copyWith(
                                color: colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: SizedBox(
                        height: 158,
                        child: AspectRatio(
                          aspectRatio: pageRatio,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(
                                color: colorScheme.outlineVariant,
                              ),
                              boxShadow: config.effectiveShowShadow
                                  ? const [
                                      BoxShadow(
                                        color: Color(0x26000000),
                                        blurRadius: 8,
                                        offset: Offset(0, 2),
                                      ),
                                    ]
                                  : null,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_previewImage != null)
                                  RawImage(
                                    image: _previewImage,
                                    fit: BoxFit.fill,
                                  )
                                else
                                  const Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                CustomPaint(
                                  painter: _CropMaskPainter(
                                    top: config.top,
                                    bottom: config.bottom,
                                    left: config.effectiveLeftForPage(pageIdx),
                                    right: config.effectiveRightForPage(pageIdx),
                                    accentColor: colorScheme.primary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card.outlined(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '阅读版式',
                      style: TextTheme.of(context).titleSmall,
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<PdfViewLayoutMode>(
                      showSelectedIcon: false,
                      segments: [
                        for (final mode in PdfViewLayoutMode.values)
                          ButtonSegment<PdfViewLayoutMode>(
                            value: mode,
                            label: Text(
                              mode.shortLabel,
                              style: TextTheme.of(context).labelSmall,
                            ),
                          ),
                      ],
                      selected: {config.layoutMode},
                      onSelectionChanged: (selection) {
                        final mode = selection.first;
                        final next = config.copyWith(layoutMode: mode);
                        _commitConfig(
                          context,
                          summary,
                          next,
                          reflow: isSingleCanvas,
                        );
                      },
                    ),
                    if (!isSingleCanvas &&
                        config.layoutMode != PdfViewLayoutMode.singlePage)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '当前笔记采用分页导入，将自动弹出双页连读书本视图。',
                          style: TextTheme.of(context).bodySmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Card.outlined(
              child: Column(
                children: [
                  SwitchListTile(
                    value: config.seamlessLongDoc,
                    secondary: const PhosphorIcon(
                      PhosphorIconsLight.arrowsVertical,
                    ),
                    title: const Text('无缝长文档'),
                    subtitle: const Text(
                      '页间距归零、阴影移除，多页连成一张长文档',
                    ),
                    onChanged: (value) {
                      final next = config.copyWith(seamlessLongDoc: value);
                      _commitConfig(
                        context,
                        summary,
                        next,
                        reflow: isSingleCanvas,
                      );
                    },
                  ),
                  if (!config.seamlessLongDoc) ...[
                    const Divider(height: 1),
                    SwitchListTile(
                      value: config.showPageShadow,
                      secondary: const PhosphorIcon(
                        PhosphorIconsLight.bookOpen,
                      ),
                      title: const Text('纸张阴影与书本中缝'),
                      subtitle: const Text('关闭可去掉每页边缘阴影线'),
                      onChanged: (value) {
                        _commitConfig(
                          context,
                          summary,
                          config.copyWith(showPageShadow: value),
                          reflow: false,
                        );
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '页间距：${config.pageGap.round()} px',
                            style: TextTheme.of(context).bodySmall,
                          ),
                          Slider(
                            value: config.pageGap,
                            min: 0,
                            max: 80,
                            divisions: 16,
                            label: '${config.pageGap.round()} px',
                            onChanged: (v) {
                              studyCubit.updatePdfCrop(
                                config.copyWith(pageGap: v),
                                persist: false,
                              );
                            },
                            onChangeEnd: (v) {
                              _commitConfig(
                                context,
                                summary,
                                config.copyWith(pageGap: v),
                                reflow: isSingleCanvas,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Card.outlined(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const PhosphorIcon(PhosphorIconsLight.crop, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '上下左右独立页边距裁剪',
                            style: TextTheme.of(context).titleSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '拖动滑块时主画布实时预览，松手后自动对齐页间距，可用于去掉页眉、页脚与多余白边。',
                      style: TextTheme.of(context).bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildCropSlider(
                      context,
                      label: '上裁剪（去页眉）',
                      value: config.top,
                      onChanged: (v) => config.withClampedCrop(top: v),
                      summary: summary,
                      isSingleCanvas: isSingleCanvas,
                    ),
                    _buildCropSlider(
                      context,
                      label: '下裁剪（去页脚）',
                      value: config.bottom,
                      onChanged: (v) => config.withClampedCrop(bottom: v),
                      summary: summary,
                      isSingleCanvas: isSingleCanvas,
                    ),
                    _buildCropSlider(
                      context,
                      label: '左裁剪',
                      value: config.left,
                      onChanged: (v) => config.withClampedCrop(left: v),
                      summary: summary,
                      isSingleCanvas: isSingleCanvas,
                    ),
                    _buildCropSlider(
                      context,
                      label: '右裁剪',
                      value: config.right,
                      onChanged: (v) => config.withClampedCrop(right: v),
                      summary: summary,
                      isSingleCanvas: isSingleCanvas,
                    ),
                    const Divider(height: 16),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: config.mirrorEvenPages,
                      title: const Text('奇偶页左右镜像'),
                      subtitle: const Text('扫描书籍装订边内宽外窄时开启'),
                      onChanged: (value) {
                        _commitConfig(
                          context,
                          summary,
                          config.copyWith(mirrorEvenPages: value),
                          reflow: isSingleCanvas &&
                              (config.seamlessLongDoc ||
                                  config.layoutMode !=
                                      PdfViewLayoutMode.singlePage),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  avatar: const PhosphorIcon(
                    PhosphorIconsLight.crop,
                    size: 16,
                  ),
                  label: const Text('去页眉页脚'),
                  onPressed: () {
                    final next = config.copyWith(
                      top: 0.08,
                      bottom: 0.08,
                      left: 0.04,
                      right: 0.04,
                    );
                    _commitConfig(
                      context,
                      summary,
                      next,
                      reflow: isSingleCanvas &&
                          (next.seamlessLongDoc ||
                              next.layoutMode != PdfViewLayoutMode.singlePage),
                    );
                  },
                ),
                ActionChip(
                  avatar: const PhosphorIcon(
                    PhosphorIconsLight.columns,
                    size: 16,
                  ),
                  label: const Text('无缝双页'),
                  onPressed: () {
                    final next = config.copyWith(
                      layoutMode: PdfViewLayoutMode.twoPageBook,
                      seamlessLongDoc: true,
                      showPageShadow: false,
                      top: config.hasCrop ? config.top : 0.06,
                      bottom: config.hasCrop ? config.bottom : 0.06,
                      left: config.hasCrop ? config.left : 0.05,
                      right: config.hasCrop ? config.right : 0.05,
                    );
                    _commitConfig(
                      context,
                      summary,
                      next,
                      reflow: isSingleCanvas,
                    );
                  },
                ),
                ActionChip(
                  avatar: const PhosphorIcon(
                    PhosphorIconsLight.arrowCounterClockwise,
                    size: 16,
                  ),
                  label: const Text('一键复位'),
                  onPressed: () {
                    final next = PdfMarginCropConfig(
                      layoutMode: config.layoutMode,
                    );
                    _commitConfig(
                      context,
                      summary,
                      next,
                      reflow: isSingleCanvas,
                    );
                  },
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildCropSlider(
    BuildContext context, {
    required String label,
    required double value,
    required PdfMarginCropConfig Function(double v) onChanged,
    required PdfSourceSummary summary,
    required bool isSingleCanvas,
  }) {
    final pct = (value * 100).round();
    final studyCubit = context.read<StudyModeCubit>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label, style: TextTheme.of(context).bodySmall),
            ),
            Text(
              '$pct%',
              style: TextTheme.of(context).labelSmall?.copyWith(
                color: pct > 0 ? ColorScheme.of(context).primary : null,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(0.0, PdfMarginCropConfig.maxSideCrop),
          min: 0.0,
          max: PdfMarginCropConfig.maxSideCrop,
          divisions: 35,
          label: '$pct%',
          onChangeStart: (_) {
            studyCubit.updatePdfCrop(
              studyCubit.state.pdfCrop.copyWith(showCropGuides: true),
              persist: false,
            );
          },
          onChanged: (v) {
            final next = onChanged(v).copyWith(showCropGuides: true);
            studyCubit.updatePdfCrop(next, persist: false);
          },
          onChangeEnd: (v) {
            final committed = onChanged(v).copyWith(showCropGuides: false);
            _commitConfig(
              context,
              summary,
              committed,
              reflow: isSingleCanvas &&
                  (committed.seamlessLongDoc ||
                      committed.layoutMode != PdfViewLayoutMode.singlePage),
            );
          },
        ),
      ],
    );
  }
}

class _CropMaskPainter extends CustomPainter {
  final double top;
  final double bottom;
  final double left;
  final double right;
  final Color accentColor;

  const _CropMaskPainter({
    required this.top,
    required this.bottom,
    required this.left,
    required this.right,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final keepRect = Rect.fromLTRB(
      size.width * left,
      size.height * top,
      size.width * (1.0 - right),
      size.height * (1.0 - bottom),
    );
    final maskPaint = Paint()..color = const Color(0x55E53935);
    if (keepRect.top > 0) {
      canvas.drawRect(
        Rect.fromLTRB(0, 0, size.width, keepRect.top),
        maskPaint,
      );
    }
    if (keepRect.bottom < size.height) {
      canvas.drawRect(
        Rect.fromLTRB(0, keepRect.bottom, size.width, size.height),
        maskPaint,
      );
    }
    if (keepRect.left > 0) {
      canvas.drawRect(
        Rect.fromLTRB(0, keepRect.top, keepRect.left, keepRect.bottom),
        maskPaint,
      );
    }
    if (keepRect.right < size.width) {
      canvas.drawRect(
        Rect.fromLTRB(
          keepRect.right,
          keepRect.top,
          size.width,
          keepRect.bottom,
        ),
        maskPaint,
      );
    }
    if (top > 0 || bottom > 0 || left > 0 || right > 0) {
      canvas.drawRect(
        keepRect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = accentColor,
      );
    }
  }

  @override
  bool shouldRepaint(_CropMaskPainter oldDelegate) =>
      top != oldDelegate.top ||
      bottom != oldDelegate.bottom ||
      left != oldDelegate.left ||
      right != oldDelegate.right ||
      accentColor != oldDelegate.accentColor;
}
