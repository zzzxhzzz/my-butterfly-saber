import 'dart:async';
import 'dart:math';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/helpers/rect.dart';
import 'package:butterfly/services/asset.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ocr_models.dart';

class PdfPagePlacement {
  final String pdfSource;
  final int pdfPageIndex;
  final String butterflyPageName;
  final Rect bounds;

  const PdfPagePlacement({
    required this.pdfSource,
    required this.pdfPageIndex,
    required this.butterflyPageName,
    required this.bounds,
  });
}

class PdfSourceSummary {
  final String source;
  final String displayName;
  final List<PdfPagePlacement> placements;

  const PdfSourceSummary({
    required this.source,
    required this.displayName,
    required this.placements,
  });
}

class PdfSearchHit {
  final int pdfPageIndex;
  final String snippet;

  const PdfSearchHit({
    required this.pdfPageIndex,
    required this.snippet,
  });
}

class PdfStudyService {
  const PdfStudyService._();

  static NoteData? _cachedData;
  static DocumentPage? _cachedPage;
  static String? _cachedPageName;
  static String? _cachedDocName;
  static List<PdfSourceSummary>? _cachedSummaries;
  static final _hexNamePattern = RegExp(r'^[0-9a-fA-F]{12,}(?:\.[A-Za-z0-9]+)?$');

