import 'dart:async';
import 'dart:math';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/helpers/rect.dart';
import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';

import 'pdf_reading_models.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';

class PdfCanvasReflowService {
  const PdfCanvasReflowService._();

  static void toggleBookSpreadMode(BuildContext context) {
    final studyCubit = maybeStudyModeCubit(context);
    if (studyCubit == null) return;
    final current = studyCubit.state.pdfCrop;
    final nextMode = current.layoutMode == PdfViewLayoutMode.singlePage
        ? PdfViewLayoutMode.twoPageBook
        : PdfViewLayoutMode.singlePage;
    final nextConfig = current.copyWith(layoutMode: nextMode);
    studyCubit.updatePdfCrop(nextConfig, persist: true);

    try {
      final bloc = BlocProvider.of<DocumentBloc>(context);
      final docState = bloc.state;
      if (docState is DocumentLoadSuccess) {
        final summaries = PdfStudyService.indexDocumentPdfs(docState);
        if (summaries.isNotEmpty &&
            isSingleCanvasMultiPagePdf(docState, summaries.first)) {
          unawaited(
            reflowCurrentPage(context, summaries.first, nextConfig),
          );
        }
      }
    } catch (_) {}
  }

  static List<List<PdfPagePlacement>> buildSpreads(
    List<PdfPagePlacement> placements,
    PdfViewLayoutMode mode,
  ) {
    if (placements.isEmpty) return const [];
    final sorted = placements.toList()
      ..sort((a, b) => a.pdfPageIndex.compareTo(b.pdfPageIndex));
    if (mode == PdfViewLayoutMode.singlePage) {
      return [
        for (final p in sorted) [p],
      ];
    }
    final spreads = <List<PdfPagePlacement>>[];
    var idx = 0;
    if (mode == PdfViewLayoutMode.twoPageCover && sorted.isNotEmpty) {
      spreads.add([sorted.first]);
      idx = 1;
    }
    while (idx < sorted.length) {
      if (idx + 1 < sorted.length) {
        spreads.add([sorted[idx], sorted[idx + 1]]);
        idx += 2;
      } else {
        spreads.add([sorted[idx]]);
        idx += 1;
      }
    }
    return spreads;
  }

  static bool isSingleCanvasMultiPagePdf(
    DocumentLoadSuccess state,
    PdfSourceSummary summary,
  ) {
    final onCurrentPage = summary.placements
        .where((p) => p.butterflyPageName == state.pageName)
        .length;
    return onCurrentPage >= 2;
  }

  static int findSpreadIndexForPdfPage(
    List<List<PdfPagePlacement>> spreads,
    int pdfPageIndex,
  ) {
    for (var i = 0; i < spreads.length; i++) {
      for (final p in spreads[i]) {
        if (p.pdfPageIndex == pdfPageIndex) return i;
      }
    }
    return 0;
  }

  static int detectCurrentPageIndex(
    BuildContext context,
    PdfSourceSummary summary,
  ) {
    if (summary.placements.isEmpty) return 0;
    final bloc = context.read<DocumentBloc>();
    final docState = bloc.state;
    if (docState is! DocumentLoadSuccess) {
      return summary.placements.first.pdfPageIndex;
    }
    final onCurrentPage = summary.placements
        .where((p) => p.butterflyPageName == docState.pageName)
        .toList();
    final candidates =
        onCurrentPage.isNotEmpty ? onCurrentPage : summary.placements;
    if (candidates.length == 1) {
      return candidates.first.pdfPageIndex;
    }

    final viewportSize = MediaQuery.sizeOf(context);
    final centerWorld = bloc.transformCubit.state.localToGlobal(
      Offset(viewportSize.width / 2, viewportSize.height / 2),
    );
    var best = candidates.first;
    var bestDist = double.infinity;
    for (final placement in candidates) {
      if (placement.bounds.contains(centerWorld)) {
        return placement.pdfPageIndex;
      }
      final dist = (placement.bounds.center - centerWorld).distanceSquared;
      if (dist < bestDist) {
        bestDist = dist;
        best = placement;
      }
    }
    return best.pdfPageIndex;
  }

