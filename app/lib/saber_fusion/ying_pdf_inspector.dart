import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'ai_tutor_tab.dart';
import 'ocr_cubit.dart';
import 'ocr_models.dart';
import 'pdf_canvas_reflow_service.dart';
import 'pdf_reading_models.dart';
import 'pdf_study_panel.dart';
import 'pdf_study_service.dart';
import 'png_export_service.dart';
import 'study_state.dart';
import 'ying_pdf_theme.dart';

class YingPdfInspectorPanel extends StatefulWidget {
  const YingPdfInspectorPanel({super.key});

  @override
  State<YingPdfInspectorPanel> createState() => _YingPdfInspectorPanelState();
}

class _YingPdfInspectorPanelState extends State<YingPdfInspectorPanel> {
  bool _docInfoExpanded = false;
  bool _cropExpanded = true;
  bool _ocrExpanded = true;
  bool _exportExpanded = true;

  PdfDocument? _pdfDoc;
  String? _loadedPdfSource;
  PdfDocument? _thumbPdfDoc;
  int? _thumbPageIdx;
  bool _loadingThumb = false;
  ui.Image? _thumbImage;

  bool _exporting = false;
  int _exportDone = 0;
  int _exportTotal = 0;

  @override
  void dispose() {
    _disposeThumb(defer: false);
    super.dispose();
  }

