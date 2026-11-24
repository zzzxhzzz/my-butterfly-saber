import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:butterfly/services/asset.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:butterfly/saber_fusion/ocr_models.dart';
import 'package:butterfly/saber_fusion/ocr_service.dart';

OcrCubit? maybeOcrCubit(BuildContext context) {
  try {
    return context.read<OcrCubit>();
  } catch (_) {
    return null;
  }
}

class OcrCubit extends Cubit<OcrState> {
  static const _prefWhiteBg = 'saber_fusion.ocr_white_bg_v1';
  static const _prefWhiteOpacity = 'saber_fusion.ocr_white_opacity_v1';
  static const _prefLanguage = 'saber_fusion.ocr_language_v1';
  static const _prefScope = 'saber_fusion.ocr_scope_v1';

  final OcrService _service;
  final Map<String, String> _docHashCache = {};

  int _jobToken = 0;
  NoteData? _boundDocument;
  AssetService? _boundAssets;
  PdfDocument? _boundPdf;
  int _lastFocusPage = 0;

  OcrCubit({OcrService? service})
    : _service = service ?? OcrService(),
      super(const OcrState());

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final whiteBg = prefs.getBool(_prefWhiteBg) ?? false;
      final opacity = (prefs.getDouble(_prefWhiteOpacity) ?? 1.0).clamp(0.0, 1.0);
      final langName = prefs.getString(_prefLanguage);
      final scopeName = prefs.getString(_prefScope);

      final language = OcrLanguage.values.firstWhere(
        (e) => e.name == langName,
        orElse: () => OcrLanguage.zhEn,
      );
      final scope = OcrScope.values.firstWhere(
        (e) => e.name == scopeName,
        orElse: () => OcrScope.entireDocument,
      );