  static void navigateToSpread(
    BuildContext context,
    List<PdfPagePlacement> spread,
    PdfMarginCropConfig config,
  ) {
    navigateToSpreadWithBloc(
      context.read<DocumentBloc>(),
      MediaQuery.sizeOf(context),
      spread,
      config,
    );
  }

  static void navigateToSpreadWithBloc(
    DocumentBloc bloc,
    Size viewportSize,
    List<PdfPagePlacement> spread,
    PdfMarginCropConfig config,
  ) {
    if (spread.isEmpty || bloc.isClosed) return;
    final current = bloc.state;
    if (current is! DocumentLoadSuccess) return;

    Rect union = config.croppedWorldRect(
      spread.first.bounds,
      spread.first.pdfPageIndex,
    );
    for (final p in spread.skip(1)) {
      union = union.expandToInclude(
        config.croppedWorldRect(p.bounds, p.pdfPageIndex),
      );
    }

    final isTwoPageSpread =
        config.layoutMode != PdfViewLayoutMode.singlePage && spread.length > 1;
    final widthFrac = isTwoPageSpread ? 0.90 : 0.72;
    final heightFrac = isTwoPageSpread ? 0.84 : 0.82;
    final targetWidth = max(1.0, union.width);
    final targetHeight = max(1.0, union.height);
    final fitScale = min(
      (viewportSize.width * widthFrac) / targetWidth,
      (viewportSize.height * heightFrac) / targetHeight,
    ).clamp(kMinZoom, kMaxZoom);
    final targetPos = Offset(
      union.center.dx - (viewportSize.width / 2) / fitScale,
      union.center.dy - (viewportSize.height / 2) / fitScale,
    );

    final targetPageName = spread.first.butterflyPageName;
    if (current.pageName == targetPageName &&
        current.currentAreaName.isNotEmpty &&
        current.currentArea != null &&
        !current.currentArea!.rect.overlaps(union)) {
      bloc.add(CurrentAreaChanged('', pageName: current.pageName));
    }

    if (current.pageName != targetPageName) {
      bloc.add(
        PageChanged(
          targetPageName,
          position: Point<double>(targetPos.dx, targetPos.dy),
          zoom: fitScale,
        ),
      );
    } else {
      bloc.transformCubit.teleport(targetPos, fitScale, 0);
      unawaited(bloc.bake());
    }
  }

  static void navigateToPageRespectingMode(
    BuildContext context,
    PdfSourceSummary summary,
    int pdfPageIndex,
    PdfMarginCropConfig config,
  ) {
    final bloc = context.read<DocumentBloc>();
    final docState = bloc.state;
    if (docState is! DocumentLoadSuccess) return;

    if (config.layoutMode != PdfViewLayoutMode.singlePage &&
        isSingleCanvasMultiPagePdf(docState, summary)) {
      final spreads = buildSpreads(summary.placements, config.layoutMode);
      final idx = findSpreadIndexForPdfPage(spreads, pdfPageIndex);
      if (idx >= 0 && idx < spreads.length) {
        navigateToSpread(context, spreads[idx], config);
        return;
      }
    }

    final exact = summary.placements
        .where((p) => p.pdfPageIndex == pdfPageIndex)
        .firstOrNull;
    if (exact != null) {
      if (config.hasCrop || config.seamlessLongDoc) {
        navigateToSpread(context, [exact], config);
      } else {
        PdfStudyService.navigateToPdfPage(context, exact);
      }
    }
  }

