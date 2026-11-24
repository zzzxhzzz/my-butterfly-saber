import 'dart:async';
import 'dart:math';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/handlers/handler.dart';
import 'package:butterfly/services/import.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_leap/material_leap.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'ai_tutor_tab.dart';
import 'lan_sync_cubit.dart';
import 'lan_sync_dialog.dart';
import 'lan_sync_models.dart';
import 'multi_pdf_window_cubit.dart';
import 'multi_pdf_window_layer.dart';
import 'ocr_cubit.dart';
import 'ocr_models.dart';
import 'pdf_canvas_reflow_service.dart';
import 'pdf_overview_dialog.dart';
import 'pdf_reading_models.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';
import 'ying_pdf_theme.dart';

class YingPdfHeaderBar extends StatelessWidget implements PreferredSizeWidget {
  final bool inView;

  const YingPdfHeaderBar({
    super.key,
    this.inView = false,
  });

  @override
  Size get preferredSize => const Size.fromHeight(48);

  void _zoomBy(
    BuildContext context,
    StudyModeState studyState,
    double factor,
  ) {
    final size = MediaQuery.sizeOf(context);
    final inspectorW =
        studyState.inspectorOpen && size.width >= LeapBreakpoints.expanded
        ? 308.0
        : 0.0;
    final center = Offset(
      max(120.0, (size.width - inspectorW) * 0.5),
      max(120.0, (size.height - preferredSize.height) * 0.5),
    );
    context.read<TransformCubit>().zoom(factor, center);
    context.read<DocumentBloc>().delayedBake(
      viewportSize: Size(size.width - inspectorW, size.height),
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
      testTransform: false,
    );
  }

  void _fitWidth(
    BuildContext context,
    StudyModeState studyState,
    DocumentLoadSuccess docState,
    PdfSourceSummary? summary,
  ) {
    final size = MediaQuery.sizeOf(context);
    final inspectorW =
        studyState.inspectorOpen && size.width >= LeapBreakpoints.expanded
        ? 308.0
        : 0.0;
    final viewW = max(240.0, size.width - inspectorW);
    final tc = context.read<TransformCubit>();

    if (summary != null && summary.placements.isNotEmpty) {
      final pageIdx = PdfCanvasReflowService.detectCurrentPageIndex(
        context,
        summary,
      );
      final placement = summary.placements.firstWhere(
        (p) => p.pdfPageIndex == pageIdx,
        orElse: () => summary.placements.first,
      );
      final cropped = studyState.pdfCrop.croppedWorldRect(
        placement.bounds,
        placement.pdfPageIndex,
      );
      final targetScale = ((viewW - 44.0) / max(120.0, cropped.width)).clamp(
        0.35,
        3.2,
      );
      final targetX = cropped.center.dx - (viewW * 0.5) / targetScale;
      final targetY = cropped.top - 20.0 / targetScale;
      tc.teleport(Offset(targetX, targetY), targetScale, 0);
    } else {
      tc.reset();
    }
    context.read<DocumentBloc>().delayedBake(
      viewportSize: Size(viewW, size.height),
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
      testTransform: false,
    );
  }

  void _cycleBookLayout(
    BuildContext context,
    StudyModeCubit studyCubit,
    StudyModeState studyState,
    PdfSourceSummary? summary,
  ) {
    final modes = PdfViewLayoutMode.values;
    final nextIdx = (modes.indexOf(studyState.pdfCrop.layoutMode) + 1) % modes.length;
    final nextConfig = studyState.pdfCrop.copyWith(layoutMode: modes[nextIdx]);
    studyCubit.updatePdfCrop(nextConfig, persist: true);
    if (summary != null) {
      unawaited(
        PdfCanvasReflowService.reflowCurrentPage(context, summary, nextConfig),
      );
    }
  }

