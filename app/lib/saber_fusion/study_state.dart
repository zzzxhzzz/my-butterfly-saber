import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'color_filters.dart';
import 'pdf_reading_models.dart';

enum StudyPanelTab {
  toc,
  thumbnails,
  search,
  crop,
  aiTutor,
  mistakes;

  String get label => switch (this) {
    StudyPanelTab.toc => '目录',
    StudyPanelTab.thumbnails => '页码',
    StudyPanelTab.search => '搜题',
    StudyPanelTab.crop => '页边距裁剪',
    StudyPanelTab.aiTutor => 'AI助教',
    StudyPanelTab.mistakes => '错题本',
  };
}

@immutable
class AiTutorConfig {
  static const defaultBaseUrl = 'https://api.openai.com/v1';
  static const defaultModel = 'gpt-4o-mini';
  static const defaultSystemPrompt =
      '你是一位耐心的理科教材与试卷辅导老师。请用清晰简洁的中文逐步解答学生框选的题目或知识点，'
      '必要时使用 LaTeX 数学公式（行内公式用 \$...\$，独立公式用 \$\$...\$\$）。';

  final String baseUrl;
  final String model;
  final String apiKey;
  final String systemPrompt;

  const AiTutorConfig({
    this.baseUrl = defaultBaseUrl,
    this.model = defaultModel,
    this.apiKey = '',
    this.systemPrompt = defaultSystemPrompt,
  });

  bool get isConfigured =>
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty;

  AiTutorConfig copyWith({
    String? baseUrl,
    String? model,
    String? apiKey,
    String? systemPrompt,
  }) => AiTutorConfig(
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    apiKey: apiKey ?? this.apiKey,
    systemPrompt: systemPrompt ?? this.systemPrompt,
  );
}

@immutable
class SnippedRegion {
  final Uint8List pngBytes;
  final Rect canvasRect;
  final int? pdfPageNumber;
  final String documentName;

  const SnippedRegion({
    required this.pngBytes,
    required this.canvasRect,
    this.pdfPageNumber,
    this.documentName = '',
  });
}

@immutable
class StudyModeState {
  final CanvasColorFilterMode colorMode;
  final bool perfectHighlighter;
  final bool studyToolbarMode;
  final bool studyPanelOpen;
  final StudyPanelTab activeTab;
  final bool aiSnippingMode;
  final SnippedRegion? pendingSnip;
  final AiTutorConfig aiConfig;
  final PdfMarginCropConfig pdfCrop;

  const StudyModeState({
    this.colorMode = CanvasColorFilterMode.normal,
    this.perfectHighlighter = true,
    this.studyToolbarMode = false,
    this.studyPanelOpen = false,
    this.activeTab = StudyPanelTab.toc,
    this.aiSnippingMode = false,
    this.pendingSnip,
    this.aiConfig = const AiTutorConfig(),
    this.pdfCrop = const PdfMarginCropConfig(),
  });

  static const _unset = Object();

  StudyModeState copyWith({
    CanvasColorFilterMode? colorMode,
    bool? perfectHighlighter,
    bool? studyToolbarMode,
    bool? studyPanelOpen,
    StudyPanelTab? activeTab,
    bool? aiSnippingMode,
    Object? pendingSnip = _unset,
    AiTutorConfig? aiConfig,
    PdfMarginCropConfig? pdfCrop,
  }) => StudyModeState(
    colorMode: colorMode ?? this.colorMode,
    perfectHighlighter: perfectHighlighter ?? this.perfectHighlighter,
    studyToolbarMode: studyToolbarMode ?? this.studyToolbarMode,
    studyPanelOpen: studyPanelOpen ?? this.studyPanelOpen,
    activeTab: activeTab ?? this.activeTab,
    aiSnippingMode: aiSnippingMode ?? this.aiSnippingMode,
    pendingSnip: identical(pendingSnip, _unset)
        ? this.pendingSnip
        : pendingSnip as SnippedRegion?,
    aiConfig: aiConfig ?? this.aiConfig,
    pdfCrop: pdfCrop ?? this.pdfCrop,
  );
}

class StudyModeCubit extends Cubit<StudyModeState> {
  static const _prefColorMode = 'saber_fusion.color_mode';
  static const _prefPerfectHighlighter = 'saber_fusion.perfect_highlighter';
  static const _prefStudyToolbar = 'saber_fusion.study_toolbar';
  static const _prefAiBaseUrl = 'saber_fusion.ai_base_url';
  static const _prefAiModel = 'saber_fusion.ai_model';
  static const _prefAiPrompt = 'saber_fusion.ai_system_prompt';
  static const _prefPdfCrop = 'saber_fusion.pdf_crop_v1';
  static const _secureAiKey = 'saber_fusion.ai_api_key';

  final FlutterSecureStorage _secureStorage;
  bool _loaded = false;

