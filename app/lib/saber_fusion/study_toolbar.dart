import 'dart:async';
import 'dart:math';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/editor_controller.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_leap/material_leap.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'lan_sync_cubit.dart';
import 'lan_sync_dialog.dart';
import 'lan_sync_models.dart';
import 'multi_pdf_window_cubit.dart';
import 'multi_pdf_window_layer.dart';
import 'pdf_canvas_reflow_service.dart';
import 'pdf_overview_dialog.dart';
import 'pdf_reading_models.dart';
import 'study_state.dart';

class SaberQuickStrip extends StatelessWidget {
  const SaberQuickStrip({super.key});

  @override
  Widget build(BuildContext context) {
    final studyCubit = maybeStudyModeCubit(context);
    if (studyCubit == null) return const SizedBox.shrink();

    return BlocBuilder<StudyModeCubit, StudyModeState>(
      bloc: studyCubit,
      buildWhen: (previous, current) =>
          previous.colorMode != current.colorMode ||
          previous.studyToolbarMode != current.studyToolbarMode ||
          previous.studyPanelOpen != current.studyPanelOpen ||
          previous.aiSnippingMode != current.aiSnippingMode ||
          previous.pdfCrop != current.pdfCrop,
      builder: (context, state) {
        final colorScheme = ColorScheme.of(context);
        final isBookMode =
            state.pdfCrop.layoutMode != PdfViewLayoutMode.singlePage;
        final cropActive =
            state.pdfCrop.hasCrop || state.pdfCrop.seamlessLongDoc;
        final maxW = max(220.0, MediaQuery.sizeOf(context).width - 24.0);

        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: Card.outlined(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: state.studyToolbarMode
                          ? '退出极简刷题栏'
                          : '极简刷题工具栏 (Saber笔盒)',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      isSelected: state.studyToolbarMode,
                      style: state.studyToolbarMode
                          ? IconButton.styleFrom(
                              backgroundColor: colorScheme.primaryContainer,
                              foregroundColor: colorScheme.onPrimaryContainer,
                            )
                          : null,
                      icon: PhosphorIcon(
                        state.studyToolbarMode
                            ? PhosphorIconsFill.pen
                            : PhosphorIconsLight.pencilSimpleLine,
                        size: 18,
                      ),
                      onPressed: studyCubit.toggleStudyToolbarMode,
                    ),
                    IconButton(
                      tooltip: '护眼反色：${state.colorMode.displayName}',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      isSelected: state.colorMode.index != 0,
                      style: state.colorMode.index != 0
                          ? IconButton.styleFrom(
                              backgroundColor: colorScheme.secondaryContainer,
                              foregroundColor:
                                  colorScheme.onSecondaryContainer,
                            )
                          : null,
                      icon: PhosphorIcon(state.colorMode.icon, size: 18),
                      onPressed: studyCubit.cycleColorMode,
                    ),
                    IconButton(
                      tooltip: isBookMode ? '切回单页连续视图' : '书本双页视图',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      isSelected: isBookMode,
                      style: isBookMode
                          ? IconButton.styleFrom(
                              backgroundColor: colorScheme.primaryContainer,
                              foregroundColor: colorScheme.onPrimaryContainer,
                            )
                          : null,
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.columns,
                        size: 18,
                      ),
                      onPressed: () =>
                          PdfCanvasReflowService.toggleBookSpreadMode(context),
                    ),
                    IconButton(
                      tooltip: '全屏页面总览（网格选页）',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.squaresFour,
                        size: 18,
                      ),
                      onPressed: () =>
                          unawaited(showPdfOverviewDialog(context)),
                    ),
                    IconButton(
                      tooltip: '侧边栏：页边距裁剪 / 无缝长文档',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      isSelected:
                          (state.studyPanelOpen &&
                              state.activeTab == StudyPanelTab.crop) ||
                          cropActive,
                      style: cropActive
                          ? IconButton.styleFrom(
                              backgroundColor: colorScheme.secondaryContainer,
                              foregroundColor:
                                  colorScheme.onSecondaryContainer,
                            )
                          : null,
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.crop,
                        size: 18,
                      ),
                      onPressed: () =>
                          studyCubit.toggleStudyPanel(StudyPanelTab.crop),
                    ),
                    IconButton(
                      tooltip: '切换 YingPDF 暖纸风格与 OCR 阅读器',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.textT,
                        size: 18,
                      ),
                      onPressed: () => studyCubit.setYingPdfStyle(true),
                    ),
                    IconButton(
                      tooltip: '教材目录 / 搜题 / 错题本',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      isSelected: state.studyPanelOpen,
                      style: state.studyPanelOpen
                          ? IconButton.styleFrom(
                              backgroundColor: colorScheme.primaryContainer,
                              foregroundColor: colorScheme.onPrimaryContainer,
                            )
                          : null,
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.bookOpen,
                        size: 18,
                      ),
                      onPressed: () => studyCubit.toggleStudyPanel(),
                    ),
                    IconButton(
                      tooltip: '框选题目问 AI',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      isSelected: state.aiSnippingMode,
                      style: state.aiSnippingMode
                          ? IconButton.styleFrom(
                              backgroundColor: colorScheme.tertiaryContainer,
                              foregroundColor: colorScheme.onTertiaryContainer,
                            )
                          : null,
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.sparkle,
                        size: 18,
                      ),
                      onPressed: () =>
                          studyCubit.setAiSnippingMode(!state.aiSnippingMode),
                    ),
                    if (maybeMultiPdfWindowCubit(context) case final winCubit?)
                      BlocBuilder<MultiPdfWindowCubit, MultiPdfWindowState>(
                        bloc: winCubit,
                        buildWhen: (prev, curr) =>
                            prev.windows.length != curr.windows.length ||
                            prev.dockVisible != curr.dockVisible,
                        builder: (context, winState) {
                          final active =
                              winState.windows.isNotEmpty ||
                              winState.dockVisible;
                          return IconButton(
                            tooltip: '多 PDF 窗口化（QQ 式悬浮小窗）',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 32,
                            ),
                            padding: EdgeInsets.zero,
                            isSelected: active,
                            style: active
                                ? IconButton.styleFrom(
                                    backgroundColor:
                                        colorScheme.primaryContainer,
                                    foregroundColor:
                                        colorScheme.onPrimaryContainer,
                                  )
                                : null,
                            icon: Badge(
                              isLabelVisible: winState.windows.isNotEmpty,
                              label: Text('${winState.windows.length}'),
                              child: const PhosphorIcon(
                                PhosphorIconsLight.appWindow,
                                size: 18,
                              ),
                            ),
                            onPressed: () => openMultiPdfWindowEntry(context),
                          );
                        },
                      ),
                    if (maybeLanSyncCubit(context) case final lanCubit?)
                      BlocBuilder<LanSyncCubit, LanSyncState>(
                        bloc: lanCubit,
                        buildWhen: (previous, current) =>
                            previous.account.isSignedIn !=
                                current.account.isSignedIn ||
                            previous.peers.length != current.peers.length ||
                            previous.syncing != current.syncing,
                        builder: (context, syncState) {
                          final online =
                              syncState.account.isSignedIn &&
                              syncState.peers.isNotEmpty;
                          return IconButton(
                            tooltip: !syncState.account.isSignedIn
                                ? '双端局域网同步账号'
                                : online
                                ? '局域网已连接 ${syncState.peers.length} 台设备（点击同步/查页码）'
                                : '局域网同步监听中',
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 32,
                            ),
                            padding: EdgeInsets.zero,
                            isSelected: online,
                            style: online
                                ? IconButton.styleFrom(
                                    backgroundColor:
                                        colorScheme.primaryContainer,
                                    foregroundColor:
                                        colorScheme.onPrimaryContainer,
                                  )
                                : null,
                            icon: PhosphorIcon(
                              syncState.account.isSignedIn
                                  ? PhosphorIconsLight.wifiHigh
                                  : PhosphorIconsLight.cloud,
                              size: 18,
                            ),
                            onPressed: () =>
                                unawaited(showLanSyncDialog(context)),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class SaberStudyToolbar extends StatelessWidget {
  const SaberStudyToolbar({super.key});

  static const _penPresets = <(String label, int color, double width)>[
    ('黑笔', 0xFF111111, 3.0),
    ('蓝笔', 0xFF1565C0, 3.0),
    ('红笔订正', 0xFFD32F2F, 3.0),
    ('草稿细笔', 0xFF546E7A, 1.8),
  ];

  static const _highlighterPresets = <(String label, int color)>[
    ('黄荧光笔', 0x70FFEB3B),
    ('绿荧光笔', 0x7069F0AE),
    ('粉荧光笔', 0x70FF80AB),
  ];

  Future<void> _activateOrCreateTool(
    BuildContext context, {
    required int Function(List<Tool> tools) findIndex,
    required Tool Function(Tool? existing) buildTool,
  }) async {
    final bloc = context.read<DocumentBloc>();
    final cubit = context.read<EditorController>();
    final docState = bloc.state;
    if (docState is! DocumentLoadSuccess) return;

    final tools = docState.info.tools;
    final idx = findIndex(tools);
    if (idx >= 0) {
      final existing = tools[idx];
      final updated = buildTool(existing);
      await cubit.toolCubit.changeTool(
        cubit,
        bloc,
        index: idx,
        context: context,
      );
      final unchangedPen =
          existing is PenTool &&
          updated is PenTool &&
          existing.combinePaths == updated.combinePaths &&
          existing.property.strokeWidth == updated.property.strokeWidth &&
          existing.property.thinning == updated.property.thinning &&
          existing.property.paint.previewColor.value ==
              updated.property.paint.previewColor.value;
      if (!unchangedPen && updated != existing) {
        bloc.add(ToolsChanged([updated]));
      }
      return;
    }

    final newId = createUniqueId();
    final created = buildTool(null).copyWith(id: newId);
    bloc.add(ToolCreated(created));
    try {
      final nextState = await bloc.stream
          .where(
            (s) =>
                s is DocumentLoadSuccess &&
                s.info.tools.any((t) => t.id == newId),
          )
          .cast<DocumentLoadSuccess>()
          .first
          .timeout(const Duration(seconds: 2));
      if (!context.mounted) return;
      final createdIdx = nextState.info.tools.indexWhere((t) => t.id == newId);
      if (createdIdx >= 0) {
        await cubit.toolCubit.changeTool(
          cubit,
          bloc,
          index: createdIdx,
          context: context,
        );
      }
    } catch (_) {}
  }

  void _selectPen(BuildContext context, int argb, double width) {
    unawaited(
      _activateOrCreateTool(
        context,
        findIndex: (tools) =>
            tools.indexWhere((t) => t is PenTool && !t.combinePaths),
        buildTool: (existing) {
          final base = existing is PenTool
              ? existing
              : PenTool(name: '刷题笔', combinePaths: false);
          return base.copyWith(
            combinePaths: false,
            property: base.property.copyWith(
              strokeWidth: width,
              thinning: 0.35,
              paint: ElementPaint.solid(color: SRGBColor(argb)),
            ),
          );
        },
      ),
    );
  }

  void _selectHighlighter(BuildContext context, int argb) {
    unawaited(
      _activateOrCreateTool(
        context,
        findIndex: (tools) =>
            tools.indexWhere((t) => t is PenTool && t.combinePaths),
        buildTool: (existing) {
          final base = existing is PenTool
              ? existing
              : PenTool(name: '不遮字荧光笔', combinePaths: true);
          return base.copyWith(
            combinePaths: true,
            property: base.property.copyWith(
              strokeWidth: 20,
              thinning: 0,
              paint: ElementPaint.solid(color: SRGBColor(argb)),
            ),
          );
        },
      ),
    );
  }

  void _selectEraser(BuildContext context) {
    unawaited(
      _activateOrCreateTool(
        context,
        findIndex: (tools) => tools.indexWhere((t) => t is EraserTool),
        buildTool: (existing) =>
            existing is EraserTool ? existing : EraserTool(mode: EraserMode.path),
      ),
    );
  }

  void _selectLasso(BuildContext context) {
    unawaited(
      _activateOrCreateTool(
        context,
        findIndex: (tools) => tools.indexWhere((t) => t is SelectTool),
        buildTool: (existing) => existing is SelectTool
            ? existing
            : SelectTool(mode: SelectMode.lasso),
      ),
    );
  }

  void _selectHand(BuildContext context) {
    unawaited(
      _activateOrCreateTool(
        context,
        findIndex: (tools) => tools.indexWhere((t) => t is HandTool),
        buildTool: (existing) => existing is HandTool ? existing : HandTool(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final bloc = context.read<DocumentBloc>();

    return BlocBuilder<StudyModeCubit, StudyModeState>(
      builder: (context, studyState) {
        return BlocBuilder<DocumentBloc, DocumentState>(
          builder: (context, docState) {
            final pages = docState is DocumentLoadSuccess
                ? docState.data.getPages(true)
                : const <String>[];
            final currentPageIdx = docState is DocumentLoadSuccess
                ? pages.indexOf(docState.pageName)
                : -1;

            return BlocBuilder<ToolCubit, ToolRuntimeState>(
              builder: (context, toolState) {
                final activeTool = toolState.handler.data;
                final activePenColor = activeTool is PenTool
                    ? activeTool.property.paint.previewColor.value
                    : null;
                final activePenCombine =
                    activeTool is PenTool ? activeTool.combinePaths : null;

                return SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                    child: Card(
                      elevation: 10,
                      shape: const StadiumBorder(),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final pen in _penPresets)
                              _ColorDotButton(
                                tooltip: pen.$1,
                                color: Color(pen.$2),
                                selected:
                                    activePenCombine == false &&
                                    activePenColor == pen.$2,
                                isHighlighter: false,
                                onTap: () =>
                                    _selectPen(context, pen.$2, pen.$3),
                              ),
                            const SizedBox(width: 4),
                            const SizedBox(
                              height: 22,
                              child: VerticalDivider(width: 8),
                            ),
                            for (final hl in _highlighterPresets)
                              _ColorDotButton(
                                tooltip: hl.$1,
                                color: Color(hl.$2).withAlpha(220),
                                selected:
                                    activePenCombine == true &&
                                    activePenColor == hl.$2,
                                isHighlighter: true,
                                onTap: () => _selectHighlighter(context, hl.$2),
                              ),
                            IconButton(
                              tooltip: studyState.perfectHighlighter
                                  ? '不遮字荧光笔已开启（点击切换传统模式）'
                                  : '已切回传统叠加模式（点击开启不遮字）',
                              visualDensity: VisualDensity.compact,
                              isSelected: studyState.perfectHighlighter,
                              icon: PhosphorIcon(
                                studyState.perfectHighlighter
                                    ? PhosphorIconsFill.highlighterCircle
                                    : PhosphorIconsLight.highlighterCircle,
                                size: 18,
                              ),
                              onPressed: () => context
                                  .read<StudyModeCubit>()
                                  .togglePerfectHighlighter(),
                            ),
                            const SizedBox(
                              height: 22,
                              child: VerticalDivider(width: 8),
                            ),
                            IconButton(
                              tooltip: '橡皮擦',
                              visualDensity: VisualDensity.compact,
                              isSelected: activeTool is EraserTool,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.eraser,
                                size: 18,
                              ),
                              onPressed: () => _selectEraser(context),
                            ),
                            IconButton(
                              tooltip: '套索选择',
                              visualDensity: VisualDensity.compact,
                              isSelected: activeTool is SelectTool,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.lasso,
                                size: 18,
                              ),
                              onPressed: () => _selectLasso(context),
                            ),
                            IconButton(
                              tooltip: '抓手移动',
                              visualDensity: VisualDensity.compact,
                              isSelected: activeTool is HandTool,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.hand,
                                size: 18,
                              ),
                              onPressed: () => _selectHand(context),
                            ),
                            IconButton(
                              tooltip: '撤销',
                              visualDensity: VisualDensity.compact,
                              onPressed:
                                  bloc.canSendUndo ? bloc.sendUndo : null,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.arrowCounterClockwise,
                                size: 18,
                              ),
                            ),
                            IconButton(
                              tooltip: '重做',
                              visualDensity: VisualDensity.compact,
                              onPressed:
                                  bloc.canSendRedo ? bloc.sendRedo : null,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.arrowClockwise,
                                size: 18,
                              ),
                            ),
                            if (pages.length > 1 && currentPageIdx >= 0) ...[
                              const SizedBox(
                                height: 22,
                                child: VerticalDivider(width: 8),
                              ),
                              IconButton(
                                tooltip: '上一页',
                                visualDensity: VisualDensity.compact,
                                onPressed: currentPageIdx > 0
                                    ? () => bloc.add(
                                        PageChanged(pages[currentPageIdx - 1]),
                                      )
                                    : null,
                                icon: const PhosphorIcon(
                                  PhosphorIconsLight.caretLeft,
                                  size: 16,
                                ),
                              ),
                              Text(
                                '${currentPageIdx + 1}/${pages.length}',
                                style: TextTheme.of(context).labelMedium,
                              ),
                              IconButton(
                                tooltip: '下一页',
                                visualDensity: VisualDensity.compact,
                                onPressed: currentPageIdx < pages.length - 1
                                    ? () => bloc.add(
                                        PageChanged(pages[currentPageIdx + 1]),
                                      )
                                    : null,
                                icon: const PhosphorIcon(
                                  PhosphorIconsLight.caretRight,
                                  size: 16,
                                ),
                              ),
                            ],
                            const SizedBox(
                              height: 22,
                              child: VerticalDivider(width: 8),
                            ),
                            IconButton(
                              tooltip:
                                  '护眼反色：${studyState.colorMode.displayName}',
                              visualDensity: VisualDensity.compact,
                              isSelected: studyState.colorMode.index != 0,
                              icon: PhosphorIcon(
                                studyState.colorMode.icon,
                                size: 18,
                              ),
                              onPressed: () => context
                                  .read<StudyModeCubit>()
                                  .cycleColorMode(),
                            ),
                            IconButton(
                              tooltip:
                                  studyState.pdfCrop.layoutMode !=
                                      PdfViewLayoutMode.singlePage
                                  ? '切回单页连续视图'
                                  : '书本双页视图',
                              visualDensity: VisualDensity.compact,
                              isSelected:
                                  studyState.pdfCrop.layoutMode !=
                                  PdfViewLayoutMode.singlePage,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.columns,
                                size: 18,
                              ),
                              onPressed: () =>
                                  PdfCanvasReflowService.toggleBookSpreadMode(
                                    context,
                                  ),
                            ),
                            IconButton(
                              tooltip: '全屏页面总览',
                              visualDensity: VisualDensity.compact,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.squaresFour,
                                size: 18,
                              ),
                              onPressed: () =>
                                  unawaited(showPdfOverviewDialog(context)),
                            ),
                            IconButton(
                              tooltip: '侧边栏：页边距裁剪 / 无缝长文档',
                              visualDensity: VisualDensity.compact,
                              isSelected:
                                  (studyState.studyPanelOpen &&
                                      studyState.activeTab ==
                                          StudyPanelTab.crop) ||
                                  studyState.pdfCrop.hasCrop ||
                                  studyState.pdfCrop.seamlessLongDoc,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.crop,
                                size: 18,
                              ),
                              onPressed: () => context
                                  .read<StudyModeCubit>()
                                  .toggleStudyPanel(StudyPanelTab.crop),
                            ),
                            if (maybeMultiPdfWindowCubit(context) != null)
                              IconButton(
                                tooltip: '多 PDF 窗口化（QQ 式悬浮窗）',
                                visualDensity: VisualDensity.compact,
                                icon: const PhosphorIcon(
                                  PhosphorIconsLight.appWindow,
                                  size: 18,
                                ),
                                onPressed: () =>
                                    openMultiPdfWindowEntry(context),
                              ),
                            IconButton(
                              tooltip: '教材目录 / 搜题 / 错题本',
                              visualDensity: VisualDensity.compact,
                              isSelected: studyState.studyPanelOpen,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.bookOpen,
                                size: 18,
                              ),
                              onPressed: () => context
                                  .read<StudyModeCubit>()
                                  .toggleStudyPanel(),
                            ),
                            IconButton(
                              tooltip: '框选题目问 AI',
                              visualDensity: VisualDensity.compact,
                              isSelected: studyState.aiSnippingMode,
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.sparkle,
                                size: 18,
                              ),
                              onPressed: () => context
                                  .read<StudyModeCubit>()
                                  .setAiSnippingMode(
                                    !studyState.aiSnippingMode,
                                  ),
                            ),
                            IconButton(
                              tooltip: '恢复 Butterfly 完整工具栏',
                              visualDensity: VisualDensity.compact,
                              style: IconButton.styleFrom(
                                foregroundColor: colorScheme.primary,
                              ),
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.slidersHorizontal,
                                size: 18,
                              ),
                              onPressed: () => context
                                  .read<StudyModeCubit>()
                                  .setStudyToolbarMode(false),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ColorDotButton extends StatelessWidget {
  final String tooltip;
  final Color color;
  final bool selected;
  final bool isHighlighter;
  final VoidCallback onTap;

  const _ColorDotButton({
    required this.tooltip,
    required this.color,
    required this.selected,
    required this.isHighlighter,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? colorScheme.primary : Colors.transparent,
              width: 2.2,
            ),
          ),
          alignment: Alignment.center,
          child: Container(
            width: isHighlighter ? 18 : 15,
            height: isHighlighter ? 11 : 15,
            decoration: BoxDecoration(
              color: color,
              borderRadius: isHighlighter
                  ? BorderRadius.circular(3)
                  : BorderRadius.circular(9),
              border: Border.all(
                color: colorScheme.outlineVariant,
                width: 0.8,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