  void _showShortcutHelpDialog(BuildContext context) {
    final palette = YingPdfPalette.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('阅读器与 OCR 快捷键'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: const [
              _ShortcutRow(keys: 'T', desc: '切换 OCR 白底重排文字层显示'),
              _ShortcutRow(keys: 'R', desc: '区域截图框选（或将已选文字添加到画布）'),
              _ShortcutRow(keys: 'F', desc: '打开全文 / OCR 识别结果搜索'),
              _ShortcutRow(keys: 'Ctrl + C', desc: '复制当前拖选中的 OCR 文字'),
              _ShortcutRow(keys: 'Esc', desc: '清除文字选中或取消区域截取'),
            ],
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: palette.accentBerry),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = YingPdfPalette.of(context);
    final studyCubit = maybeStudyModeCubit(context);
    final ocrCubit = maybeOcrCubit(context);
    final nativeTitleBar = context.select<SettingsCubit, bool>(
      (cubit) => cubit.state.nativeTitleBar,
    );

    if (studyCubit == null) return const SizedBox.shrink();

    return Container(
      height: preferredSize.height + MediaQuery.paddingOf(context).top,
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      decoration: BoxDecoration(
        color: palette.headerSurface,
        border: Border(
          bottom: BorderSide(color: palette.borderSubtle, width: 1),
        ),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            const Positioned.fill(
              child: WindowFreeSpace<SettingsCubit, ButterflySettings>(),
            ),
            BlocBuilder<StudyModeCubit, StudyModeState>(
              bloc: studyCubit,
              builder: (context, studyState) =>
                  BlocBuilder<DocumentBloc, DocumentState>(
                    builder: (context, docState) {
                      final loaded = docState is DocumentLoadSuccess ? docState : null;
                      final summaries = loaded != null
                          ? PdfStudyService.indexDocumentPdfs(loaded)
                          : const <PdfSourceSummary>[];
                      final primarySummary = summaries.firstOrNull;
                      final docTitle =
                          (primarySummary != null &&
                              primarySummary.displayName.trim().isNotEmpty)
                          ? primarySummary.displayName.trim()
                          : (loaded?.metadata.name.trim().isNotEmpty == true
                                ? loaded!.metadata.name.trim()
                                : '未命名文档');

                      final totalPdfPages = primarySummary?.placements.length ?? 0;
                      final notePages =
                          loaded?.data.getPages(true) ?? const <String>[];
                      final noteIdx = loaded != null
                          ? max(0, notePages.indexOf(loaded.pageName))
                          : 0;

                      return Row(
                        children: [
                          const SizedBox(width: 8),
                          _OpenMenuButton(palette: palette),
                          const SizedBox(width: 6),
                          _DocStatusPill(
                            palette: palette,
                            title: docTitle,
                            totalPdfPages: totalPdfPages,
                            noteIdx: noteIdx,
                            noteTotal: max(1, notePages.length),
                            primarySummary: primarySummary,
                            onOpenOverview: loaded == null
                                ? null
                                : () => unawaited(showPdfOverviewDialog(context)),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _ZoomPill(
                                    palette: palette,
                                    onZoomOut: () => _zoomBy(
                                      context,
                                      studyState,
                                      1 / 1.15,
                                    ),
                                    onZoomIn: () => _zoomBy(
                                      context,
                                      studyState,
                                      1.15,
                                    ),
                                    onFit: loaded == null
                                        ? null
                                        : () => _fitWidth(
                                            context,
                                            studyState,
                                            loaded,
                                            primarySummary,
                                          ),
                                  ),
                                  const SizedBox(width: 5),
                                  if (ocrCubit != null)
                                    BlocBuilder<OcrCubit, OcrState>(
                                      bloc: ocrCubit,
                                      buildWhen: (prev, curr) =>
                                          prev.whiteBgVisible !=
                                              curr.whiteBgVisible ||
                                          prev.completedPages !=
                                              curr.completedPages ||
                                          prev.isRunning != curr.isRunning,
                                      builder: (context, ocrState) =>
                                          _OcrLayerPill(
                                            palette: palette,
                                            active: ocrState.whiteBgVisible,
                                            count: ocrState.completedPages,
                                            running: ocrState.isRunning,
                                            onTap: ocrCubit.toggleWhiteBgLayer,
                                          ),
                                    )
                                  else
                                    _OcrLayerPill(
                                      palette: palette,
                                      active: false,
                                      count: 0,
                                      running: false,
                                      onTap: null,
                                    ),
                                  const SizedBox(width: 5),
                                  _HeaderActionChip(
                                    palette: palette,
                                    icon: PhosphorIconsLight.selection,
                                    label: '截取',
                                    shortcut: 'R',
                                    active: studyState.aiSnippingMode,
                                    tooltip: '区域框选截取（R）',
                                    onTap: loaded == null
                                        ? null
                                        : () => studyCubit.setAiSnippingMode(
                                            !studyState.aiSnippingMode,
                                          ),
                                  ),
                                  const SizedBox(width: 5),
                                  _HeaderActionChip(
                                    palette: palette,
                                    icon: PhosphorIconsLight.magnifyingGlass,
                                    label: '搜索',
                                    shortcut: 'F',
                                    active:
                                        studyState.inspectorOpen &&
                                        studyState.studyPanelOpen &&
                                        studyState.activeTab ==
                                            StudyPanelTab.search,
                                    tooltip: '全文 / OCR 识别文字搜索（F）',
                                    onTap: loaded == null
                                        ? null
                                        : () {
                                            studyCubit.setInspectorOpen(true);
                                            studyCubit.openStudyPanel(
                                              StudyPanelTab.search,
                                            );
                                          },
                                  ),
                                  const SizedBox(width: 5),
                                  _HeaderActionChip(
                                    palette: palette,
                                    icon: PhosphorIconsLight.sparkle,
                                    label: 'API',
                                    shortcut: '',
                                    active: studyState.aiConfig.isConfigured,
                                    tooltip: studyState.aiConfig.isConfigured
                                        ? 'OpenAI API 已配置 (${studyState.aiConfig.effectiveVisionModel})，点击调整'
                                        : '配置 OpenAI 格式 API 接口',
                                    onTap: () => unawaited(
                                      showOpenAiApiSettingsDialog(context),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          _WorkspaceModeToggle(
                            palette: palette,
                            mode: studyState.workspaceMode,
                            excerptCount: studyState.canvasExcerptCount,
                            onChanged: studyCubit.setWorkspaceMode,
                          ),
                          const SizedBox(width: 4),
                          _HeaderIconBtn(
                            palette: palette,
                            tooltip:
                                '阅读版式：${studyState.pdfCrop.layoutMode.label}',
                            icon: studyState.pdfCrop.layoutMode ==
                                    PdfViewLayoutMode.singlePage
                                ? PhosphorIconsLight.rows
                                : PhosphorIconsLight.columns,
                            active: studyState.pdfCrop.layoutMode !=
                                PdfViewLayoutMode.singlePage,
                            onPressed: () => _cycleBookLayout(
                              context,
                              studyCubit,
                              studyState,
                              primarySummary,
                            ),
                          ),
                          _HeaderIconBtn(
                            palette: palette,
                            tooltip:
                                '滤镜模式：${studyState.colorMode.displayName}',
                            icon: studyState.colorMode.index == 0
                                ? PhosphorIconsLight.sun
                                : PhosphorIconsLight.moon,
                            active: studyState.colorMode.index != 0,
                            onPressed: studyCubit.cycleColorMode,
                          ),
                          if (maybeMultiPdfWindowCubit(context)
                              case final winCubit?)
                            BlocBuilder<
                              MultiPdfWindowCubit,
                              MultiPdfWindowState
                            >(
                              bloc: winCubit,
                              builder: (context, winState) => _HeaderIconBtn(
                                palette: palette,
                                tooltip:
                                    '多 PDF 悬浮窗 (${winState.windows.length})',
                                icon: PhosphorIconsLight.appWindow,
                                active: winState.windows.any(
                                  (w) => !w.minimized,
                                ),
                                onPressed: () =>
                                    openMultiPdfWindowEntry(context),
                              ),
                            ),
                          if (maybeLanSyncCubit(context) case final lanCubit?)
                            BlocBuilder<LanSyncCubit, LanSyncState>(
                              bloc: lanCubit,
                              builder: (context, lanState) {
                                final online =
                                    lanState.account.isSignedIn &&
                                    lanState.peers.isNotEmpty;
                                final signedIn = lanState.account.isSignedIn;
                                return _HeaderIconBtn(
                                  palette: palette,
                                  tooltip: !signedIn
                                      ? '局域网双端同步账号'
                                      : online
                                      ? '局域网已连接 ${lanState.peers.length} 台设备'
                                      : '局域网同步监听中',
                                  icon: online
                                      ? PhosphorIconsLight.cloud
                                      : PhosphorIconsLight.wifiHigh,
                                  active: online,
                                  onPressed: () => unawaited(
                                    showLanSyncDialog(context),
                                  ),
                                );
                              },
                            ),
                          MenuAnchor(
                            builder: (context, controller, child) =>
                                _HeaderIconBtn(
                                  palette: palette,
                                  tooltip: '帮助、API 与界面切换',
                                  icon: PhosphorIconsLight.question,
                                  active: false,
                                  onPressed: () => controller.isOpen
                                      ? controller.close()
                                      : controller.open(),
                                ),
                            menuChildren: [
                              MenuItemButton(
                                leadingIcon: const PhosphorIcon(
                                  PhosphorIconsLight.sparkle,
                                ),
                                onPressed: () => unawaited(
                                  showOpenAiApiSettingsDialog(context),
                                ),
                                child: const Text('配置 OpenAI 格式 API 接口'),
                              ),
                              MenuItemButton(
                                leadingIcon: const PhosphorIcon(
                                  PhosphorIconsLight.info,
                                ),
                                onPressed: () =>
                                    _showShortcutHelpDialog(context),
                                child: const Text('快捷键与功能说明'),
                              ),
                              MenuItemButton(
                                leadingIcon: const PhosphorIcon(
                                  PhosphorIconsLight.slidersHorizontal,
                                ),
                                onPressed: () =>
                                    studyCubit.setYingPdfStyle(false),
                                child: const Text('切换经典 Butterfly 界面'),
                              ),
                            ],
                          ),
                          _HeaderIconBtn(
                            palette: palette,
                            tooltip: studyState.inspectorOpen
                                ? '收起右侧检查器'
                                : '展开右侧检查器',
                            icon: studyState.inspectorOpen
                                ? PhosphorIconsLight.caretRight
                                : PhosphorIconsLight.caretLeft,
                            active: studyState.inspectorOpen,
                            onPressed: studyCubit.toggleInspectorOpen,
                          ),
                          if (isWindow && !inView && !nativeTitleBar) ...[
                            const SizedBox(width: 4),
                            const WindowButtons<
                              SettingsCubit,
                              ButterflySettings
                            >(height: 40),
                          ] else
                            const SizedBox(width: 6),
                        ],
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OpenMenuButton extends StatelessWidget {
  final YingPdfPalette palette;

  const _OpenMenuButton({required this.palette});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, _) => Material(
        color: palette.accentBerry,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PhosphorIcon(
                  PhosphorIconsLight.folderOpen,
                  size: 15,
                  color: Colors.white,
                ),
                SizedBox(width: 6),
                Text(
                  '打开',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const PhosphorIcon(PhosphorIconsLight.filePdf),
          onPressed: () => unawaited(
            showImportAssetWizard(
              ImportType.pdf,
              context,
              context.read<DocumentBloc>(),
              context.read<ImportService>(),
            ),
          ),
          child: const Text('导入 PDF 文档'),
        ),
        MenuItemButton(
          leadingIcon: const PhosphorIcon(PhosphorIconsLight.image),
          onPressed: () => unawaited(
            showImportAssetWizard(
              ImportType.image,
              context,
              context.read<DocumentBloc>(),
              context.read<ImportService>(),
            ),
          ),
          child: const Text('导入图片'),
        ),
        if (maybeMultiPdfWindowCubit(context) != null)
          MenuItemButton(
            leadingIcon: const PhosphorIcon(PhosphorIconsLight.appWindow),
            onPressed: () => openMultiPdfWindowEntry(context),
            child: const Text('打开多 PDF 悬浮窗'),
          ),
        MenuItemButton(
          leadingIcon: const PhosphorIcon(PhosphorIconsLight.download),
          onPressed: () => unawaited(context.read<DocumentBloc>().save()),
          child: const Text('保存当前笔记'),
        ),
        MenuItemButton(
          leadingIcon: const PhosphorIcon(PhosphorIconsLight.house),
          onPressed: () async {
            final router = GoRouter.of(context);
            await context.read<DocumentBloc>().save();
            if (!context.mounted) return;
            if (router.canPop()) {
              router.pop();
            } else {
              router.go('/');
            }
          },
          child: const Text('返回文件库主页'),
        ),
      ],
    );
  }
}

class _DocStatusPill extends StatelessWidget {
  final YingPdfPalette palette;
  final String title;
  final int totalPdfPages;
  final int noteIdx;
  final int noteTotal;
  final PdfSourceSummary? primarySummary;
  final VoidCallback? onOpenOverview;

  const _DocStatusPill({
    required this.palette,
    required this.title,
    required this.totalPdfPages,
    required this.noteIdx,
    required this.noteTotal,
    required this.primarySummary,
    required this.onOpenOverview,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 235),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: palette.pillSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: palette.accentBerry,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.inkPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (primarySummary != null && totalPdfPages > 0)
            BlocSelector<TransformCubit, CameraTransform, int>(
              selector: (_) => PdfCanvasReflowService.detectCurrentPageIndex(
                context,
                primarySummary!,
              ),
              builder: (_, currentPdfIdx) => Text(
                '第 ${currentPdfIdx + 1}/$totalPdfPages 页',
                style: TextStyle(
                  color: palette.inkSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          else
            Text(
              '第 ${noteIdx + 1}/$noteTotal 页',
              style: TextStyle(
                color: palette.inkSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          const SizedBox(width: 5),
          InkWell(
            onTap: onOpenOverview,
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Tooltip(
                message: '全屏多页总览',
                child: PhosphorIcon(
                  PhosphorIconsLight.squaresFour,
                  size: 14,
                  color: palette.inkSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ZoomPill extends StatelessWidget {
  final YingPdfPalette palette;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback? onFit;

  const _ZoomPill({
    required this.palette,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: palette.controlSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SmallHeaderTap(
            onTap: onZoomOut,
            tooltip: '缩小',
            child: PhosphorIcon(
              PhosphorIconsLight.minus,
              size: 13,
              color: palette.inkSecondary,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: BlocSelector<TransformCubit, CameraTransform, int>(
              selector: (t) => (t.size * 100).round(),
              builder: (_, zoomPercent) => Text(
                '$zoomPercent%',
                style: TextStyle(
                  color: palette.inkPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _SmallHeaderTap(
            onTap: onZoomIn,
            tooltip: '放大',
            child: PhosphorIcon(
              PhosphorIconsLight.plus,
              size: 13,
              color: palette.inkSecondary,
            ),
          ),
          Container(
            width: 1,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            color: palette.borderSubtle,
          ),
          _SmallHeaderTap(
            onTap: onFit,
            tooltip: '适应页面宽度',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PhosphorIcon(
                  PhosphorIconsLight.frameCorners,
                  size: 13,
                  color: palette.inkSecondary,
                ),
                const SizedBox(width: 4),
                Text(
                  '适应',
                  style: TextStyle(
                    color: palette.inkPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OcrLayerPill extends StatelessWidget {
  final YingPdfPalette palette;
  final bool active;
  final int count;
  final bool running;
  final VoidCallback? onTap;

  const _OcrLayerPill({
    required this.palette,
    required this.active,
    required this.count,
    required this.running,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '切换 OCR 白底重排文字层（T）',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: active ? palette.accentSoft : palette.controlSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? palette.accentBerry : palette.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PhosphorIcon(
                PhosphorIconsLight.textT,
                size: 14,
                color: active ? palette.accentBerryDark : palette.inkSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                '文字层',
                style: TextStyle(
                  color: active ? palette.accentBerryDark : palette.inkPrimary,
                  fontSize: 12,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
              const SizedBox(width: 5),
              _ShortcutKbd(palette: palette, text: 'T'),
              const SizedBox(width: 5),
              Text(
                running ? '$count…' : '$count',
                style: TextStyle(
                  color: palette.accentBerry,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderActionChip extends StatelessWidget {
  final YingPdfPalette palette;
  final PhosphorIconData icon;
  final String label;
  final String shortcut;
  final bool active;
  final String tooltip;
  final VoidCallback? onTap;

  const _HeaderActionChip({
    required this.palette,
    required this.icon,
    required this.label,
    required this.shortcut,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: active ? palette.accentSoft : palette.controlSurface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? palette.accentBerry : palette.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PhosphorIcon(
                icon,
                size: 14,
                color: active ? palette.accentBerryDark : palette.inkSecondary,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: active ? palette.accentBerryDark : palette.inkPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (shortcut.isNotEmpty) ...[
                const SizedBox(width: 5),
                _ShortcutKbd(palette: palette, text: shortcut),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceModeToggle extends StatelessWidget {
  final YingPdfPalette palette;
  final StudyWorkspaceMode mode;
  final int excerptCount;
  final ValueChanged<StudyWorkspaceMode> onChanged;

  const _WorkspaceModeToggle({
    required this.palette,
    required this.mode,
    required this.excerptCount,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.pillSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _WorkspaceTab(
            palette: palette,
            selected: mode == StudyWorkspaceMode.reading,
            icon: PhosphorIconsLight.bookOpen,
            label: '阅读',
            badgeCount: null,
            onTap: () => onChanged(StudyWorkspaceMode.reading),
          ),
          _WorkspaceTab(
            palette: palette,
            selected: mode == StudyWorkspaceMode.canvas,
            icon: PhosphorIconsLight.paintBrush,
            label: '画布',
            badgeCount: excerptCount > 0 ? excerptCount : null,
            onTap: () => onChanged(StudyWorkspaceMode.canvas),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceTab extends StatelessWidget {
  final YingPdfPalette palette;
  final bool selected;
  final PhosphorIconData icon;
  final String label;
  final int? badgeCount;
  final VoidCallback onTap;

  const _WorkspaceTab({
    required this.palette,
    required this.selected,
    required this.icon,
    required this.label,
    required this.badgeCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? palette.controlSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhosphorIcon(
              icon,
              size: 13,
              color: selected ? palette.inkPrimary : palette.inkSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: selected ? palette.inkPrimary : palette.inkSecondary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (badgeCount != null) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: palette.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$badgeCount',
                  style: TextStyle(
                    color: palette.accentBerryDark,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderIconBtn extends StatelessWidget {
  final YingPdfPalette palette;
  final String tooltip;
  final PhosphorIconData icon;
  final bool active;
  final VoidCallback onPressed;

  const _HeaderIconBtn({
    required this.palette,
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(7),
        child: Container(
          width: 30,
          height: 30,
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: active ? palette.accentSoft : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Center(
            child: PhosphorIcon(
              icon,
              size: 16,
              color: active ? palette.accentBerryDark : palette.inkSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SmallHeaderTap extends StatelessWidget {
  final VoidCallback? onTap;
  final String tooltip;
  final Widget child;

  const _SmallHeaderTap({
    required this.onTap,
    required this.tooltip,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          child: child,
        ),
      ),
    );
  }
}

class _ShortcutKbd extends StatelessWidget {
  final YingPdfPalette palette;
  final String text;

  const _ShortcutKbd({required this.palette, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: palette.pillSurface,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: palette.inkSecondary,
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  final String keys;
  final String desc;

  const _ShortcutRow({required this.keys, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 72,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: ColorScheme.of(context).surfaceContainerHigh,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              keys,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(desc, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }
}
