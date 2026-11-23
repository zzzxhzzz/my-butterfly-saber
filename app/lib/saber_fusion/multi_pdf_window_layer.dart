import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/api/file_system.dart';
import 'package:butterfly/api/open.dart';
import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/editor_controller.dart';
import 'package:butterfly/helpers/element.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lw_file_system/lw_file_system.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'color_filters.dart';
import 'multi_pdf_window_cubit.dart';
import 'pdf_reading_models.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';

DocumentBloc? _maybeDocumentBloc(BuildContext context) {
  try {
    return BlocProvider.of<DocumentBloc>(context);
  } catch (_) {
    return null;
  }
}

EditorController? _maybeEditorController(BuildContext context) {
  try {
    return BlocProvider.of<EditorController>(context);
  } catch (_) {
    return null;
  }
}

Future<void> pickAndOpenLocalPdfWindows(BuildContext context) async {
  final windowCubit = maybeMultiPdfWindowCubit(context);
  if (windowCubit == null) return;
  final viewportSize = MediaQuery.sizeOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);

  final picked = await importFilesWithExtensions(
    const ['pdf', 'bfly'],
    multiple: true,
  );
  if (picked.isEmpty) return;

  var skipped = 0;
  for (final (bytes, ext, baseName) in picked) {
    final lowerExt = ext.toLowerCase();
    if (lowerExt == 'pdf') {
      windowCubit.openPdfBytes(
        title: '$baseName.pdf',
        bytes: bytes,
        viewportSize: viewportSize,
      );
    } else if (lowerExt == 'bfly') {
      final ok = windowCubit.openFromBflyBytes(
        title: baseName,
        bflyBytes: bytes,
        viewportSize: viewportSize,
      );
      if (!ok) skipped++;
    }
  }

  if (skipped > 0) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text('有 $skipped 个 .bfly 笔记内不含 PDF（纯手写笔记暂不支持独立 PDF 窗预览）'),
      ),
    );
  }
}

void openMultiPdfWindowEntry(BuildContext context) {
  final windowCubit = maybeMultiPdfWindowCubit(context);
  if (windowCubit == null) return;
  if (windowCubit.state.windows.isEmpty) {
    windowCubit.showDock();
    unawaited(showLibraryWindowPickerDialog(context));
    return;
  }
  if (!windowCubit.state.dockVisible) {
    windowCubit.showDock();
    return;
  }
  if (windowCubit.state.windows.every((w) => w.minimized)) {
    windowCubit.restoreAll();
    return;
  }
  windowCubit.toggleDock();
}

Future<void> openCurrentDocumentAsWindow(BuildContext context) async {
  final windowCubit = maybeMultiPdfWindowCubit(context);
  final docBloc = _maybeDocumentBloc(context);
  if (windowCubit == null || docBloc == null) return;
  final docState = docBloc.state;
  if (docState is! DocumentLoadSuccess) return;

  final viewportSize = MediaQuery.sizeOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final saveLocation = _maybeEditorController(context)?.saveCubit.state.location;
  final summaries = PdfStudyService.indexDocumentPdfs(docState);
  if (summaries.isEmpty) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('当前文档暂未导入 PDF，可通过「+ 本地PDF」或「+ 笔记库」打开')),
    );
    windowCubit.showDock();
    return;
  }

  final summary = summaries.first;
  final bytes = getDataFromSource(docState.data, summary.source);
  if (bytes == null || bytes.isEmpty) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('无法读取当前文档的内置 PDF 数据')),
    );
    return;
  }

  String? diskPath;
  if (!kIsWeb && saveLocation != null && !saveLocation.isRemote) {
    if (saveLocation.absolute) {
      diskPath = saveLocation.path;
    } else if (saveLocation.path.isNotEmpty) {
      final root = await getButterflyDocumentsDirectory();
      final rel = saveLocation.pathWithoutLeadingSlash
          .replaceAll('/', Platform.pathSeparator);
      final candidate = File(
        '$root${Platform.pathSeparator}$rel.bfly',
      );
      if (await candidate.exists()) {
        diskPath = candidate.path;
      }
    }
  }

  final title = docState.metadata.name.isNotEmpty
      ? docState.metadata.name
      : summary.displayName;
  windowCubit.openPdfBytes(
    title: title,
    bytes: bytes,
    diskPath: diskPath,
    assetLocation: saveLocation,
    viewportSize: viewportSize,
  );
}

