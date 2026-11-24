import 'dart:async';
import 'dart:typed_data';

import 'package:butterfly/services/asset.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ocr_models.dart';
import 'ocr_service.dart';
import 'study_state.dart';

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
  static const _prefEngineMode = 'saber_fusion.ocr_engine_v1';
  static const _defaultCooldown = Duration(milliseconds: 850);

  final OcrService _service;
  final Map<String, String> _docHashCache = {};

  int _jobToken = 0;
  NoteData? _boundDocument;
  AssetService? _boundAssets;
  PdfDocument? _boundPdf;
  int _lastFocusPage = 0;
  DateTime _busyUntil = DateTime.fromMillisecondsSinceEpoch(0);
  AiTutorConfig _latestAiConfig = const AiTutorConfig();

  OcrCubit({OcrService? service})
    : _service = service ?? OcrService(),
      super(const OcrState());

  void syncAiConfig(AiTutorConfig config) {
    _latestAiConfig = config;
  }

  /// Interaction-first cooldown: pauses background OCR while user scrolls,
  /// zooms, or edits so canvas rendering stays responsive at 60fps.
  void notifyUserBusy([Duration duration = _defaultCooldown]) {
    final target = DateTime.now().add(duration);
    if (target.isAfter(_busyUntil)) {
      _busyUntil = target;
    }
  }

  Future<void> _waitUntilIdle(int token) async {
    while (!isClosed && token == _jobToken) {
      final now = DateTime.now();
      if (!now.isBefore(_busyUntil)) return;
      final remaining = _busyUntil.difference(now);
      final waitStep = remaining.inMilliseconds > 160
          ? const Duration(milliseconds: 160)
          : remaining;
      await Future<void>.delayed(waitStep);
    }
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final whiteBg = prefs.getBool(_prefWhiteBg) ?? false;
      final opacity = (prefs.getDouble(_prefWhiteOpacity) ?? 1.0).clamp(0.0, 1.0);
      final langName = prefs.getString(_prefLanguage);
      final scopeName = prefs.getString(_prefScope);
      final engineName = prefs.getString(_prefEngineMode);

      final language = OcrLanguage.values.firstWhere(
        (e) => e.name == langName,
        orElse: () => OcrLanguage.zhEn,
      );
      final scope = OcrScope.values.firstWhere(
        (e) => e.name == scopeName,
        orElse: () => OcrScope.progressive,
      );
      final engineMode = OcrEngineMode.values.firstWhere(
        (e) => e.name == engineName,
        orElse: () => OcrEngineMode.localNative,
      );

      if (!isClosed) {
        emit(
          state.copyWith(
            whiteBgVisible: whiteBg,
            whiteBgOpacity: opacity,
            language: language,
            scope: scope,
            engineMode: engineMode,
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

    final totalPages = pdf.pages.length;
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

    // Emit totalPages immediately so UI never hangs at 0 / 0 on 300+ page docs.
    emit(
      state.copyWith(
        activePdfSource: pdfSource,
        docHash: docHash,
        totalPages: totalPages,
        completedPages: 0,
        cacheHitPages: 0,
        pages: const {},
        isRunning: false,
        currentRunningPage: null,
        statusError: null,
      ),
    );

    final cacheTag = OcrService.cacheTagFor(state.language, state.engineMode);
    final cachedIndices = await _service.listCachedPageIndices(
      docHash: docHash,
      cacheTag: cacheTag,
    );
    if (isClosed || token != _jobToken) return;

    final cachedPages = <int, OcrPageResult>{};
    if (cachedIndices.isNotEmpty) {
      // Load nearby viewport pages first for instant interactivity.
      final clampedFocus = initialFocusPage.clamp(0, totalPages - 1);
      final priorityIndices = <int>[];
      final restIndices = <int>[];
      for (final idx in cachedIndices) {
        if (idx >= 0 && idx < totalPages) {
          if ((idx - clampedFocus).abs() <= 4) {
            priorityIndices.add(idx);
          } else {
            restIndices.add(idx);
          }
        }
      }

      for (final idx in priorityIndices) {
        final hit = await _service.loadCachedPage(
          docHash: docHash,
          cacheTag: cacheTag,
          pageIndex: idx,
        );
        if (isClosed || token != _jobToken) return;
        if (hit != null) cachedPages[idx] = hit;
      }

      if (priorityIndices.isNotEmpty && restIndices.isNotEmpty) {
        emit(
          state.copyWith(
            completedPages: cachedPages.length,
            cacheHitPages: cachedPages.length,
            pages: Map.unmodifiable(cachedPages),
          ),
        );
      }

      for (var i = 0; i < restIndices.length; i++) {
        final hit = await _service.loadCachedPage(
          docHash: docHash,
          cacheTag: cacheTag,
          pageIndex: restIndices[i],
        );
        if (isClosed || token != _jobToken) return;
        if (hit != null) cachedPages[restIndices[i]] = hit;
        if (i % 24 == 23) {
          await Future<void>.delayed(Duration.zero);
        }
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

    if (state.engineMode == OcrEngineMode.openAiVision &&
        !_latestAiConfig.isConfigured) {
      return;
    }

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
            engineMode: state.engineMode,
            targets: targets,
          ),
        );
      }
    }
  }

  Future<void> ensureProgressiveAround(int centerPage) async {
    _lastFocusPage = centerPage;
    if (state.isRunning) return;
    if (state.engineMode == OcrEngineMode.openAiVision &&
        !_latestAiConfig.isConfigured) {
      return;
    }
    final pdf = _boundPdf;
    final docHash = state.docHash;
    if (pdf == null || docHash == null || pdf.pages.isEmpty) return;

    final targets = _buildPriorityQueue(
      totalPages: pdf.pages.length,
      focusPage: centerPage,
      alreadyDone: state.pages.keys.toSet(),
      progressiveOnly: state.scope == OcrScope.progressive,
    );
    if (targets.isEmpty) return;
    final token = _jobToken;
    unawaited(
      _runPageQueue(
        token: token,
        pdf: pdf,
        docHash: docHash,
        language: state.language,
        engineMode: state.engineMode,
        targets: targets,
      ),
    );
  }

  void stopOcrTask() {
    if (!state.isRunning) return;
    _jobToken++;
    emit(state.copyWith(isRunning: false, currentRunningPage: null));
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

  Future<void> rerunOcrTask({bool currentScopeOnly = false}) async {
    final source = state.activePdfSource;
    final docHash = state.docHash;
    final doc = _boundDocument;
    final assets = _boundAssets;
    if (source == null || docHash == null || doc == null || assets == null) {
      return;
    }

    final token = ++_jobToken;
    final cacheTag = OcrService.cacheTagFor(state.language, state.engineMode);
    await _service.clearCacheForDoc(docHash: docHash, cacheTag: cacheTag);
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
      progressiveOnly: currentScopeOnly && state.scope == OcrScope.progressive,
    );
    await _runPageQueue(
      token: token,
      pdf: pdf,
      docHash: docHash,
      language: state.language,
      engineMode: state.engineMode,
      targets: targets,
    );
  }

  Future<bool> recognizeSinglePageWithOpenAi(
    int pageIndex,
    AiTutorConfig aiConfig,
  ) async {
    _latestAiConfig = aiConfig;
    final pdf = _boundPdf;
    final docHash = state.docHash;
    if (pdf == null ||
        docHash == null ||
        pageIndex < 0 ||
        pageIndex >= pdf.pages.length) {
      return false;
    }
    if (!aiConfig.isConfigured) {
      emit(state.copyWith(statusError: '请先在 AI 设置中配置 OpenAI 兼容接口与 Key'));
      return false;
    }

    final token = ++_jobToken;
    emit(
      state.copyWith(
        isRunning: true,
        currentRunningPage: pageIndex,
        statusError: null,
      ),
    );
    try {
      final result = await _service.recognizePdfPage(
        pdfPage: pdf.pages[pageIndex],
        pageIndex: pageIndex,
        language: state.language,
        engineMode: OcrEngineMode.openAiVision,
        aiConfig: aiConfig,
      );
      if (isClosed || token != _jobToken) return false;

      final currentBucketTag = OcrService.cacheTagFor(
        state.language,
        state.engineMode,
      );
      await _service.saveCachedPage(
        docHash: docHash,
        cacheTag: OcrService.cacheTagFor(
          state.language,
          OcrEngineMode.openAiVision,
        ),
        result: result,
      );
      if (currentBucketTag !=
          OcrService.cacheTagFor(state.language, OcrEngineMode.openAiVision)) {
        await _service.saveCachedPage(
          docHash: docHash,
          cacheTag: currentBucketTag,
          result: result,
        );
      }
      if (isClosed || token != _jobToken) return false;

      final updated = Map<int, OcrPageResult>.from(state.pages);
      updated[pageIndex] = result;
      emit(
        state.copyWith(
          pages: Map.unmodifiable(updated),
          completedPages: updated.length,
          isRunning: false,
          currentRunningPage: null,
          statusError: null,
        ),
      );
      return true;
    } catch (e) {
      if (!isClosed && token == _jobToken) {
        emit(
          state.copyWith(
            isRunning: false,
            currentRunningPage: null,
            statusError: e.toString(),
          ),
        );
      }
      return false;
    }
  }

  List<int> _buildPriorityQueue({
    required int totalPages,
    required int focusPage,
    required Set<int> alreadyDone,
    required bool progressiveOnly,
  }) {
    final clampedFocus = focusPage.clamp(0, totalPages - 1);
    final ordered = <int>{};
    if (!alreadyDone.contains(clampedFocus)) {
      ordered.add(clampedFocus);
    }

    final windowRadius = progressiveOnly ? 1 : totalPages;
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
    required OcrEngineMode engineMode,
    required List<int> targets,
  }) async {
    if (targets.isEmpty) return;
    emit(state.copyWith(isRunning: true, statusError: null));
    final cacheTag = OcrService.cacheTagFor(language, engineMode);

    for (final pageIndex in targets) {
      await _waitUntilIdle(token);
      if (isClosed || token != _jobToken) return;
      if (pageIndex < 0 || pageIndex >= pdf.pages.length) continue;

      emit(state.copyWith(isRunning: true, currentRunningPage: pageIndex));
      try {
        final result = await _service.recognizePdfPage(
          pdfPage: pdf.pages[pageIndex],
          pageIndex: pageIndex,
          language: language,
          engineMode: engineMode,
          aiConfig: _latestAiConfig,
        );
        if (isClosed || token != _jobToken) return;

        await _service.saveCachedPage(
          docHash: docHash,
          cacheTag: cacheTag,
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
        if (engineMode == OcrEngineMode.openAiVision) {
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));
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
            engineMode: state.engineMode,
            targets: targets,
          ),
        );
      }
    }
  }

  Future<void> setEngineMode(OcrEngineMode engineMode) async {
    if (state.engineMode == engineMode) return;
    emit(state.copyWith(engineMode: engineMode, selection: null, statusError: null));
    await _saveString(_prefEngineMode, engineMode.name);

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

  void setSelection(OcrSelectionState? selection) {
    emit(state.copyWith(selection: selection));
  }

  void clearSelection() {
    if (state.selection == null) return;
    emit(state.copyWith(selection: null));
  }

  Future<String?> recognizeRegionPng(
    Uint8List pngBytes, {
    AiTutorConfig? aiConfig,
  }) => _service.recognizeRegionPng(
    pngBytes: pngBytes,
    language: state.language,
    engineMode: state.engineMode,
    aiConfig: aiConfig ?? _latestAiConfig,
  );

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
