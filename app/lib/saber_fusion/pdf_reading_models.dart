import 'package:material_ui/material_ui.dart';

enum PdfViewLayoutMode {
  singlePage,
  twoPageBook,
  twoPageCover;

  String get label => switch (this) {
    PdfViewLayoutMode.singlePage => '单页连续',
    PdfViewLayoutMode.twoPageBook => '书本双页',
    PdfViewLayoutMode.twoPageCover => '封面+双页',
  };

  String get shortLabel => switch (this) {
    PdfViewLayoutMode.singlePage => '单页',
    PdfViewLayoutMode.twoPageBook => '双页',
    PdfViewLayoutMode.twoPageCover => '封面',
  };
}

@immutable
class PdfMarginCropConfig {
  static const double maxSideCrop = 0.35;
  static const double maxAxisSum = 0.70;

  final double top;
  final double bottom;
  final double left;
  final double right;
  final bool mirrorEvenPages;
  final bool seamlessLongDoc;
  final bool showPageShadow;
  final double pageGap;
  final PdfViewLayoutMode layoutMode;

  /// Runtime-only flag while dragging crop sliders; not persisted to disk.
  final bool showCropGuides;

  const PdfMarginCropConfig({
    this.top = 0.0,
    this.bottom = 0.0,
    this.left = 0.0,
    this.right = 0.0,
    this.mirrorEvenPages = false,
    this.seamlessLongDoc = false,
    this.showPageShadow = true,
    this.pageGap = 24.0,
    this.layoutMode = PdfViewLayoutMode.singlePage,
    this.showCropGuides = false,
  });

  /// Matches Butterfly's untouched rendering defaults for tests and vanilla docs.
  const PdfMarginCropConfig.vanilla()
    : top = 0.0,
      bottom = 0.0,
      left = 0.0,
      right = 0.0,
      mirrorEvenPages = false,
      seamlessLongDoc = false,
      showPageShadow = false,
      pageGap = 0.0,
      layoutMode = PdfViewLayoutMode.singlePage,
      showCropGuides = false;

  bool get hasCrop =>
      top > 0.001 || bottom > 0.001 || left > 0.001 || right > 0.001;

  double get effectivePageGap => seamlessLongDoc ? 0.0 : pageGap.clamp(0.0, 120.0);

  double get effectiveRowGap =>
      seamlessLongDoc ? 0.0 : (pageGap > 24.0 ? pageGap.clamp(0.0, 120.0) : 24.0);

  bool get effectiveShowShadow => seamlessLongDoc ? false : showPageShadow;

  double get effectiveBookSpineGap => seamlessLongDoc ? 0.0 : 10.0;

  double effectiveLeftForPage(int pdfPageIndex) =>
      mirrorEvenPages && pdfPageIndex.isOdd ? right : left;

  double effectiveRightForPage(int pdfPageIndex) =>
      mirrorEvenPages && pdfPageIndex.isOdd ? left : right;

  double get visibleHeightFraction => (1.0 - top - bottom).clamp(0.30, 1.0);

  double visibleWidthFractionForPage(int pdfPageIndex) =>
      (1.0 - effectiveLeftForPage(pdfPageIndex) - effectiveRightForPage(pdfPageIndex))
          .clamp(0.30, 1.0);

  Rect croppedLocalRect(
    double absWidth,
    double absHeight,
    int pdfPageIndex,
  ) {
    final l = effectiveLeftForPage(pdfPageIndex);
    final r = effectiveRightForPage(pdfPageIndex);
    return Rect.fromLTRB(
      absWidth * l,
      absHeight * top,
      absWidth * (1.0 - r),
      absHeight * (1.0 - bottom),
    );
  }

  Rect croppedWorldRect(Rect fullBounds, int pdfPageIndex) {
    final l = effectiveLeftForPage(pdfPageIndex);
    final r = effectiveRightForPage(pdfPageIndex);
    return Rect.fromLTRB(
      fullBounds.left + fullBounds.width * l,
      fullBounds.top + fullBounds.height * top,
      fullBounds.right - fullBounds.width * r,
      fullBounds.bottom - fullBounds.height * bottom,
    );
  }