  void _disposeThumb({bool defer = true}) {
    final old = _thumbImage;
    _thumbImage = null;
    if (old == null) return;
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    } else {
      old.dispose();
    }
  }

  void _ensurePdfDocument(DocumentLoadSuccess docState, PdfSourceSummary? summary) {
    final source = summary?.source;
    if (source == null) {
      _loadedPdfSource = null;
      _pdfDoc = null;
      return;
    }
    if (_loadedPdfSource == source && _pdfDoc != null) return;
    _loadedPdfSource = source;
    unawaited(
      docState.assetService.getPdfDocument(source, docState.data).then((pdf) {
        if (!mounted || _loadedPdfSource != source) return;
        setState(() => _pdfDoc = pdf);
      }),
    );
  }

  void _ensureThumb(int pageIndex) {
    final pdf = _pdfDoc;
    if (pdf == null || pageIndex < 0 || pageIndex >= pdf.pages.length) return;
    if (identical(_thumbPdfDoc, pdf) &&
        _thumbPageIdx == pageIndex &&
        (_thumbImage != null || _loadingThumb)) {
      return;
    }
    _thumbPdfDoc = pdf;
    _thumbPageIdx = pageIndex;
    _loadingThumb = true;
    unawaited(_renderThumb(pdf, pageIndex));
  }

  Future<void> _renderThumb(PdfDocument pdf, int pageIndex) async {
    try {
      final page = pdf.pages[pageIndex];
      final scale = math.min(1.0, 220.0 / math.max(page.width, page.height));
      final w = math.max(1, (page.width * scale).round());
      final h = math.max(1, (page.height * scale).round());
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
          !identical(pdf, _thumbPdfDoc) ||
          _thumbPageIdx != pageIndex) {
        image.dispose();
        return;
      }
      _disposeThumb();
      setState(() {
        _thumbImage = image;
        _loadingThumb = false;
      });
    } catch (_) {
    } finally {
      if (mounted && _loadingThumb) {
        setState(() => _loadingThumb = false);
      }
    }
  }

  void _commitCrop(
    BuildContext context,
    PdfSourceSummary? summary,
    PdfMarginCropConfig nextConfig, {
    bool reflow = true,
  }) {
    final studyCubit = context.read<StudyModeCubit>();
    final clean = nextConfig.copyWith(showCropGuides: false);
    studyCubit.updatePdfCrop(clean, persist: true);
    if (summary == null) return;
    if (reflow) {
      unawaited(PdfCanvasReflowService.reflowCurrentPage(context, summary, clean));
    } else {
      unawaited(context.read<DocumentBloc>().bake(reset: true));
    }
  }

  Future<void> _exportCurrent(
    BuildContext context,
    String title,
    int pageIdx,
    PdfMarginCropConfig crop,
  ) async {
    final pdf = _pdfDoc;
    if (pdf == null || _exporting) return;
    setState(() {
      _exporting = true;
      _exportDone = 0;
      _exportTotal = 1;
    });
    try {
      final ok = await PngExportService.exportCurrentPagePng(
        context,
        documentTitle: title,
        pdf: pdf,
        pageIndex: pageIdx,
        crop: crop,
      );
      if (ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出第 ${pageIdx + 1} 页裁剪 PNG（144 DPI）')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出 PNG 失败：$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  Future<void> _exportAll(
    BuildContext context,
    String title,
    PdfMarginCropConfig crop,
  ) async {
    final pdf = _pdfDoc;
    if (pdf == null || _exporting) return;
    setState(() {
      _exporting = true;
      _exportDone = 0;
      _exportTotal = pdf.pages.length;
    });
    try {
      final outPath = await PngExportService.exportAllPagesPng(
        context,
        documentTitle: title,
        pdf: pdf,
        crop: crop,
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _exportDone = done;
              _exportTotal = total;
            });
          }
        },
      );
      if (outPath != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              outPath == 'zip'
                  ? '已导出全部 ${pdf.pages.length} 页 PNG 压缩包'
                  : '已导出全部 ${pdf.pages.length} 页 PNG 到 $outPath',
            ),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('批量导出 PNG 失败：$e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _exporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = YingPdfPalette.of(context);
    final studyCubit = maybeStudyModeCubit(context);
    final ocrCubit = maybeOcrCubit(context);
    if (studyCubit == null) return const SizedBox.shrink();

    return Container(
      width: 308,
      decoration: BoxDecoration(
        color: palette.inspectorSurface,
        border: Border(
          left: BorderSide(color: palette.borderSubtle, width: 1),
        ),
      ),
      child: BlocBuilder<StudyModeCubit, StudyModeState>(
        bloc: studyCubit,
        builder: (context, studyState) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: palette.pillSurface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _ModeTabButton(
                          palette: palette,
                          label: '检查器',
                          selected: !studyState.studyPanelOpen,
                          onTap: studyCubit.closeStudyPanel,
                        ),
                      ),
                      Expanded(
                        child: _ModeTabButton(
                          palette: palette,
                          label: '目录 · AI · 错题',
                          selected: studyState.studyPanelOpen,
                          onTap: () => studyCubit.openStudyPanel(
                            studyState.activeTab,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (studyState.studyPanelOpen)
                const Expanded(child: PdfStudyPanel())
              else
                Expanded(
                  child: BlocBuilder<DocumentBloc, DocumentState>(
                    builder: (context, docState) {
                      final loaded = docState is DocumentLoadSuccess
                          ? docState
                          : null;
                      final summaries = loaded != null
                          ? PdfStudyService.indexDocumentPdfs(loaded)
                          : const <PdfSourceSummary>[];
                      final summary = summaries.firstOrNull;
                      if (loaded != null) {
                        _ensurePdfDocument(loaded, summary);
                      }
                      final pageIdx = (summary != null && summary.placements.isNotEmpty)
                          ? PdfCanvasReflowService.detectCurrentPageIndex(
                              context,
                              summary,
                            )
                          : 0;
                      _ensureThumb(pageIdx);
                      final config = studyState.pdfCrop;
                      final currentPdfPage =
                          (_pdfDoc != null &&
                              pageIdx >= 0 &&
                              pageIdx < _pdfDoc!.pages.length)
                          ? _pdfDoc!.pages[pageIdx]
                          : null;
                      final paperBadge = PngExportService.detectPaperLabel(
                        currentPdfPage,
                      );
                      final docTitle =
                          (summary != null &&
                              summary.displayName.trim().isNotEmpty)
                          ? summary.displayName.trim()
                          : (loaded?.metadata.name.trim().isNotEmpty == true
                                ? loaded!.metadata.name.trim()
                                : '未加载 PDF');

                      return ListView(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 16),
                        children: [
                          _AccordionCard(
                            palette: palette,
                            icon: PhosphorIconsLight.info,
                            title: '文档信息',
                            trailingText: paperBadge,
                            expanded: _docInfoExpanded,
                            onToggle: () => setState(
                              () => _docInfoExpanded = !_docInfoExpanded,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '文件：$docTitle',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: palette.inkPrimary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  currentPdfPage == null
                                      ? '页数：${summary?.placements.length ?? 0} 页'
                                      : '尺寸：${currentPdfPage.width.round()}×${currentPdfPage.height.round()} pt · 共 ${summary?.placements.length ?? 0} 页',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: palette.inkSecondary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final m in PdfViewLayoutMode.values)
                                      ChoiceChip(
                                        label: Text(
                                          m.label,
                                          style: const TextStyle(fontSize: 11),
                                        ),
                                        selected: config.layoutMode == m,
                                        onSelected: (_) {
                                          final next = config.copyWith(
                                            layoutMode: m,
                                          );
                                          _commitCrop(context, summary, next);
                                        },
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          _AccordionCard(
                            palette: palette,
                            icon: PhosphorIconsLight.crop,
                            title: '页边距裁剪',
                            trailingAction: GestureDetector(
                              onTap: () {
                                final reset = PdfMarginCropConfig(
                                  layoutMode: config.layoutMode,
                                );
                                _commitCrop(context, summary, reset);
                              },
                              child: Text(
                                '重置',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: palette.inkMuted,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            expanded: _cropExpanded,
                            onToggle: () =>
                                setState(() => _cropExpanded = !_cropExpanded),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: palette.cardSurface,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: palette.borderSubtle,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 46,
                                        height: 62,
                                        child: Container(
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius: BorderRadius.circular(3),
                                            border: Border.all(
                                              color: config.hasCrop
                                                  ? palette.accentBerry
                                                  : palette.borderStrong,
                                            ),
                                          ),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              if (_thumbImage != null)
                                                RawImage(
                                                  image: _thumbImage,
                                                  fit: BoxFit.fill,
                                                ),
                                              CustomPaint(
                                                painter: _MiniCropMaskPainter(
                                                  top: config.top,
                                                  right: config
                                                      .effectiveRightForPage(
                                                        pageIdx,
                                                      ),
                                                  bottom: config.bottom,
                                                  left: config
                                                      .effectiveLeftForPage(
                                                        pageIdx,
                                                      ),
                                                  accentColor:
                                                      palette.accentBerry,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              config.hasCrop
                                                  ? '实时预览中'
                                                  : '实时预览',
                                              style: TextStyle(
                                                color: palette.inkSecondary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '松手应用裁剪并自动重排',
                                              style: TextStyle(
                                                color: palette.inkMuted,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                _CropSideSlider(
                                  palette: palette,
                                  label: '上',
                                  value: config.top,
                                  onChanged: (v) => studyCubit.updatePdfCrop(
                                    config
                                        .withClampedCrop(top: v)
                                        .copyWith(showCropGuides: true),
                                  ),
                                  onChangeEnd: (v) => _commitCrop(
                                    context,
                                    summary,
                                    config.withClampedCrop(top: v),
                                  ),
                                ),
                                _CropSideSlider(
                                  palette: palette,
                                  label: '右',
                                  value: config.right,
                                  onChanged: (v) => studyCubit.updatePdfCrop(
                                    config
                                        .withClampedCrop(right: v)
                                        .copyWith(showCropGuides: true),
                                  ),
                                  onChangeEnd: (v) => _commitCrop(
                                    context,
                                    summary,
                                    config.withClampedCrop(right: v),
                                  ),
                                ),
                                _CropSideSlider(
                                  palette: palette,
                                  label: '下',
                                  value: config.bottom,
                                  onChanged: (v) => studyCubit.updatePdfCrop(
                                    config
                                        .withClampedCrop(bottom: v)
                                        .copyWith(showCropGuides: true),
                                  ),
                                  onChangeEnd: (v) => _commitCrop(
                                    context,
                                    summary,
                                    config.withClampedCrop(bottom: v),
                                  ),
                                ),
                                _CropSideSlider(
                                  palette: palette,
                                  label: '左',
                                  value: config.left,
                                  onChanged: (v) => studyCubit.updatePdfCrop(
                                    config
                                        .withClampedCrop(left: v)
                                        .copyWith(showCropGuides: true),
                                  ),
                                  onChangeEnd: (v) => _commitCrop(
                                    context,
                                    summary,
                                    config.withClampedCrop(left: v),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _CompactPresetBtn(
                                        palette: palette,
                                        label: '去页眉',
                                        onTap: () => _commitCrop(
                                          context,
                                          summary,
                                          config.withClampedCrop(top: 0.08),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _CompactPresetBtn(
                                        palette: palette,
                                        label: '去页脚',
                                        onTap: () => _commitCrop(
                                          context,
                                          summary,
                                          config.withClampedCrop(bottom: 0.08),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: _CompactPresetBtn(
                                        palette: palette,
                                        label: '去页眉页脚',
                                        onTap: () => _commitCrop(
                                          context,
                                          summary,
                                          config.withClampedCrop(
                                            top: 0.08,
                                            bottom: 0.08,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: palette.cardSurface,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: palette.borderSubtle,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '无缝文档流',
                                              style: TextStyle(
                                                color: palette.inkPrimary,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              '页间距归零、去掉阴影，多页连成一张',
                                              style: TextStyle(
                                                color: palette.inkMuted,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Transform.scale(
                                        scale: 0.85,
                                        child: Switch(
                                          value: config.seamlessLongDoc,
                                          onChanged: (v) {
                                            final next = config.copyWith(
                                              seamlessLongDoc: v,
                                            );
                                            _commitCrop(context, summary, next);
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (ocrCubit != null)
                            BlocBuilder<OcrCubit, OcrState>(
                              bloc: ocrCubit,
                              builder: (context, ocrState) => _AccordionCard(
                                palette: palette,
                                icon: PhosphorIconsLight.textT,
                                title: 'OCR 文字层',
                                trailingText:
                                    '${ocrState.completedPages} / ${ocrState.totalPages}',
                                expanded: _ocrExpanded,
                                onToggle: () => setState(
                                  () => _ocrExpanded = !_ocrExpanded,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      '命中缓存的页直接读取，不会重复识别。默认识别范围可在下方切换（整个文档 / 渐进式）。页面上的文字随时可以拖拽选中，按 T 可切换白底文字层显示。',
                                      style: TextStyle(
                                        color: palette.inkMuted,
                                        fontSize: 11,
                                        height: 1.45,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Text(
                                          '白底文字层',
                                          style: TextStyle(
                                            color: palette.inkSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const Spacer(),
                                        Transform.scale(
                                          scale: 0.82,
                                          child: Switch(
                                            value: ocrState.whiteBgVisible,
                                            onChanged:
                                                ocrCubit.setWhiteBgVisible,
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        Text(
                                          '白底不透明度',
                                          style: TextStyle(
                                            color: palette.inkSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                        Expanded(
                                          child: SliderTheme(
                                            data: SliderTheme.of(context),
                                            child: Slider(
                                              value: ocrState.whiteBgOpacity,
                                              onChanged: (v) {
                                                if (!ocrState.whiteBgVisible &&
                                                    v > 0.05) {
                                                  ocrCubit.setWhiteBgVisible(
                                                    true,
                                                  );
                                                }
                                                ocrCubit.setWhiteBgOpacity(v);
                                              },
                                            ),
                                          ),
                                        ),
                                        SizedBox(
                                          width: 36,
                                          child: Text(
                                            '${(ocrState.whiteBgOpacity * 100).round()}%',
                                            textAlign: TextAlign.right,
                                            style: TextStyle(
                                              color: palette.inkMuted,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      children: [
                                        Text(
                                          '识别语言',
                                          style: TextStyle(
                                            color: palette.inkSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const Spacer(),
                                        Container(
                                          height: 30,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: palette.controlSurface,
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(
                                              color: palette.borderSubtle,
                                            ),
                                          ),
                                          child: DropdownButton<OcrLanguage>(
                                            value: ocrState.language,
                                            isDense: true,
                                            underline: const SizedBox.shrink(),
                                            style: TextStyle(
                                              color: palette.inkPrimary,
                                              fontSize: 12,
                                            ),
                                            items: [
                                              for (final lang
                                                  in OcrLanguage.values)
                                                DropdownMenuItem<OcrLanguage>(
                                                  value: lang,
                                                  child: Text(lang.label),
                                                ),
                                            ],
                                            onChanged: (val) {
                                              if (val != null) {
                                                unawaited(
                                                  ocrCubit.setLanguage(val),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Text(
                                          '识别引擎',
                                          style: TextStyle(
                                            color: palette.inkSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const Spacer(),
                                        Container(
                                          height: 30,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: palette.controlSurface,
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            border: Border.all(
                                              color: palette.borderSubtle,
                                            ),
                                          ),
                                          child: DropdownButton<OcrEngineMode>(
                                            value: ocrState.engineMode,
                                            isDense: true,
                                            underline: const SizedBox.shrink(),
                                            style: TextStyle(
                                              color: palette.inkPrimary,
                                              fontSize: 11,
                                            ),
                                            items: [
                                              for (final em
                                                  in OcrEngineMode.values)
                                                DropdownMenuItem<OcrEngineMode>(
                                                  value: em,
                                                  child: Text(em.label),
                                                ),
                                            ],
                                            onChanged: (val) {
                                              if (val != null) {
                                                ocrCubit.syncAiConfig(
                                                  studyState.aiConfig,
                                                );
                                                unawaited(
                                                  ocrCubit.setEngineMode(val),
                                                );
                                              }
                                            },
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Tooltip(
                                          message: '配置 OpenAI 兼容接口',
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(
                                              6,
                                            ),
                                            onTap: () => unawaited(
                                              showOpenAiApiSettingsDialog(
                                                context,
                                              ),
                                            ),
                                            child: Container(
                                              width: 30,
                                              height: 30,
                                              decoration: BoxDecoration(
                                                color: studyState
                                                        .aiConfig
                                                        .isConfigured
                                                    ? palette.accentSoft
                                                    : palette.controlSurface,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                border: Border.all(
                                                  color: palette.borderSubtle,
                                                ),
                                              ),
                                              child: Center(
                                                child: PhosphorIcon(
                                                  PhosphorIconsLight.gear,
                                                  size: 14,
                                                  color: studyState
                                                          .aiConfig
                                                          .isConfigured
                                                      ? palette.accentBerryDark
                                                      : palette.inkSecondary,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        Text(
                                          '识别范围',
                                          style: TextStyle(
                                            color: palette.inkSecondary,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const Spacer(),
                                        for (final s in OcrScope.values) ...[
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 4,
                                            ),
                                            child: ChoiceChip(
                                              label: Text(
                                                s.label,
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                ),
                                              ),
                                              visualDensity:
                                                  VisualDensity.compact,
                                              selected: ocrState.scope == s,
                                              onSelected: (_) => unawaited(
                                                ocrCubit.setScope(s),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    if (loaded != null &&
                                        summary != null &&
                                        ocrState.totalPages == 0)
                                      FilledButton(
                                        style: FilledButton.styleFrom(
                                          backgroundColor: palette.accentBerry,
                                        ),
                                        onPressed: () {
                                          ocrCubit.syncAiConfig(
                                            studyState.aiConfig,
                                          );
                                          unawaited(
                                            ocrCubit.bindDocument(
                                              pdfSource: summary.source,
                                              document: loaded.data,
                                              assets: loaded.assetService,
                                              initialFocusPage: pageIdx,
                                              forceSameSource: true,
                                            ),
                                          );
                                        },
                                        child: const Text(
                                          '立即绑定并启动 OCR 识别',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      )
                                    else
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: OutlinedButton(
                                                  style: OutlinedButton.styleFrom(
                                                    backgroundColor:
                                                        palette.controlSurface,
                                                    foregroundColor:
                                                        palette.inkPrimary,
                                                    side: BorderSide(
                                                      color:
                                                          palette.borderStrong,
                                                    ),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                  ),
                                                  onPressed:
                                                      ocrState.isRunning ||
                                                          ocrState.totalPages ==
                                                              0
                                                      ? null
                                                      : () => unawaited(
                                                          ocrCubit
                                                              .rerunOcrTask(),
                                                        ),
                                                  child: const Text(
                                                    '重新执行 OCR',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              if (ocrState.isRunning) ...[
                                                const SizedBox(width: 6),
                                                OutlinedButton(
                                                  style: OutlinedButton.styleFrom(
                                                    backgroundColor:
                                                        palette.accentSoft,
                                                    foregroundColor:
                                                        palette.accentBerryDark,
                                                    side: BorderSide(
                                                      color:
                                                          palette.accentBerry,
                                                    ),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            8,
                                                          ),
                                                    ),
                                                  ),
                                                  onPressed:
                                                      ocrCubit.stopOcrTask,
                                                  child: const Text(
                                                    '停止',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          OutlinedButton.icon(
                                            style: OutlinedButton.styleFrom(
                                              backgroundColor:
                                                  palette.controlSurface,
                                              foregroundColor:
                                                  palette.accentBerryDark,
                                              side: BorderSide(
                                                color: palette.borderSubtle,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                            ),
                                            onPressed: (ocrState.totalPages == 0 ||
                                                    ocrState.isRunning)
                                                ? null
                                                : () async {
                                                    if (!studyState
                                                        .aiConfig
                                                        .isConfigured) {
                                                      await showOpenAiApiSettingsDialog(
                                                        context,
                                                      );
                                                      return;
                                                    }
                                                    await ocrCubit
                                                        .recognizeSinglePageWithOpenAi(
                                                          pageIdx,
                                                          studyState.aiConfig,
                                                        );
                                                  },
                                            icon: const PhosphorIcon(
                                              PhosphorIconsLight.sparkle,
                                              size: 14,
                                            ),
                                            label: Text(
                                              studyState.aiConfig.isConfigured
                                                  ? 'AI 视觉高精度识别第 ${pageIdx + 1} 页'
                                                  : '配置 OpenAI 视觉 API 精识本页',
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.all(10),
                                      decoration: BoxDecoration(
                                        color: palette.cardSurface,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: palette.borderSubtle,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                '本文档识别进度',
                                                style: TextStyle(
                                                  color: palette.inkSecondary,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                              const Spacer(),
                                              Text(
                                                '${ocrState.completedPages} / ${ocrState.totalPages}',
                                                style: TextStyle(
                                                  color: palette.inkPrimary,
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(4),
                                            child: LinearProgressIndicator(
                                              value: ocrState.totalPages == 0
                                                  ? 0
                                                  : ocrState.progress,
                                              minHeight: 5,
                                              backgroundColor:
                                                  palette.trackFill,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    palette.progressBar,
                                                  ),
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            ocrState.isRunning
                                                ? '正在识别第 ${(ocrState.currentRunningPage ?? 0) + 1} / ${ocrState.totalPages} 页…'
                                                : ocrState.statusError != null
                                                ? ocrState.statusError!
                                                : ocrState.allCompleted
                                                ? '全部完成，缓存命中 ${ocrState.cacheHitPages} 页'
                                                : ocrState.totalPages == 0
                                                ? '打开含 PDF 文档后自动开始离线识别'
                                                : ocrState.scope ==
                                                      OcrScope.progressive
                                                ? '渐进式就绪 ${ocrState.completedPages} / ${ocrState.totalPages} 页 · 翻页时自动识别邻近页'
                                                : '已就绪 ${ocrState.completedPages} / ${ocrState.totalPages} 页（缓存命中 ${ocrState.cacheHitPages} 页）',
                                            style: TextStyle(
                                              color: ocrState.statusError != null
                                                  ? palette.accentBerry
                                                  : palette.inkMuted,
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(height: 8),
                          _AccordionCard(
                            palette: palette,
                            icon: PhosphorIconsLight.download,
                            title: '导出',
                            trailingText: 'PNG',
                            expanded: _exportExpanded,
                            onToggle: () => setState(
                              () => _exportExpanded = !_exportExpanded,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '按当前页边距裁剪导出，2× 分辨率（约 144 DPI）。全部页会逐页写成 PNG 放进你选择的文件夹。',
                                  style: TextStyle(
                                    color: palette.inkMuted,
                                    fontSize: 11,
                                    height: 1.45,
                                  ),
                                ),
                                if (_exporting) ...[
                                  const SizedBox(height: 8),
                                  LinearProgressIndicator(
                                    value: _exportTotal > 0
                                        ? _exportDone / _exportTotal
                                        : null,
                                    minHeight: 4,
                                  ),
                                ],
                                const SizedBox(height: 10),
                                Row(
                                  children: [
                                    Expanded(
                                      child: _CompactIconActionBtn(
                                        palette: palette,
                                        icon: PhosphorIconsLight.fileImage,
                                        label: '导出本页',
                                        onTap: (_pdfDoc == null || _exporting)
                                            ? null
                                            : () => unawaited(
                                                _exportCurrent(
                                                  context,
                                                  docTitle,
                                                  pageIdx,
                                                  config,
                                                ),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: _CompactIconActionBtn(
                                        palette: palette,
                                        icon: PhosphorIconsLight.files,
                                        label: '导出全部页',
                                        onTap: (_pdfDoc == null || _exporting)
                                            ? null
                                            : () => unawaited(
                                                _exportAll(
                                                  context,
                                                  docTitle,
                                                  config,
                                                ),
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ModeTabButton extends StatelessWidget {
  final YingPdfPalette palette;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeTabButton({
    required this.palette,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5),
        decoration: BoxDecoration(
          color: selected ? palette.controlSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? palette.inkPrimary : palette.inkSecondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _AccordionCard extends StatelessWidget {
  final YingPdfPalette palette;
  final PhosphorIconData icon;
  final String title;
  final String? trailingText;
  final Widget? trailingAction;
  final bool expanded;
  final VoidCallback onToggle;
  final Widget child;

  const _AccordionCard({
    required this.palette,
    required this.icon,
    required this.title,
    this.trailingText,
    this.trailingAction,
    required this.expanded,
    required this.onToggle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.headerSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
              child: Row(
                children: [
                  PhosphorIcon(icon, size: 15, color: palette.inkSecondary),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: palette.inkPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (trailingAction != null) ...[
                    trailingAction!,
                    const SizedBox(width: 6),
                  ] else if (trailingText != null) ...[
                    Text(
                      trailingText!,
                      style: TextStyle(
                        color: palette.inkMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  PhosphorIcon(
                    expanded
                        ? PhosphorIconsLight.caretRight
                        : PhosphorIconsLight.caretLeft,
                    size: 13,
                    color: palette.inkMuted,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(11, 2, 11, 12),
              child: child,
            ),
        ],
      ),
    );
  }
}

class _CropSideSlider extends StatelessWidget {
  final YingPdfPalette palette;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  const _CropSideSlider({
    required this.palette,
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Text(
              label,
              style: TextStyle(
                color: palette.inkSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                padding: const EdgeInsets.symmetric(horizontal: 4),
              ),
              child: Slider(
                value: value.clamp(0.0, PdfMarginCropConfig.maxSideCrop),
                min: 0.0,
                max: PdfMarginCropConfig.maxSideCrop,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${(value * 100).toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: palette.inkMuted,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactPresetBtn extends StatelessWidget {
  final YingPdfPalette palette;
  final String label;
  final VoidCallback onTap;

  const _CompactPresetBtn({
    required this.palette,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: palette.controlSurface,
        foregroundColor: palette.inkPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        side: BorderSide(color: palette.borderSubtle),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      onPressed: onTap,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}

class _CompactIconActionBtn extends StatelessWidget {
  final YingPdfPalette palette;
  final PhosphorIconData icon;
  final String label;
  final VoidCallback? onTap;

  const _CompactIconActionBtn({
    required this.palette,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        backgroundColor: palette.controlSurface,
        foregroundColor: palette.inkPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
        side: BorderSide(color: palette.borderStrong),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onTap,
      icon: PhosphorIcon(icon, size: 15),
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
    );
  }
}

class _MiniCropMaskPainter extends CustomPainter {
  final double top;
  final double right;
  final double bottom;
  final double left;
  final Color accentColor;

  const _MiniCropMaskPainter({
    required this.top,
    required this.right,
    required this.bottom,
    required this.left,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (top <= 0.001 &&
        right <= 0.001 &&
        bottom <= 0.001 &&
        left <= 0.001) {
      return;
    }
    final inner = Rect.fromLTRB(
      size.width * left,
      size.height * top,
      size.width * (1.0 - right),
      size.height * (1.0 - bottom),
    );
    final maskPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(inner);
    canvas.drawPath(maskPath, Paint()..color = const Color(0x55000000));
    canvas.drawRect(
      inner,
      Paint()
        ..color = accentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_MiniCropMaskPainter oldDelegate) =>
      oldDelegate.top != top ||
      oldDelegate.right != right ||
      oldDelegate.bottom != bottom ||
      oldDelegate.left != left ||
      oldDelegate.accentColor != accentColor;
}