  static Future<void> reflowCurrentPage(
    BuildContext context,
    PdfSourceSummary summary,
    PdfMarginCropConfig config, {
    bool refitCamera = true,
  }) async {
    final bloc = context.read<DocumentBloc>();
    final docState = bloc.state;
    if (docState is! DocumentLoadSuccess) return;
    if (!isSingleCanvasMultiPagePdf(docState, summary)) return;

    final viewportSize = MediaQuery.sizeOf(context);
    final currentPdfIdx = detectCurrentPageIndex(context, summary);
    final controller = bloc.editorController;
    if (controller.saveCubit.state.embedding?.editable == false) return;

    final pdfElements = <PdfElement>[];
    for (final layer in docState.page.layers) {
      for (final el in layer.content) {
        if (el is PdfElement && el.source == summary.source && el.id != null) {
          pdfElements.add(el);
        }
      }
    }
    if (pdfElements.length < 2) return;
    pdfElements.sort((a, b) => a.page.compareTo(b.page));

    final oldBoundsByPage = <int, Rect>{};
    for (final el in pdfElements) {
      oldBoundsByPage[el.page] = PdfStudyService.computePdfBounds(el);
    }

    final renderers = controller.rendererCubit.renderers;
    final rendererById = <String, Renderer<PadElement>>{};
    for (final r in renderers) {
      final id = r.element.id;
      if (id != null) rendererById[id] = r;
    }

    final pdfIds = pdfElements.map((e) => e.id).whereType<String>().toSet();
    final attachmentsByPdfPage = <int, List<String>>{};
    for (final layer in docState.page.layers) {
      for (final el in layer.content) {
        final id = el.id;
        if (id == null || pdfIds.contains(id)) continue;
        final renderer = rendererById[id];
        final bounds = renderer?.expandedRect ?? renderer?.rect;
        if (bounds == null) continue;
        final center = bounds.center;
        int? matchedPage;
        var bestDist = double.infinity;
        for (final pdfEl in pdfElements) {
          final pdfRect = oldBoundsByPage[pdfEl.page]!;
          final expanded = Rect.fromLTRB(
            pdfRect.left - 40,
            pdfRect.top - 40,
            pdfRect.right + pdfRect.width * 0.55,
            pdfRect.bottom + 40,
          );
          if (expanded.contains(center)) {
            final d = (pdfRect.center - center).distanceSquared;
            if (d < bestDist) {
              bestDist = d;
              matchedPage = pdfEl.page;
            }
          }
        }
        if (matchedPage != null) {
          attachmentsByPdfPage.putIfAbsent(matchedPage, () => []).add(id);
        }
      }
    }

    final firstEl = pdfElements.first;
    final firstOld = oldBoundsByPage[firstEl.page]!;
    final firstVis = config.croppedWorldRect(firstOld, firstEl.page);
    final originX = firstVis.left;
    final originY = firstVis.top;

    var sumVisWidth = 0.0;
    for (final el in pdfElements) {
      final b = oldBoundsByPage[el.page]!;
      sumVisWidth += b.width * config.visibleWidthFractionForPage(el.page);
    }
    final avgVisWidth = sumVisWidth / pdfElements.length;
    final spineGap = config.effectiveBookSpineGap;
    final spreadTypicalWidth = avgVisWidth * 2 + spineGap;

    final rows = <List<PdfElement>>[];
    if (config.layoutMode == PdfViewLayoutMode.singlePage) {
      for (final el in pdfElements) {
        rows.add([el]);
      }
    } else {
      var idx = 0;
      if (config.layoutMode == PdfViewLayoutMode.twoPageCover &&
          pdfElements.isNotEmpty) {
        rows.add([pdfElements.first]);
        idx = 1;
      }
      while (idx < pdfElements.length) {
        if (idx + 1 < pdfElements.length) {
          rows.add([pdfElements[idx], pdfElements[idx + 1]]);
          idx += 2;
        } else {
          rows.add([pdfElements[idx]]);
          idx += 1;
        }
      }
    }

    final newPositionsByPage = <int, Offset>{};
    final newBoundsByPage = <int, Rect>{};
    var cursorY = originY;

    for (final row in rows) {
      var maxRowHeight = 0.0;
      if (config.layoutMode != PdfViewLayoutMode.singlePage && row.length == 1) {
        final el = row.first;
        final oldB = oldBoundsByPage[el.page]!;
        final l = config.effectiveLeftForPage(el.page);
        final visW = oldB.width * config.visibleWidthFractionForPage(el.page);
        final visH = oldB.height * config.visibleHeightFraction;
        final visX =
            el.page == 0 && config.layoutMode == PdfViewLayoutMode.twoPageCover
                ? originX + (spreadTypicalWidth - visW) / 2
                : originX;
        final newX = visX - oldB.width * l;
        final newY = cursorY - oldB.height * config.top;
        newPositionsByPage[el.page] = Offset(newX, newY);
        newBoundsByPage[el.page] = Rect.fromLTWH(
          newX,
          newY,
          oldB.width,
          oldB.height,
        );
        maxRowHeight = visH;
      } else {
        var cursorX = originX;
        for (var c = 0; c < row.length; c++) {
          final el = row[c];
          final oldB = oldBoundsByPage[el.page]!;
          final l = config.effectiveLeftForPage(el.page);
          final visW = oldB.width * config.visibleWidthFractionForPage(el.page);
          final visH = oldB.height * config.visibleHeightFraction;
          final newX = cursorX - oldB.width * l;
          final newY = cursorY - oldB.height * config.top;
          newPositionsByPage[el.page] = Offset(newX, newY);
          newBoundsByPage[el.page] = Rect.fromLTWH(
            newX,
            newY,
            oldB.width,
            oldB.height,
          );
          cursorX += visW + (c == 0 ? spineGap : 0.0);
          maxRowHeight = max(maxRowHeight, visH);
        }
      }
      final rowGap = config.layoutMode == PdfViewLayoutMode.singlePage
          ? config.effectivePageGap
          : config.effectiveRowGap;
      cursorY += maxRowHeight + rowGap;
    }

    final updates = <String, List<PadElement>>{};
    for (final el in pdfElements) {
      final id = el.id;
      final newPos = newPositionsByPage[el.page];
      final oldB = oldBoundsByPage[el.page];
      if (id == null || newPos == null || oldB == null) continue;
      final dx = newPos.dx - el.position.x;
      final dy = newPos.dy - el.position.y;
      if (dx.abs() > 0.25 || dy.abs() > 0.25) {
        updates[id] = [el.copyWith(position: Point(newPos.dx, newPos.dy))];
        for (final attachId in attachmentsByPdfPage[el.page] ?? const <String>[]) {
          final r = rendererById[attachId];
          final transformed = r?.transform(position: Offset(dx, dy));
          if (transformed != null) {
            updates[attachId] = [transformed.element];
          }
        }
      }
    }

    if (docState.currentAreaName.isNotEmpty) {
      bloc.add(CurrentAreaChanged('', pageName: docState.pageName));
    }

    if (updates.isNotEmpty) {
      final previousPage = docState.page;
      bloc.add(ElementsChanged(updates, pageName: docState.pageName));
      try {
        await bloc.stream
            .firstWhere(
              (s) => s is DocumentLoadSuccess && !identical(s.page, previousPage),
            )
            .timeout(const Duration(milliseconds: 800));
      } catch (_) {}
    }

    if (bloc.isClosed) return;
    if (refitCamera) {
      final refreshed = [
        for (final el in pdfElements)
          PdfPagePlacement(
            pdfSource: summary.source,
            pdfPageIndex: el.page,
            butterflyPageName: docState.pageName,
            bounds: newBoundsByPage[el.page] ?? oldBoundsByPage[el.page]!,
          ),
      ];
      final spreads = buildSpreads(refreshed, config.layoutMode);
      final spreadIdx = findSpreadIndexForPdfPage(spreads, currentPdfIdx);
      if (spreadIdx >= 0 && spreadIdx < spreads.length) {
        navigateToSpreadWithBloc(bloc, viewportSize, spreads[spreadIdx], config);
      }
      unawaited(bloc.bake(reset: true));
    } else {
      unawaited(bloc.bake(reset: true));
    }
  }
}