      if (!isClosed) {
        emit(
          state.copyWith(
            whiteBgVisible: whiteBg,
            whiteBgOpacity: opacity,
            language: language,
            scope: scope,
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> bindDocument({
    required String pdfSource,
    required NoteData document,
    required AssetService assets,
    int initialFocusPage = 0,
    bool forceSameSource = false,
  }) async {
    _boundDocument = document;
    _boundAssets = assets;
    _lastFocusPage = initialFocusPage;

    if (!forceSameSource &&
        state.activePdfSource == pdfSource &&
        state.docHash != null &&
        state.totalPages > 0) {
      unawaited(ensureProgressiveAround(initialFocusPage));
      return;
    }

    final token = ++_jobToken;
    emit(
      state.copyWith(
        activePdfSource: pdfSource,
        docHash: null,
        totalPages: 0,
        completedPages: 0,
        cacheHitPages: 0,
        isRunning: false,
        currentRunningPage: null,
        pages: const {},
        selection: null,
        statusError: null,
      ),
    );

    final pdf = await assets.getPdfDocument(pdfSource, document);
    if (isClosed || token != _jobToken) return;
    if (pdf == null || pdf.pages.isEmpty) {
      _boundPdf = null;
      return;
    }
    _boundPdf = pdf;

    var docHash = _docHashCache[pdfSource];
    if (docHash == null) {
      final bytes = await _service.readPdfBytes(
        source: pdfSource,
        document: document,
        assets: assets,
      );
      if (isClosed || token != _jobToken) return;
      docHash = bytes != null
          ? _service.computeDocHash(bytes)
          : pdfSource.hashCode.toRadixString(16).padLeft(8, '0');
      _docHashCache[pdfSource] = docHash;
    }

    final totalPages = pdf.pages.length;
    final langTag = state.language.nativeTag;
    final cachedPages = <int, OcrPageResult>{};
    for (var i = 0; i < totalPages; i++) {
      final hit = await _service.loadCachedPage(
        docHash: docHash,
        langTag: langTag,
        pageIndex: i,
      );
      if (isClosed || token != _jobToken) return;
      if (hit != null) {
        cachedPages[i] = hit;
      }
    }

    emit(
      state.copyWith(
        activePdfSource: pdfSource,
        docHash: docHash,
        totalPages: totalPages,
        completedPages: cachedPages.length,
        cacheHitPages: cachedPages.length,
        pages: Map.unmodifiable(cachedPages),
        isRunning: false,
        currentRunningPage: null,
        statusError: null,
      ),
    );

    if (cachedPages.length < totalPages) {
      final targets = _buildPriorityQueue(
        totalPages: totalPages,
        focusPage: initialFocusPage,
        alreadyDone: cachedPages.keys.toSet(),
        progressiveOnly: state.scope == OcrScope.progressive,
      );
      if (targets.isNotEmpty) {
        unawaited(
          _runPageQueue(
            token: token,
            pdf: pdf,
            docHash: docHash,
            language: state.language,
            targets: targets,
          ),
        );
      }
    }
  }

  Future<void> ensureProgressiveAround(int centerPage) async {
    _lastFocusPage = centerPage;
    if (state.scope != OcrScope.progressive || state.isRunning) return;
    final pdf = _boundPdf;
    final docHash = state.docHash;
    if (pdf == null || docHash == null || pdf.pages.isEmpty) return;

    final targets = _buildPriorityQueue(
      totalPages: pdf.pages.length,
      focusPage: centerPage,
      alreadyDone: state.pages.keys.toSet(),
      progressiveOnly: true,
    );
    if (targets.isEmpty) return;
    final token = _jobToken;
    unawaited(
      _runPageQueue(
        token: token,
        pdf: pdf,
        docHash: docHash,
        language: state.language,
        targets: targets,
      ),
    );
  }

  void unbindDocument() {
    if (state.activePdfSource == null &&
        state.totalPages == 0 &&
        state.pages.isEmpty) {
      return;
    }
    _jobToken++;
    _boundDocument = null;
    _boundAssets = null;
    _boundPdf = null;
    emit(
      state.copyWith(
        activePdfSource: null,
        docHash: null,
        totalPages: 0,
        completedPages: 0,
        cacheHitPages: 0,
        isRunning: false,
        currentRunningPage: null,
        pages: const {},
        selection: null,
        statusError: null,
      ),
    );
  }

  Future<void> rerunOcrTask() async {
    final source = state.activePdfSource;
    final docHash = state.docHash;
    final doc = _boundDocument;
    final assets = _boundAssets;
    if (source == null || docHash == null || doc == null || assets == null) {
      return;
    }

    final token = ++_jobToken;
    await _service.clearCacheForDoc(
      docHash: docHash,
      langTag: state.language.nativeTag,
    );
    if (isClosed || token != _jobToken) return;

    final pdf = _boundPdf ?? await assets.getPdfDocument(source, doc);
    if (isClosed || token != _jobToken || pdf == null) return;
    _boundPdf = pdf;

    emit(
      state.copyWith(
        totalPages: pdf.pages.length,
        completedPages: 0,
        cacheHitPages: 0,
        pages: const {},
        selection: null,
        isRunning: true,
        statusError: null,
      ),
    );

    final targets = _buildPriorityQueue(
      totalPages: pdf.pages.length,
      focusPage: _lastFocusPage,
      alreadyDone: const {},
      progressiveOnly: false,
    );
    await _runPageQueue(
      token: token,
      pdf: pdf,
      docHash: docHash,
      language: state.language,
      targets: targets,
    );
  }

  List<int> _buildPriorityQueue({
    required int totalPages,
    required int focusPage,
    required Set<int> alreadyDone,
    required bool progressiveOnly,
  }) {
    final clampedFocus = focusPage.clamp(0, totalPages - 1);
    final ordered = LinkedHashSet<int>();
    if (!alreadyDone.contains(clampedFocus)) {
      ordered.add(clampedFocus);
    }

    final windowRadius = progressiveOnly ? 2 : totalPages;
    for (var d = 1; d <= windowRadius; d++) {
      final next = clampedFocus + d;
      if (next < totalPages && !alreadyDone.contains(next)) {
        ordered.add(next);
      }
      final prev = clampedFocus - d;
      if (prev >= 0 && !alreadyDone.contains(prev)) {
        ordered.add(prev);
      }
    }
    if (!progressiveOnly) {
      for (var i = 0; i < totalPages; i++) {
        if (!alreadyDone.contains(i)) {
          ordered.add(i);
        }
      }
    }
    return ordered.toList(growable: false);
  }

  Future<void> _runPageQueue({
    required int token,
    required PdfDocument pdf,
    required String docHash,
    required OcrLanguage language,
    required List<int> targets,
  }) async {
    if (targets.isEmpty) return;
    emit(state.copyWith(isRunning: true, statusError: null));

    for (final pageIndex in targets) {
      if (isClosed || token != _jobToken) return;
      if (pageIndex < 0 || pageIndex >= pdf.pages.length) continue;

      emit(state.copyWith(isRunning: true, currentRunningPage: pageIndex));
      try {
        final result = await _service.recognizePdfPage(
          pdfPage: pdf.pages[pageIndex],
          pageIndex: pageIndex,
          language: language,
        );
        if (isClosed || token != _jobToken) return;

        await _service.saveCachedPage(
          docHash: docHash,
          langTag: language.nativeTag,
          result: result,
        );
        if (isClosed || token != _jobToken) return;

        final updated = Map<int, OcrPageResult>.from(state.pages);
        updated[pageIndex] = result;
        emit(
          state.copyWith(
            pages: Map.unmodifiable(updated),
            completedPages: updated.length,
            isRunning: true,
            currentRunningPage: pageIndex,
          ),
        );
      } catch (e) {
        if (isClosed || token != _jobToken) return;
        emit(state.copyWith(statusError: '第 ${pageIndex + 1} 页识别异常: $e'));
      }
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }

    if (!isClosed && token == _jobToken) {
      emit(state.copyWith(isRunning: false, currentRunningPage: null));
    }
  }

  void toggleWhiteBgLayer() {
    final next = !state.whiteBgVisible;
    emit(state.copyWith(whiteBgVisible: next));
    _saveBool(_prefWhiteBg, next);
  }

  void setWhiteBgVisible(bool visible) {
    if (state.whiteBgVisible == visible) return;
    emit(state.copyWith(whiteBgVisible: visible));
    _saveBool(_prefWhiteBg, visible);
  }

  void setWhiteBgOpacity(double opacity) {
    final clamped = opacity.clamp(0.0, 1.0);
    emit(state.copyWith(whiteBgOpacity: clamped));
    _saveDouble(_prefWhiteOpacity, clamped);
  }

  Future<void> setLanguage(OcrLanguage language) async {
    if (state.language == language) return;
    emit(state.copyWith(language: language, selection: null));
    await _saveString(_prefLanguage, language.name);

    final source = state.activePdfSource;
    final doc = _boundDocument;
    final assets = _boundAssets;
    if (source != null && doc != null && assets != null) {
      await bindDocument(
        pdfSource: source,
        document: doc,
        assets: assets,
        initialFocusPage: _lastFocusPage,
        forceSameSource: true,
      );
    }
  }

  Future<void> setScope(OcrScope scope) async {
    if (state.scope == scope) return;
    emit(state.copyWith(scope: scope));
    await _saveString(_prefScope, scope.name);

    if (scope == OcrScope.entireDocument &&
        !state.isRunning &&
        _boundPdf != null &&
        state.docHash != null &&
        state.completedPages < state.totalPages) {
      final targets = _buildPriorityQueue(
        totalPages: _boundPdf!.pages.length,
        focusPage: _lastFocusPage,
        alreadyDone: state.pages.keys.toSet(),
        progressiveOnly: false,
      );
      if (targets.isNotEmpty) {
        unawaited(
          _runPageQueue(
            token: _jobToken,
            pdf: _boundPdf!,
            docHash: state.docHash!,
            language: state.language,
            targets: targets,
          ),
        );
      }
    }
  }

  void setSelection(OcrSelectionState? selection) {
    emit(state.copyWith(selection: selection));
  }

  void clearSelection() {
    if (state.selection == null) return;
    emit(state.copyWith(selection: null));
  }

  Future<String?> recognizeRegionPng(Uint8List pngBytes) =>
      _service.recognizeRegionPng(pngBytes: pngBytes, language: state.language);

  Future<void> _saveBool(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {}
  }

  Future<void> _saveDouble(String key, double value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(key, value);
    } catch (_) {}
  }

  Future<void> _saveString(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  @override
  Future<void> close() {
    _jobToken++;
    return super.close();
  }
}
