import 'package:material_ui/material_ui.dart';

enum OcrLanguage {
  zhEn,
  zhOnly,
  enOnly,
  jaEn;

  String get label => switch (this) {
    OcrLanguage.zhEn => '中文 + 英文',
    OcrLanguage.zhOnly => '仅中文',
    OcrLanguage.enOnly => '仅英文',
    OcrLanguage.jaEn => '日文 + 英文',
  };

  String get nativeTag => switch (this) {
    OcrLanguage.zhEn => 'zh_en',
    OcrLanguage.zhOnly => 'zh',
    OcrLanguage.enOnly => 'en',
    OcrLanguage.jaEn => 'ja',
  };
}

enum OcrScope {
  entireDocument,
  progressive;

  String get label => switch (this) {
    OcrScope.entireDocument => '整个文档',
    OcrScope.progressive => '渐进式',
  };
}

@immutable
class OcrWordBox {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  const OcrWordBox({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  Rect toWorldRect(Rect pageBounds) => Rect.fromLTRB(
    pageBounds.left + pageBounds.width * left,
    pageBounds.top + pageBounds.height * top,
    pageBounds.left + pageBounds.width * right,
    pageBounds.top + pageBounds.height * bottom,
  );

  Map<String, dynamic> toJson() => {
    't': text,
    'l': left,
    'tp': top,
    'r': right,
    'b': bottom,
  };

  factory OcrWordBox.fromJson(Map<String, dynamic> json) => OcrWordBox(
    text: (json['t'] as String?) ?? '',
    left: ((json['l'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
    top: ((json['tp'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
    right: ((json['r'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
    bottom: ((json['b'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
  );
}

@immutable
class OcrTextLine {
  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
  final List<OcrWordBox> words;

  const OcrTextLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.words = const [],
  });

  Rect toWorldRect(Rect pageBounds) => Rect.fromLTRB(
    pageBounds.left + pageBounds.width * left,
    pageBounds.top + pageBounds.height * top,
    pageBounds.left + pageBounds.width * right,
    pageBounds.top + pageBounds.height * bottom,
  );

  Map<String, dynamic> toJson() => {
    'text': text,
    'l': left,
    't': top,
    'r': right,
    'b': bottom,
    if (words.isNotEmpty) 'words': [for (final w in words) w.toJson()],
  };

  factory OcrTextLine.fromJson(Map<String, dynamic> json) {
    final rawWords = json['words'];
    final words = <OcrWordBox>[];
    if (rawWords is List) {
      for (final item in rawWords) {
        if (item is Map) {
          words.add(
            OcrWordBox.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
    }
    return OcrTextLine(
      text: (json['text'] as String?) ?? '',
      left: ((json['l'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      top: ((json['t'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      right: ((json['r'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      bottom: ((json['b'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      words: List.unmodifiable(words),
    );
  }
}

@immutable
class OcrPageResult {
  final int pageIndex;
  final String langTag;
  final List<OcrTextLine> lines;
  final bool fromCache;

  const OcrPageResult({
    required this.pageIndex,
    required this.langTag,
    required this.lines,
    this.fromCache = false,
  });

  String get fullText => lines.map((e) => e.text).join('\n');

  Map<String, dynamic> toJson() => {
    'pageIndex': pageIndex,
    'langTag': langTag,
    'lines': [for (final line in lines) line.toJson()],
  };

  factory OcrPageResult.fromJson(
    Map<String, dynamic> json, {
    bool fromCache = true,
  }) {
    final rawLines = json['lines'];
    final parsed = <OcrTextLine>[];
    if (rawLines is List) {
      for (final item in rawLines) {
        if (item is Map) {
          parsed.add(
            OcrTextLine.fromJson(
              item.map((k, v) => MapEntry(k.toString(), v)),
            ),
          );
        }
      }
    }
    return OcrPageResult(
      pageIndex: (json['pageIndex'] as num?)?.toInt() ?? 0,
      langTag: (json['langTag'] as String?) ?? 'zh_en',
      lines: List.unmodifiable(parsed),
      fromCache: fromCache,
    );
  }
}

@immutable
class OcrSelectionState {
  final String pdfSource;
  final int pageIndex;
  final String text;
  final List<Rect> worldRects;
  final Offset menuAnchorLocal;

  const OcrSelectionState({
    required this.pdfSource,
    required this.pageIndex,
    required this.text,
    required this.worldRects,
    required this.menuAnchorLocal,
  });

  bool get isNotEmpty => text.trim().isNotEmpty && worldRects.isNotEmpty;
}

@immutable
class OcrState {
  static const _unset = Object();

  final String? activePdfSource;
  final String? docHash;
  final int totalPages;
  final int completedPages;
  final int cacheHitPages;
  final bool isRunning;
  final int? currentRunningPage;
  final bool textLayerEnabled;
  final bool whiteBgVisible;
  final double whiteBgOpacity;
  final OcrLanguage language;
  final OcrScope scope;
  final Map<int, OcrPageResult> pages;
  final OcrSelectionState? selection;
  final String? statusError;

  const OcrState({
    this.activePdfSource,
    this.docHash,
    this.totalPages = 0,
    this.completedPages = 0,
    this.cacheHitPages = 0,
    this.isRunning = false,
    this.currentRunningPage,
    this.textLayerEnabled = true,
    this.whiteBgVisible = false,
    this.whiteBgOpacity = 1.0,
    this.language = OcrLanguage.zhEn,
    this.scope = OcrScope.entireDocument,
    this.pages = const {},
    this.selection,
    this.statusError,
  });

  bool get allCompleted => totalPages > 0 && completedPages >= totalPages && !isRunning;

  double get progress =>
      totalPages > 0 ? (completedPages / totalPages).clamp(0.0, 1.0) : 0.0;

  OcrState copyWith({
    Object? activePdfSource = _unset,
    Object? docHash = _unset,
    int? totalPages,
    int? completedPages,
    int? cacheHitPages,
    bool? isRunning,
    Object? currentRunningPage = _unset,
    bool? textLayerEnabled,
    bool? whiteBgVisible,
    double? whiteBgOpacity,
    OcrLanguage? language,
    OcrScope? scope,
    Map<int, OcrPageResult>? pages,
    Object? selection = _unset,
    Object? statusError = _unset,
  }) => OcrState(
    activePdfSource: identical(activePdfSource, _unset)
        ? this.activePdfSource
        : activePdfSource as String?,
    docHash: identical(docHash, _unset) ? this.docHash : docHash as String?,
    totalPages: totalPages ?? this.totalPages,
    completedPages: completedPages ?? this.completedPages,
    cacheHitPages: cacheHitPages ?? this.cacheHitPages,
    isRunning: isRunning ?? this.isRunning,
    currentRunningPage: identical(currentRunningPage, _unset)
        ? this.currentRunningPage
        : currentRunningPage as int?,
    textLayerEnabled: textLayerEnabled ?? this.textLayerEnabled,
    whiteBgVisible: whiteBgVisible ?? this.whiteBgVisible,
    whiteBgOpacity: (whiteBgOpacity ?? this.whiteBgOpacity).clamp(0.0, 1.0),
    language: language ?? this.language,
    scope: scope ?? this.scope,
    pages: pages ?? this.pages,
    selection: identical(selection, _unset)
        ? this.selection
        : selection as OcrSelectionState?,
    statusError: identical(statusError, _unset)
        ? this.statusError
        : statusError as String?,
  );
}