  StudyModeCubit({FlutterSecureStorage? secureStorage})
    : _secureStorage = secureStorage ?? const FlutterSecureStorage(),
      super(const StudyModeState());

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final colorName = prefs.getString(_prefColorMode);
      final colorMode = CanvasColorFilterMode.values.firstWhere(
        (m) => m.name == colorName,
        orElse: () => CanvasColorFilterMode.normal,
      );
      final perfectHighlighter = prefs.getBool(_prefPerfectHighlighter) ?? true;
      final studyToolbarMode = prefs.getBool(_prefStudyToolbar) ?? false;
      final baseUrl = prefs.getString(_prefAiBaseUrl) ?? AiTutorConfig.defaultBaseUrl;
      final model = prefs.getString(_prefAiModel) ?? AiTutorConfig.defaultModel;
      final prompt =
          prefs.getString(_prefAiPrompt) ?? AiTutorConfig.defaultSystemPrompt;
      var pdfCrop = const PdfMarginCropConfig();
      final cropRaw = prefs.getString(_prefPdfCrop);
      if (cropRaw != null && cropRaw.isNotEmpty) {
        try {
          final decoded = jsonDecode(cropRaw);
          if (decoded is Map<String, dynamic>) {
            pdfCrop = PdfMarginCropConfig.fromJson(decoded);
          }
        } catch (_) {}
      }
      var apiKey = '';
      try {
        apiKey = await _secureStorage.read(key: _secureAiKey) ?? '';
      } catch (_) {}
      if (!isClosed) {
        emit(
          state.copyWith(
            colorMode: colorMode,
            perfectHighlighter: perfectHighlighter,
            studyToolbarMode: studyToolbarMode,
            pdfCrop: pdfCrop,
            aiConfig: AiTutorConfig(
              baseUrl: baseUrl,
              model: model,
              apiKey: apiKey,
              systemPrompt: prompt,
            ),
          ),
        );
      }
    } catch (_) {
      // Ignore storage initialization failures in constrained test environments.
    }
  }

  Future<void> _savePref(Future<void> Function(SharedPreferences prefs) fn) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await fn(prefs);
    } catch (_) {}
  }

  void cycleColorMode() {
    setColorMode(state.colorMode.next);
  }

  void setColorMode(CanvasColorFilterMode mode) {
    emit(state.copyWith(colorMode: mode));
    unawaited(_savePref((p) => p.setString(_prefColorMode, mode.name)));
  }

  void togglePerfectHighlighter() {
    final next = !state.perfectHighlighter;
    emit(state.copyWith(perfectHighlighter: next));
    unawaited(_savePref((p) => p.setBool(_prefPerfectHighlighter, next)));
  }

  void toggleStudyToolbarMode() {
    final next = !state.studyToolbarMode;
    emit(state.copyWith(studyToolbarMode: next));
    unawaited(_savePref((p) => p.setBool(_prefStudyToolbar, next)));
  }

  void setStudyToolbarMode(bool enabled) {
    if (state.studyToolbarMode == enabled) return;
    emit(state.copyWith(studyToolbarMode: enabled));
    unawaited(_savePref((p) => p.setBool(_prefStudyToolbar, enabled)));
  }

  void toggleStudyPanel([StudyPanelTab? tab]) {
    if (tab != null) {
      final shouldClose = state.studyPanelOpen && state.activeTab == tab;
      emit(
        state.copyWith(
          studyPanelOpen: !shouldClose,
          activeTab: tab,
        ),
      );
      return;
    }
    emit(state.copyWith(studyPanelOpen: !state.studyPanelOpen));
  }

  void openStudyPanel(StudyPanelTab tab) {
    emit(state.copyWith(studyPanelOpen: true, activeTab: tab));
  }

  void closeStudyPanel() {
    if (!state.studyPanelOpen) return;
    emit(state.copyWith(studyPanelOpen: false));
  }

  void setAiSnippingMode(bool enabled) {
    emit(state.copyWith(aiSnippingMode: enabled));
  }

  void setPendingSnip(SnippedRegion? snip) {
    emit(state.copyWith(pendingSnip: snip));
  }

  Future<void> updateAiConfig(AiTutorConfig config) async {
    emit(state.copyWith(aiConfig: config));
    await _savePref((prefs) async {
      await prefs.setString(_prefAiBaseUrl, config.baseUrl);
      await prefs.setString(_prefAiModel, config.model);
      await prefs.setString(_prefAiPrompt, config.systemPrompt);
    });
    try {
      if (config.apiKey.isEmpty) {
        await _secureStorage.delete(key: _secureAiKey);
      } else {
        await _secureStorage.write(key: _secureAiKey, value: config.apiKey);
      }
    } catch (_) {}
  }

  void updatePdfCrop(PdfMarginCropConfig next, {bool persist = true}) {
    emit(state.copyWith(pdfCrop: next));
    if (persist) {
      unawaited(
        _savePref((p) => p.setString(_prefPdfCrop, jsonEncode(next.toJson()))),
      );
    }
  }

  void setPdfLayoutMode(PdfViewLayoutMode mode) {
    updatePdfCrop(state.pdfCrop.copyWith(layoutMode: mode));
  }

  void toggleTwoPageBookMode() {
    final nextMode = switch (state.pdfCrop.layoutMode) {
      PdfViewLayoutMode.singlePage => PdfViewLayoutMode.twoPageBook,
      PdfViewLayoutMode.twoPageBook => PdfViewLayoutMode.twoPageCover,
      PdfViewLayoutMode.twoPageCover => PdfViewLayoutMode.singlePage,
    };
    setPdfLayoutMode(nextMode);
  }

  void toggleSeamlessLongDoc() {
    updatePdfCrop(
      state.pdfCrop.copyWith(seamlessLongDoc: !state.pdfCrop.seamlessLongDoc),
    );
  }

  void resetPdfCrop() {
    updatePdfCrop(
      PdfMarginCropConfig(layoutMode: state.pdfCrop.layoutMode),
    );
  }
}

StudyModeCubit? maybeStudyModeCubit(BuildContext context) {
  try {
    return BlocProvider.of<StudyModeCubit>(context);
  } catch (_) {
    return null;
  }
}