  PdfMarginCropConfig withClampedCrop({
    double? top,
    double? bottom,
    double? left,
    double? right,
  }) {
    var nextTop = (top ?? this.top).clamp(0.0, maxSideCrop);
    var nextBottom = (bottom ?? this.bottom).clamp(0.0, maxSideCrop);
    if (nextTop + nextBottom > maxAxisSum) {
      if (top != null && bottom == null) {
        nextBottom = (maxAxisSum - nextTop).clamp(0.0, maxSideCrop);
      } else {
        nextTop = (maxAxisSum - nextBottom).clamp(0.0, maxSideCrop);
      }
    }

    var nextLeft = (left ?? this.left).clamp(0.0, maxSideCrop);
    var nextRight = (right ?? this.right).clamp(0.0, maxSideCrop);
    if (nextLeft + nextRight > maxAxisSum) {
      if (left != null && right == null) {
        nextRight = (maxAxisSum - nextLeft).clamp(0.0, maxSideCrop);
      } else {
        nextLeft = (maxAxisSum - nextRight).clamp(0.0, maxSideCrop);
      }
    }

    return copyWith(
      top: nextTop,
      bottom: nextBottom,
      left: nextLeft,
      right: nextRight,
    );
  }

  PdfMarginCropConfig copyWith({
    double? top,
    double? bottom,
    double? left,
    double? right,
    bool? mirrorEvenPages,
    bool? seamlessLongDoc,
    bool? showPageShadow,
    double? pageGap,
    PdfViewLayoutMode? layoutMode,
    bool? showCropGuides,
  }) {
    return PdfMarginCropConfig(
      top: (top ?? this.top).clamp(0.0, maxSideCrop),
      bottom: (bottom ?? this.bottom).clamp(0.0, maxSideCrop),
      left: (left ?? this.left).clamp(0.0, maxSideCrop),
      right: (right ?? this.right).clamp(0.0, maxSideCrop),
      mirrorEvenPages: mirrorEvenPages ?? this.mirrorEvenPages,
      seamlessLongDoc: seamlessLongDoc ?? this.seamlessLongDoc,
      showPageShadow: showPageShadow ?? this.showPageShadow,
      pageGap: (pageGap ?? this.pageGap).clamp(0.0, 120.0),
      layoutMode: layoutMode ?? this.layoutMode,
      showCropGuides: showCropGuides ?? this.showCropGuides,
    );
  }

  Map<String, dynamic> toJson() => {
    'top': top,
    'bottom': bottom,
    'left': left,
    'right': right,
    'mirrorEvenPages': mirrorEvenPages,
    'seamlessLongDoc': seamlessLongDoc,
    'showPageShadow': showPageShadow,
    'pageGap': pageGap,
    'layoutMode': layoutMode.name,
  };

  factory PdfMarginCropConfig.fromJson(Map<String, dynamic> json) {
    final layoutName = json['layoutMode'] as String?;
    final layoutMode = PdfViewLayoutMode.values.firstWhere(
      (m) => m.name == layoutName,
      orElse: () => PdfViewLayoutMode.singlePage,
    );
    final raw = PdfMarginCropConfig(
      top: (json['top'] as num?)?.toDouble() ?? 0.0,
      bottom: (json['bottom'] as num?)?.toDouble() ?? 0.0,
      left: (json['left'] as num?)?.toDouble() ?? 0.0,
      right: (json['right'] as num?)?.toDouble() ?? 0.0,
      mirrorEvenPages: json['mirrorEvenPages'] as bool? ?? false,
      seamlessLongDoc: json['seamlessLongDoc'] as bool? ?? false,
      showPageShadow: json['showPageShadow'] as bool? ?? true,
      pageGap: ((json['pageGap'] as num?)?.toDouble() ?? 24.0).clamp(0.0, 120.0),
      layoutMode: layoutMode,
    );
    return raw.withClampedCrop();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfMarginCropConfig &&
          top == other.top &&
          bottom == other.bottom &&
          left == other.left &&
          right == other.right &&
          mirrorEvenPages == other.mirrorEvenPages &&
          seamlessLongDoc == other.seamlessLongDoc &&
          showPageShadow == other.showPageShadow &&
          pageGap == other.pageGap &&
          layoutMode == other.layoutMode &&
          showCropGuides == other.showCropGuides;

  @override
  int get hashCode => Object.hash(
    top,
    bottom,
    left,
    right,
    mirrorEvenPages,
    seamlessLongDoc,
    showPageShadow,
    pageGap,
    layoutMode,
    showCropGuides,
  );
}