  static int findNearestPlacementIndex(
    List<PdfPagePlacement> placements,
    Offset worldCenter,
  ) {
    if (placements.isEmpty) return 0;
    if (placements.length <= 12) {
      var bestIdx = 0;
      var bestDist = double.infinity;
      for (var i = 0; i < placements.length; i++) {
        final b = placements[i].bounds;
        if (b.contains(worldCenter)) return i;
        final d = (b.center - worldCenter).distanceSquared;
        if (d < bestDist) {
          bestDist = d;
          bestIdx = i;
        }
      }
      return bestIdx;
    }

    // Fast path: check monotonic Y ordering (both single-column and 2-page spread rows).
    final firstTop = placements.first.bounds.top;
    final lastTop = placements.last.bounds.top;
    if (lastTop >= firstTop) {
      var lo = 0;
      var hi = placements.length - 1;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (placements[mid].bounds.bottom < worldCenter.dy) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      final start = max(0, lo - 4);
      final end = min(placements.length - 1, lo + 5);
      var bestIdx = start;
      var bestDist = double.infinity;
      for (var i = start; i <= end; i++) {
        final b = placements[i].bounds;
        if (b.contains(worldCenter)) return i;
        final d = (b.center - worldCenter).distanceSquared;
        if (d < bestDist) {
          bestDist = d;
          bestIdx = i;
        }
      }
      return bestIdx;
    }

    var bestIdx = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < placements.length; i++) {
      final b = placements[i].bounds;
      if (b.contains(worldCenter)) return i;
      final d = (b.center - worldCenter).distanceSquared;
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  static Rect computePdfBounds(PdfElement element) {
    final constraints = element.constraints;
    var width = element.width;
    var height = element.height;
    if (constraints is ScaledElementConstraints) {
      width *= constraints.scaleX == 0 ? 1 : constraints.scaleX;
      height *= constraints.scaleY == 0 ? 1 : constraints.scaleY;
    } else if (constraints is FixedElementConstraints) {
      width = constraints.width == 0 ? width : constraints.width;
      height = constraints.height == 0 ? height : constraints.height;
    } else if (constraints is DynamicElementConstraints) {
      width = constraints.width;
      height = constraints.height;
      final ratio = constraints.aspectRatio;
      if (ratio != 0) {
        if (width == 0) width = height * ratio;
        if (height == 0) height = width / ratio;
      }
      if (width == 0) width = element.width;
      if (height == 0) height = element.height;
    }
    return Rect.fromLTWH(
      element.position.x,
      element.position.y,
      width.abs(),
      height.abs(),
    );
  }

  static List<PdfSourceSummary> indexDocumentPdfs(DocumentLoadSuccess state) {
    final docName = state.metadata.name;
    if (identical(state.data, _cachedData) &&
        identical(state.page, _cachedPage) &&
        state.pageName == _cachedPageName &&
        docName == _cachedDocName &&
        _cachedSummaries != null) {
      return _cachedSummaries!;
    }

    final grouped = <String, List<PdfPagePlacement>>{};
    final pages = state.data.getPages(true);
    for (final realPageName in pages) {
      final page = realPageName == state.pageName
          ? state.page
          : state.data.getPage(realPageName);
      if (page == null) continue;
      for (final element in page.content.whereType<PdfElement>()) {
        grouped.putIfAbsent(element.source, () => []).add(
          PdfPagePlacement(
            pdfSource: element.source,
            pdfPageIndex: element.page,
            butterflyPageName: realPageName,
            bounds: computePdfBounds(element),
          ),
        );
      }
    }
    if (grouped.isEmpty) {
      for (final element in state.page.content.whereType<PdfElement>()) {
        grouped.putIfAbsent(element.source, () => []).add(
          PdfPagePlacement(
            pdfSource: element.source,
            pdfPageIndex: element.page,
            butterflyPageName: state.pageName,
            bounds: computePdfBounds(element),
          ),
        );
      }
    }

    final summaries = <PdfSourceSummary>[];
    var index = 1;
    final cleanDocTitle = docName.trim();
    for (final entry in grouped.entries) {
      final placements = entry.value.toList()
        ..sort((a, b) => a.pdfPageIndex.compareTo(b.pdfPageIndex));
      final rawName = entry.key.split('/').last;
      final label = (rawName.isEmpty || _hexNamePattern.hasMatch(rawName))
          ? (cleanDocTitle.isNotEmpty
                ? (grouped.length > 1 ? '$cleanDocTitle #$index' : cleanDocTitle)
                : 'PDF #$index')
          : (rawName.length > 28
                ? '${rawName.substring(0, 22)}...'
                : rawName);
      summaries.add(
        PdfSourceSummary(
          source: entry.key,
          displayName: label,
          placements: List.unmodifiable(placements),
        ),
      );
      index++;
    }
    final frozen = List<PdfSourceSummary>.unmodifiable(summaries);
    _cachedData = state.data;
    _cachedPage = state.page;
    _cachedPageName = state.pageName;
    _cachedDocName = docName;
    _cachedSummaries = frozen;
    return frozen;
  }

  static Future<List<PdfOutlineNode>> loadOutline(
    AssetService assetService,
    NoteData data,
    String source,
  ) async {
    final pdfDoc = await assetService.getPdfDocument(source, data);
    if (pdfDoc == null) return const [];
    try {
      return await pdfDoc.loadOutline();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<PdfSearchHit>> searchPdfText(
    AssetService assetService,
    NoteData data,
    String source,
    String query, {
    required bool Function() isCancelled,
    void Function(int current, int total)? onProgress,
    Map<int, OcrPageResult>? ocrPages,
  }) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final pdfDoc = await assetService.getPdfDocument(source, data);
    if (pdfDoc == null) return const [];

    final hits = <PdfSearchHit>[];
    final pages = pdfDoc.pages;
    for (var i = 0; i < pages.length; i++) {
      if (isCancelled()) break;
      onProgress?.call(i + 1, pages.length);
      var pageHits = 0;
      try {
        final rawText = await pages[i].loadText();
        final fullText = rawText?.fullText ?? '';
        if (fullText.isNotEmpty) {
          final lower = fullText.toLowerCase();
          var searchFrom = 0;
          while (pageHits < 2) {
            final matchIndex = lower.indexOf(needle, searchFrom);
            if (matchIndex < 0) break;
            final start = max(0, matchIndex - 24);
            final end = min(fullText.length, matchIndex + needle.length + 48);
            final rawSnippet = fullText
                .substring(start, end)
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            final prefix = start > 0 ? '...' : '';
            final suffix = end < fullText.length ? '...' : '';
            hits.add(
              PdfSearchHit(
                pdfPageIndex: i,
                snippet: '$prefix$rawSnippet$suffix',
              ),
            );
            pageHits++;
            searchFrom = matchIndex + needle.length;
          }
        }
      } catch (_) {}
      if (pageHits == 0 && ocrPages != null) {
        final ocrText = ocrPages[i]?.fullText ?? '';
        if (ocrText.isNotEmpty) {
          final lowerOcr = ocrText.toLowerCase();
          var searchFrom = 0;
          while (pageHits < 2) {
            final matchIndex = lowerOcr.indexOf(needle, searchFrom);
            if (matchIndex < 0) break;
            final start = max(0, matchIndex - 24);
            final end = min(ocrText.length, matchIndex + needle.length + 48);
            final rawSnippet = ocrText
                .substring(start, end)
                .replaceAll(RegExp(r'\s+'), ' ')
                .trim();
            final prefix = start > 0 ? '...' : '';
            final suffix = end < ocrText.length ? '...' : '';
            hits.add(
              PdfSearchHit(
                pdfPageIndex: i,
                snippet: '[OCR] $prefix$rawSnippet$suffix',
              ),
            );
            pageHits++;
            searchFrom = matchIndex + needle.length;
          }
        }
      }
      if (i % 4 == 3) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return hits;
  }

  static void navigateToPdfPage(
    BuildContext context,
    PdfPagePlacement placement,
  ) {
    final bloc = context.read<DocumentBloc>();
    final current = bloc.state;
    if (current is! DocumentLoadSuccess) return;

    final viewportSize = MediaQuery.sizeOf(context);
    final bounds = placement.bounds;
    final targetWidth = max(1.0, bounds.width);
    final targetHeight = max(1.0, bounds.height);
    final fitScale = min(
      (viewportSize.width * 0.68) / targetWidth,
      (viewportSize.height * 0.80) / targetHeight,
    ).clamp(kMinZoom, kMaxZoom);
    final targetPos = Offset(
      bounds.center.dx - (viewportSize.width / 2) / fitScale,
      bounds.center.dy - (viewportSize.height / 2) / fitScale,
    );

    if (current.pageName == placement.butterflyPageName &&
        current.currentAreaName.isNotEmpty &&
        current.currentArea != null &&
        !current.currentArea!.rect.overlaps(bounds)) {
      bloc.add(CurrentAreaChanged('', pageName: current.pageName));
    }

    if (current.pageName != placement.butterflyPageName) {
      bloc.add(
        PageChanged(
          placement.butterflyPageName,
          position: Point<double>(targetPos.dx, targetPos.dy),
          zoom: fitScale,
        ),
      );
    } else {
      bloc.transformCubit.teleport(targetPos, fitScale, 0);
      unawaited(bloc.bake());
    }
  }
}