Future<void> showLibraryWindowPickerDialog(BuildContext context) async {
  final windowCubit = maybeMultiPdfWindowCubit(context);
  if (windowCubit == null) return;
  final viewportSize = MediaQuery.sizeOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);

  final entries = <_LibraryFileEntry>[];
  if (!kIsWeb) {
    try {
      final rootPath = await getButterflyDocumentsDirectory();
      final rootDir = Directory(rootPath);
      if (await rootDir.exists()) {
        await for (final entity in rootDir.list(recursive: true)) {
          if (entity is! File) continue;
          final lower = entity.path.toLowerCase();
          if (!lower.endsWith('.bfly') && !lower.endsWith('.pdf')) continue;
          if (entity.path.contains('.conflict-')) continue;
          final stat = await entity.stat();
          var rel = entity.path
              .substring(rootDir.path.length)
              .replaceAll('\\', '/');
          if (rel.startsWith('/')) rel = rel.substring(1);
          final display = rel.endsWith('.bfly')
              ? rel.substring(0, rel.length - 5)
              : rel;
          entries.add(
            _LibraryFileEntry(
              file: entity,
              relativePath: rel,
              displayName: display,
              isPdf: lower.endsWith('.pdf'),
              modified: stat.modified,
            ),
          );
        }
        entries.sort((a, b) => b.modified.compareTo(a.modified));
      }
    } catch (_) {}
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Row(
        children: [
          PhosphorIcon(PhosphorIconsLight.appWindow, size: 20),
          SizedBox(width: 8),
          Expanded(child: Text('从笔记库打开小窗（多 PDF 窗口化）')),
        ],
      ),
      content: SizedBox(
        width: 460,
        height: 400,
        child: entries.isEmpty
            ? const Center(
                child: Text(
                  '本地笔记库中暂无 .bfly 或 .pdf 文件。\n可点击下方「选择电脑/平板本地 PDF」直接打开。',
                  textAlign: TextAlign.center,
                ),
              )
            : ListView.separated(
                itemCount: entries.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (itemContext, index) {
                  final item = entries[index];
                  return ListTile(
                    leading: PhosphorIcon(
                      item.isPdf
                          ? PhosphorIconsLight.filePdf
                          : PhosphorIconsLight.notebook,
                    ),
                    title: Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(item.isPdf ? 'PDF 文档' : 'Butterfly 笔记（含导入 PDF）'),
                    onTap: () async {
                      Navigator.of(dialogContext).pop();
                      try {
                        final bytes = await item.file.readAsBytes();
                        if (item.isPdf) {
                          windowCubit.openPdfBytes(
                            title: item.displayName,
                            bytes: bytes,
                            diskPath: item.file.path,
                            viewportSize: viewportSize,
                          );
                        } else {
                          final relNoExt = item.relativePath.endsWith('.bfly')
                              ? item.relativePath.substring(
                                  0,
                                  item.relativePath.length - 5,
                                )
                              : item.relativePath;
                          final ok = windowCubit.openFromBflyBytes(
                            title: item.displayName,
                            bflyBytes: bytes,
                            diskPath: item.file.path,
                            assetLocation: AssetLocation.local('/$relNoExt'),
                            viewportSize: viewportSize,
                          );
                          if (!ok) {
                            messenger?.showSnackBar(
                              const SnackBar(
                                content: Text('该笔记不含内置 PDF；已为您打开或保留主画布编辑'),
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        messenger?.showSnackBar(
                          SnackBar(content: Text('打开失败：$e')),
                        );
                      }
                    },
                  );
                },
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            unawaited(pickAndOpenLocalPdfWindows(context));
          },
          icon: const PhosphorIcon(PhosphorIconsLight.folderOpen, size: 16),
          label: const Text('浏览本地 PDF / .bfly'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

Future<void> launchIndependentOsWindow(
  BuildContext context,
  PdfWindowSession session,
) async {
  if (kIsWeb || !Platform.isWindows) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    var pathToOpen = session.diskPath;
    if (pathToOpen == null || pathToOpen.isEmpty) {
      final tmpFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}butterfly_win_${session.id}.pdf',
      );
      await tmpFile.writeAsBytes(session.pdfBytes, flush: true);
      pathToOpen = tmpFile.path;
    }
    final args = <String>[
      if (overrideButterflyDirectory != null &&
          overrideButterflyDirectory!.isNotEmpty) ...[
        '--path',
        overrideButterflyDirectory!,
      ],
      pathToOpen,
    ];
    await Process.start(
      Platform.resolvedExecutable,
      args,
      mode: ProcessStartMode.detached,
    );
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(content: Text('启动独立窗口失败：$e')),
    );
  }
}

class _LibraryFileEntry {
  final File file;
  final String relativePath;
  final String displayName;
  final bool isPdf;
  final DateTime modified;

  const _LibraryFileEntry({
    required this.file,
    required this.relativePath,
    required this.displayName,
    required this.isPdf,
    required this.modified,
  });
}

class MultiPdfWindowLayer extends StatelessWidget {
  const MultiPdfWindowLayer({super.key});

  @override
  Widget build(BuildContext context) {
    final windowCubit = maybeMultiPdfWindowCubit(context);
    if (windowCubit == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = constraints.biggest;
        return BlocBuilder<MultiPdfWindowCubit, MultiPdfWindowState>(
          bloc: windowCubit,
          builder: (context, state) {
            if (!state.dockVisible && state.windows.isEmpty) {
              return const SizedBox.shrink();
            }

            final visibleWindows = state.windows
                .where((w) => !w.minimized)
                .toList()
              ..sort((a, b) {
                if (a.pinned != b.pinned) return a.pinned ? 1 : -1;
                return a.zOrder.compareTo(b.zOrder);
              });

            return Stack(
              fit: StackFit.expand,
              children: [
                for (final session in visibleWindows)
                  Positioned(
                    key: ValueKey('pdf_win_${session.id}'),
                    left: session.offset.dx,
                    top: session.offset.dy,
                    width: session.size.width,
                    height: session.size.height,
                    child: _FloatingPdfWindowCard(
                      key: ValueKey('pdf_win_card_${session.id}'),
                      session: session,
                      viewportBounds: viewportSize,
                    ),
                  ),
                Align(
                  alignment: Alignment.bottomLeft,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                      child: _QqWindowDockBar(
                        state: state,
                        viewportSize: viewportSize,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _QqWindowDockBar extends StatelessWidget {
  final MultiPdfWindowState state;
  final Size viewportSize;

  const _QqWindowDockBar({
    required this.state,
    required this.viewportSize,
  });

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MultiPdfWindowCubit>();
    final colorScheme = ColorScheme.of(context);
    final hasDocBloc = _maybeDocumentBloc(context)?.state is DocumentLoadSuccess;
    final allMinimized =
        state.windows.isNotEmpty && state.windows.every((w) => w.minimized);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: max(280.0, viewportSize.width - 24)),
      child: Card.outlined(
        elevation: 8,
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PhosphorIcon(
                  PhosphorIconsLight.appWindow,
                  size: 18,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  '多窗 PDF',
                  style: TextTheme.of(context).labelLarge?.copyWith(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                for (final w in state.windows) ...[
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        if (w.minimized) {
                          cubit.focusWindow(w.id);
                        } else {
                          cubit.toggleMinimize(w.id);
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: w.minimized
                              ? colorScheme.surfaceContainerHighest
                              : colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: w.minimized
                                ? colorScheme.outlineVariant
                                : colorScheme.primary,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (w.pinned) ...[
                              PhosphorIcon(
                                PhosphorIconsFill.pushPin,
                                size: 12,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 3),
                            ],
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 110),
                              child: Text(
                                w.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextTheme.of(context).labelSmall?.copyWith(
                                  color: w.minimized
                                      ? colorScheme.onSurfaceVariant
                                      : colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                            if (w.totalPages > 0) ...[
                              const SizedBox(width: 4),
                              Text(
                                'P${w.currentPage + 1}',
                                style: TextTheme.of(context).labelSmall?.copyWith(
                                  fontSize: 10,
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () => cubit.closeWindow(w.id),
                              child: const PhosphorIcon(
                                PhosphorIconsLight.x,
                                size: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(
                  height: 20,
                  child: VerticalDivider(width: 8),
                ),
                ActionChip(
                  avatar: const PhosphorIcon(
                    PhosphorIconsLight.plus,
                    size: 14,
                  ),
                  label: const Text('本地PDF'),
                  onPressed: () =>
                      unawaited(pickAndOpenLocalPdfWindows(context)),
                ),
                const SizedBox(width: 4),
                ActionChip(
                  avatar: const PhosphorIcon(
                    PhosphorIconsLight.folderOpen,
                    size: 14,
                  ),
                  label: const Text('笔记库'),
                  onPressed: () =>
                      unawaited(showLibraryWindowPickerDialog(context)),
                ),
                if (hasDocBloc) ...[
                  const SizedBox(width: 4),
                  ActionChip(
                    avatar: const PhosphorIcon(
                      PhosphorIconsLight.filePdf,
                      size: 14,
                    ),
                    label: const Text('当前PDF'),
                    onPressed: () =>
                        unawaited(openCurrentDocumentAsWindow(context)),
                  ),
                ],
                if (state.windows.length >= 2)
                  IconButton(
                    tooltip: '并排平铺所有小窗',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => cubit.tileWindows(viewportSize),
                    icon: const PhosphorIcon(
                      PhosphorIconsLight.gridFour,
                      size: 18,
                    ),
                  ),
                if (state.windows.isNotEmpty)
                  IconButton(
                    tooltip: allMinimized ? '展开全部小窗' : '全部最小化到任务栏',
                    visualDensity: VisualDensity.compact,
                    onPressed: allMinimized ? cubit.restoreAll : cubit.minimizeAll,
                    icon: PhosphorIcon(
                      allMinimized
                          ? PhosphorIconsLight.arrowsOutSimple
                          : PhosphorIconsLight.minus,
                      size: 18,
                    ),
                  ),
                IconButton(
                  tooltip: state.windows.isEmpty ? '收起多窗栏' : '关闭全部小窗',
                  visualDensity: VisualDensity.compact,
                  onPressed:
                      state.windows.isEmpty ? cubit.hideDock : cubit.closeAll,
                  icon: const PhosphorIcon(PhosphorIconsLight.x, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingPdfWindowCard extends StatefulWidget {
  final PdfWindowSession session;
  final Size viewportBounds;

  const _FloatingPdfWindowCard({
    super.key,
    required this.session,
    required this.viewportBounds,
  });

  @override
  State<_FloatingPdfWindowCard> createState() => _FloatingPdfWindowCardState();
}

class _FloatingPdfWindowCardState extends State<_FloatingPdfWindowCard> {
  static const int _maxWindowThumbs = 20;

  PdfDocument? _pdfDoc;
  bool _loadingDoc = true;
  String? _loadError;

  final ScrollController _scrollCtrl = ScrollController();
  final Map<int, ui.Image> _pageCache = {};
  final Set<int> _pendingPages = {};
  final List<int> _pageLru = [];

  @override
  void initState() {
    super.initState();
    unawaited(_openDoc());
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _clearPageCache(deferDispose: false);
    unawaited(_pdfDoc?.dispose());
    _pdfDoc = null;
    super.dispose();
  }

  void _clearPageCache({bool deferDispose = true}) {
    final imgs = _pageCache.values.toList();
    _pageCache.clear();
    _pendingPages.clear();
    _pageLru.clear();
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

  Future<void> _openDoc() async {
    try {
      final doc = await PdfDocument.openData(widget.session.pdfBytes);
      if (!mounted) {
        await doc.dispose();
        return;
      }
      _pdfDoc = doc;
      setState(() {
        _loadingDoc = false;
        _loadError = null;
      });
      if (mounted) {
        context.read<MultiPdfWindowCubit>().setPage(
          widget.session.id,
          widget.session.currentPage,
          totalPages: doc.pages.length,
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingDoc = false;
        _loadError = e.toString();
      });
    }
  }

  ui.Image? _pageImageFor(int pageIdx) {
    final cached = _pageCache[pageIdx];
    if (cached != null) {
      _pageLru.remove(pageIdx);
      _pageLru.add(pageIdx);
      return cached;
    }
    _requestPageImage(pageIdx);
    return null;
  }

  void _requestPageImage(int pageIdx) {
    final doc = _pdfDoc;
    if (doc == null ||
        _pendingPages.contains(pageIdx) ||
        pageIdx < 0 ||
        pageIdx >= doc.pages.length) {
      return;
    }
    _pendingPages.add(pageIdx);
    () async {
      try {
        final page = doc.pages[pageIdx];
        final targetMax = 1000.0 * widget.session.zoom.clamp(0.8, 1.8);
        final scale = min(2.0, targetMax / max(page.width, page.height));
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
        _pageCache[pageIdx] = image;
        _pageLru.remove(pageIdx);
        _pageLru.add(pageIdx);
        while (_pageLru.length > _maxWindowThumbs) {
          final evicted = _pageLru.removeAt(0);
          final old = _pageCache.remove(evicted);
          if (old != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
        }
        setState(() {});
      } catch (_) {
      } finally {
        _pendingPages.remove(pageIdx);
      }
    }();
  }

  void _stepPage(int delta) {
    final doc = _pdfDoc;
    if (doc == null || doc.pages.isEmpty) return;
    final cubit = context.read<MultiPdfWindowCubit>();
    final step = widget.session.twoPageMode ? delta * 2 : delta;
    final nextPage = (widget.session.currentPage + step).clamp(
      0,
      doc.pages.length - 1,
    );
    cubit.setPage(widget.session.id, nextPage, totalPages: doc.pages.length);
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.jumpTo(0);
    }
  }

  Future<void> _showQuickPageJumpDialog(BuildContext context) async {
    final doc = _pdfDoc;
    if (doc == null || doc.pages.isEmpty) return;
    final cubit = context.read<MultiPdfWindowCubit>();
    final ctrl = TextEditingController(
      text: '${widget.session.currentPage + 1}',
    );
    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('跳转到页面（共 ${doc.pages.length} 页）'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '目标页码',
            filled: true,
          ),
          onSubmitted: (raw) => Navigator.of(
            dialogContext,
          ).pop(int.tryParse(raw.trim())),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              dialogContext,
            ).pop(int.tryParse(ctrl.text.trim())),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result != null) {
      cubit.setPage(
        widget.session.id,
        (result - 1).clamp(0, doc.pages.length - 1),
        totalPages: doc.pages.length,
      );
    }
  }

  Future<void> _switchToMainCanvas(BuildContext context) async {
    final s = widget.session;
    if (s.assetLocation != null && s.assetLocation!.path.isNotEmpty) {
      await openFile(context, true, s.assetLocation!);
      return;
    }
    if (s.diskPath != null && s.diskPath!.isNotEmpty) {
      await openFile(
        context,
        true,
        AssetLocation.local(s.diskPath!).copyWith(absolute: true),
      );
      return;
    }
    final docBloc = _maybeDocumentBloc(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (docBloc == null) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('请先新建或打开一篇笔记，再使用悬浮窗「+ 本地PDF」导入')),
      );
      return;
    }
    messenger?.showSnackBar(
      const SnackBar(content: Text('该外部 PDF 仅打开于小窗模式；如需批注请使用顶部「+ -> 导入」')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<MultiPdfWindowCubit>();
    final colorScheme = ColorScheme.of(context);
    final studyState = maybeStudyModeCubit(context)?.state;
    final cropConfig = widget.session.applyGlobalCrop && studyState != null
        ? studyState.pdfCrop
        : const PdfMarginCropConfig.vanilla();
    final filter = studyState != null
        ? canvasColorFilterFor(studyState.colorMode)
        : null;
    final session = widget.session;
    final canSwitchMain =
        session.assetLocation != null ||
        (session.diskPath != null && session.diskPath!.isNotEmpty);

    return Opacity(
      opacity: session.opacity,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) => cubit.focusWindow(session.id),
        child: Material(
          elevation: 14,
          borderRadius: BorderRadius.circular(12),
          color: colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: session.pinned
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
                width: session.pinned ? 1.5 : 1.0,
              ),
            ),
            child: Stack(
              children: [
                Column(
                  children: [
                    GestureDetector(
                      onPanStart: (_) => cubit.focusWindow(session.id),
                      onPanUpdate: (details) => cubit.moveWindow(
                        session.id,
                        details.delta,
                        widget.viewportBounds,
                      ),
                      child: Container(
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          border: Border(
                            bottom: BorderSide(
                              color: colorScheme.outlineVariant,
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            PhosphorIcon(
                              PhosphorIconsLight.filePdf,
                              size: 16,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                session.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextTheme.of(context).labelLarge,
                              ),
                            ),
                            IconButton(
                              tooltip:
                                  session.twoPageMode ? '窗口内切为单页' : '窗口内切为书本双页',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              isSelected: session.twoPageMode,
                              onPressed: () => cubit.toggleTwoPage(session.id),
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.columns,
                                size: 15,
                              ),
                            ),
                            IconButton(
                              tooltip:
                                  session.applyGlobalCrop ? '已应用全局页边距裁剪' : '未应用裁剪',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              isSelected: session.applyGlobalCrop,
                              onPressed: () =>
                                  cubit.toggleApplyCrop(session.id),
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.crop,
                                size: 15,
                              ),
                            ),
                            IconButton(
                              tooltip:
                                  '窗口透明度 ${(session.opacity * 100).round()}%',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              onPressed: () => cubit.cycleOpacity(session.id),
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.drop,
                                size: 15,
                              ),
                            ),
                            IconButton(
                              tooltip: session.pinned ? '取消置顶' : '置顶此窗口',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              isSelected: session.pinned,
                              onPressed: () => cubit.togglePin(session.id),
                              icon: PhosphorIcon(
                                session.pinned
                                    ? PhosphorIconsFill.pushPin
                                    : PhosphorIconsLight.pushPin,
                                size: 15,
                              ),
                            ),
                            if (canSwitchMain)
                              IconButton(
                                tooltip: '切到主画布编辑批注',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 28,
                                  height: 28,
                                ),
                                onPressed: () =>
                                    unawaited(_switchToMainCanvas(context)),
                                icon: const PhosphorIcon(
                                  PhosphorIconsLight.arrowSquareIn,
                                  size: 15,
                                ),
                              ),
                            if (!kIsWeb && Platform.isWindows)
                              IconButton(
                                tooltip: '弹出独立系统窗口',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 28,
                                  height: 28,
                                ),
                                onPressed: () => unawaited(
                                  launchIndependentOsWindow(context, session),
                                ),
                                icon: const PhosphorIcon(
                                  PhosphorIconsLight.arrowSquareOut,
                                  size: 15,
                                ),
                              ),
                            IconButton(
                              tooltip: '最小化到多窗任务栏',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              onPressed: () => cubit.toggleMinimize(session.id),
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.minus,
                                size: 15,
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭小窗',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 28,
                                height: 28,
                              ),
                              onPressed: () => cubit.closeWindow(session.id),
                              icon: const PhosphorIcon(
                                PhosphorIconsLight.x,
                                size: 15,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        color: colorScheme.surfaceDim,
                        child: _buildBody(context, cropConfig, filter),
                      ),
                    ),
                    _buildFooterBar(context),
                  ],
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    onPanStart: (_) => cubit.focusWindow(session.id),
                    onPanUpdate: (details) => cubit.resizeWindow(
                      session.id,
                      details.delta,
                      widget.viewportBounds,
                    ),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpLeftDownRight,
                      child: Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.bottomRight,
                        padding: const EdgeInsets.all(3),
                        child: PhosphorIcon(
                          PhosphorIconsLight.arrowsOutSimple,
                          size: 13,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    PdfMarginCropConfig cropConfig,
    ColorFilter? filter,
  ) {
    if (_loadingDoc) {
      return const Center(child: CircularProgressIndicator());
    }
    final doc = _pdfDoc;
    if (_loadError != null || doc == null || doc.pages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('无法加载 PDF：${_loadError ?? '页面为空'}'),
        ),
      );
    }

    final safePage = widget.session.currentPage.clamp(0, doc.pages.length - 1);
    Widget viewer;
    if (widget.session.twoPageMode) {
      final hasRight = safePage + 1 < doc.pages.length;
      final spineGap = cropConfig.effectiveBookSpineGap;
      viewer = Center(
        child: Padding(
          padding: EdgeInsets.all(cropConfig.seamlessLongDoc ? 0.0 : 8.0),
          child: Transform.scale(
            scale: widget.session.zoom,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(
                  child: _buildWindowPageTile(doc, safePage, cropConfig),
                ),
                if (hasRight) ...[
                  if (spineGap > 0) SizedBox(width: spineGap),
                  Flexible(
                    child: _buildWindowPageTile(doc, safePage + 1, cropConfig),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    } else {
      viewer = SingleChildScrollView(
        controller: _scrollCtrl,
        padding: EdgeInsets.symmetric(
          vertical: cropConfig.seamlessLongDoc ? 0 : 8,
          horizontal: cropConfig.seamlessLongDoc ? 0 : 8,
        ),
        child: Center(
          child: FractionallySizedBox(
            widthFactor: (0.94 * widget.session.zoom).clamp(0.45, 2.2),
            child: Column(
              children: [
                for (var idx = safePage; idx < min(doc.pages.length, safePage + 8); idx++) ...[
                  if (idx > safePage && !cropConfig.seamlessLongDoc)
                    SizedBox(height: cropConfig.effectivePageGap.clamp(0, 48)),
                  _buildWindowPageTile(doc, idx, cropConfig),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (filter != null) {
      viewer = ColorFiltered(colorFilter: filter, child: viewer);
    }
    return viewer;
  }

  Widget _buildWindowPageTile(
    PdfDocument doc,
    int pageIdx,
    PdfMarginCropConfig cropConfig,
  ) {
    final page = doc.pages[pageIdx];
    final img = _pageImageFor(pageIdx);
    final l = cropConfig.effectiveLeftForPage(pageIdx);
    final r = cropConfig.effectiveRightForPage(pageIdx);
    final t = cropConfig.top;
    final b = cropConfig.bottom;
    final rawRatio = page.height > 0 && page.width > 0
        ? page.width / page.height
        : 0.707;
    final aspect = rawRatio * ((1.0 - l - r) / (1.0 - t - b)).clamp(0.3, 3.0);

    return AspectRatio(
      aspectRatio: aspect,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: cropConfig.effectiveShowShadow
              ? Border.all(color: const Color(0x22000000))
              : null,
          boxShadow: cropConfig.effectiveShowShadow
              ? const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 6,
                    offset: Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: img == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : CustomPaint(
                painter: _WindowPdfPagePainter(
                  image: img,
                  left: l,
                  top: t,
                  right: r,
                  bottom: b,
                ),
                child: const SizedBox.expand(),
              ),
      ),
    );
  }

  Widget _buildFooterBar(BuildContext context) {
    final cubit = context.read<MultiPdfWindowCubit>();
    final total = _pdfDoc?.pages.length ?? widget.session.totalPages;
    final current = total > 0
        ? widget.session.currentPage.clamp(0, total - 1)
        : 0;
    final zoomPct = (widget.session.zoom * 100).round();

    return Container(
      height: 36,
      padding: const EdgeInsets.only(left: 8, right: 24),
      decoration: BoxDecoration(
        color: ColorScheme.of(context).surfaceContainerLow,
        border: Border(
          top: BorderSide(color: ColorScheme.of(context).outlineVariant),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一页',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: current > 0 ? () => _stepPage(-1) : null,
            icon: const PhosphorIcon(PhosphorIconsLight.caretLeft, size: 15),
          ),
          TextButton(
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
            ),
            onPressed: total > 0
                ? () => unawaited(_showQuickPageJumpDialog(context))
                : null,
            child: Text(
              total > 0 ? '第 ${current + 1}/$total 页' : '...',
              style: TextTheme.of(context).labelSmall,
            ),
          ),
          IconButton(
            tooltip: '下一页',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: total > 0 && current < total - 1
                ? () => _stepPage(1)
                : null,
            icon: const PhosphorIcon(PhosphorIconsLight.caretRight, size: 15),
          ),
          const Spacer(),
          IconButton(
            tooltip: '缩小',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            onPressed: () =>
                cubit.setZoom(widget.session.id, widget.session.zoom - 0.15),
            icon: const PhosphorIcon(PhosphorIconsLight.minus, size: 14),
          ),
          Text('$zoomPct%', style: TextTheme.of(context).labelSmall),
          IconButton(
            tooltip: '放大',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 26, height: 26),
            onPressed: () =>
                cubit.setZoom(widget.session.id, widget.session.zoom + 0.15),
            icon: const PhosphorIcon(PhosphorIconsLight.plus, size: 14),
          ),
        ],
      ),
    );
  }
}

class _WindowPdfPagePainter extends CustomPainter {
  final ui.Image image;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const _WindowPdfPagePainter({
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
    canvas.drawImageRect(
      image,
      src,
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );
  }

  @override
  bool shouldRepaint(_WindowPdfPagePainter oldDelegate) =>
      !identical(image, oldDelegate.image) ||
      left != oldDelegate.left ||
      top != oldDelegate.top ||
      right != oldDelegate.right ||
      bottom != oldDelegate.bottom;
}
