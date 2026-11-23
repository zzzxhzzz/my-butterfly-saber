import 'dart:math';
import 'dart:typed_data';

import 'package:butterfly/helpers/element.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:lw_file_system/lw_file_system.dart';
import 'package:material_ui/material_ui.dart';

@immutable
class PdfWindowSession {
  final String id;
  final String title;
  final Uint8List pdfBytes;
  final String? diskPath;
  final AssetLocation? assetLocation;
  final Offset offset;
  final Size size;
  final bool minimized;
  final bool pinned;
  final double opacity;
  final bool twoPageMode;
  final bool applyGlobalCrop;
  final int currentPage;
  final int totalPages;
  final double zoom;
  final int zOrder;

  const PdfWindowSession({
    required this.id,
    required this.title,
    required this.pdfBytes,
    this.diskPath,
    this.assetLocation,
    required this.offset,
    required this.size,
    this.minimized = false,
    this.pinned = false,
    this.opacity = 1.0,
    this.twoPageMode = false,
    this.applyGlobalCrop = true,
    this.currentPage = 0,
    this.totalPages = 0,
    this.zoom = 1.0,
    this.zOrder = 1,
  });

  PdfWindowSession copyWith({
    String? title,
    String? diskPath,
    AssetLocation? assetLocation,
    Offset? offset,
    Size? size,
    bool? minimized,
    bool? pinned,
    double? opacity,
    bool? twoPageMode,
    bool? applyGlobalCrop,
    int? currentPage,
    int? totalPages,
    double? zoom,
    int? zOrder,
  }) {
    return PdfWindowSession(
      id: id,
      title: title ?? this.title,
      pdfBytes: pdfBytes,
      diskPath: diskPath ?? this.diskPath,
      assetLocation: assetLocation ?? this.assetLocation,
      offset: offset ?? this.offset,
      size: size ?? this.size,
      minimized: minimized ?? this.minimized,
      pinned: pinned ?? this.pinned,
      opacity: opacity ?? this.opacity,
      twoPageMode: twoPageMode ?? this.twoPageMode,
      applyGlobalCrop: applyGlobalCrop ?? this.applyGlobalCrop,
      currentPage: currentPage ?? this.currentPage,
      totalPages: totalPages ?? this.totalPages,
      zoom: zoom ?? this.zoom,
      zOrder: zOrder ?? this.zOrder,
    );
  }
}

@immutable
class MultiPdfWindowState {
  final List<PdfWindowSession> windows;
  final bool dockVisible;
  final int nextZOrder;

  const MultiPdfWindowState({
    this.windows = const [],
    this.dockVisible = false,
    this.nextZOrder = 1,
  });

  MultiPdfWindowState copyWith({
    List<PdfWindowSession>? windows,
    bool? dockVisible,
    int? nextZOrder,
  }) {
    return MultiPdfWindowState(
      windows: windows ?? this.windows,
      dockVisible: dockVisible ?? this.dockVisible,
      nextZOrder: nextZOrder ?? this.nextZOrder,
    );
  }
}

class MultiPdfWindowCubit extends Cubit<MultiPdfWindowState> {
  MultiPdfWindowCubit() : super(const MultiPdfWindowState());

  void showDock() {
    if (!state.dockVisible) {
      emit(state.copyWith(dockVisible: true));
    }
  }

  void hideDock() {
    if (state.dockVisible) {
      emit(state.copyWith(dockVisible: false));
    }
  }

  void toggleDock() {
    emit(state.copyWith(dockVisible: !state.dockVisible));
  }

  void openPdfBytes({
    required String title,
    required Uint8List bytes,
    String? diskPath,
    AssetLocation? assetLocation,
    int initialPage = 0,
    Size viewportSize = const Size(1280, 800),
  }) {
    final cleanTitle = title.trim().isEmpty ? 'PDF 参考窗' : title.trim();
    final existingIdx = state.windows.indexWhere((w) {
      if (diskPath != null &&
          diskPath.isNotEmpty &&
          w.diskPath == diskPath) {
        return true;
      }
      if (assetLocation != null &&
          assetLocation.path.isNotEmpty &&
          w.assetLocation?.path == assetLocation.path &&
          w.assetLocation?.remote == assetLocation.remote) {
        return true;
      }
      return w.title == cleanTitle && w.pdfBytes.length == bytes.length;
    });

    if (existingIdx >= 0) {
      final list = List<PdfWindowSession>.from(state.windows);
      final target = list[existingIdx];
      list[existingIdx] = target.copyWith(
        minimized: false,
        zOrder: state.nextZOrder,
      );
      emit(
        state.copyWith(
          windows: list,
          dockVisible: true,
          nextZOrder: state.nextZOrder + 1,
        ),
      );
      return;
    }

    final isCompact = viewportSize.width < 700;
    final defaultWidth =
        min(isCompact ? viewportSize.width * 0.88 : 500.0, viewportSize.width - 24)
            .clamp(280.0, 760.0);
    final defaultHeight =
        min(isCompact ? viewportSize.height * 0.72 : 590.0, viewportSize.height - 88)
            .clamp(240.0, 780.0);

    final cascade = state.windows.length % 6;
    final maxX = max(16.0, viewportSize.width - defaultWidth - 16.0);
    final maxY = max(56.0, viewportSize.height - defaultHeight - 64.0);
    final startX = (88.0 + cascade * 36.0).clamp(16.0, maxX);
    final startY = (68.0 + cascade * 30.0).clamp(56.0, maxY);

    final session = PdfWindowSession(
      id: createUniqueId(),
      title: cleanTitle,
      pdfBytes: bytes,
      diskPath: diskPath,
      assetLocation: assetLocation,
      offset: Offset(startX, startY),
      size: Size(defaultWidth, defaultHeight),
      currentPage: max(0, initialPage),
      zOrder: state.nextZOrder,
    );

    emit(
      state.copyWith(
        windows: [...state.windows, session],
        dockVisible: true,
        nextZOrder: state.nextZOrder + 1,
      ),
    );
  }

  bool openFromBflyBytes({
    required String title,
    required Uint8List bflyBytes,
    String? diskPath,
    AssetLocation? assetLocation,
    Size viewportSize = const Size(1280, 800),
  }) {
    try {
      final data = NoteData.fromData(bflyBytes);
      for (final pageName in data.getPages(true)) {
        final page = data.getPage(pageName);
        if (page == null) continue;
        for (final el in page.content.whereType<PdfElement>()) {
          final pdfBytes = getDataFromSource(data, el.source);
          if (pdfBytes != null && pdfBytes.isNotEmpty) {
            openPdfBytes(
              title: title,
              bytes: pdfBytes,
              diskPath: diskPath,
              assetLocation: assetLocation,
              viewportSize: viewportSize,
            );
            return true;
          }
        }
      }
      final allAssets = data.getAllAssets();
      for (final entry in allAssets.entries) {
        final raw = entry.value;
        if (raw.length >= 4 &&
            raw[0] == 0x25 &&
            raw[1] == 0x50 &&
            raw[2] == 0x44 &&
            raw[3] == 0x46) {
          openPdfBytes(
            title: title,
            bytes: raw,
            diskPath: diskPath,
            assetLocation: assetLocation,
            viewportSize: viewportSize,
          );
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  void _update(
    String id,
    PdfWindowSession Function(PdfWindowSession current) mapper,
  ) {
    final idx = state.windows.indexWhere((w) => w.id == id);
    if (idx < 0) return;
    final list = List<PdfWindowSession>.from(state.windows);
    list[idx] = mapper(list[idx]);
    emit(state.copyWith(windows: list));
  }

  void focusWindow(String id) {
    final idx = state.windows.indexWhere((w) => w.id == id);
    if (idx < 0) return;
    final current = state.windows[idx];
    if (!current.minimized && current.zOrder == state.nextZOrder - 1) return;
    final list = List<PdfWindowSession>.from(state.windows);
    list[idx] = current.copyWith(
      minimized: false,
      zOrder: state.nextZOrder,
    );
    emit(
      state.copyWith(
        windows: list,
        nextZOrder: state.nextZOrder + 1,
      ),
    );
  }

  void moveWindow(String id, Offset delta, Size viewportBounds) {
    _update(id, (w) {
      final maxX = max(12.0, viewportBounds.width - 140.0);
      final maxY = max(56.0, viewportBounds.height - 92.0);
      final nextX = (w.offset.dx + delta.dx).clamp(
        -(w.size.width - 140.0),
        maxX,
      );
      final nextY = (w.offset.dy + delta.dy).clamp(48.0, maxY);
      return w.copyWith(offset: Offset(nextX, nextY));
    });
  }

  void resizeWindow(String id, Offset delta, Size viewportBounds) {
    _update(id, (w) {
      final maxW = max(300.0, viewportBounds.width - 24.0);
      final maxH = max(240.0, viewportBounds.height - 76.0);
      final nextW = (w.size.width + delta.dx).clamp(300.0, maxW);
      final nextH = (w.size.height + delta.dy).clamp(240.0, maxH);
      return w.copyWith(size: Size(nextW, nextH));
    });
  }

  void toggleMinimize(String id) {
    final idx = state.windows.indexWhere((w) => w.id == id);
    if (idx < 0) return;
    final target = state.windows[idx];
    final nextMin = !target.minimized;
    final list = List<PdfWindowSession>.from(state.windows);
    list[idx] = target.copyWith(
      minimized: nextMin,
      zOrder: nextMin ? target.zOrder : state.nextZOrder,
    );
    emit(
      state.copyWith(
        windows: list,
        nextZOrder: nextMin ? state.nextZOrder : state.nextZOrder + 1,
      ),
    );
  }

  void togglePin(String id) {
    _update(id, (w) => w.copyWith(pinned: !w.pinned));
  }

  void cycleOpacity(String id) {
    _update(id, (w) {
      final next = w.opacity > 0.92
          ? 0.85
          : (w.opacity > 0.72 ? 0.65 : 1.0);
      return w.copyWith(opacity: next);
    });
  }

  void toggleTwoPage(String id) {
    _update(id, (w) => w.copyWith(twoPageMode: !w.twoPageMode));
  }

  void toggleApplyCrop(String id) {
    _update(id, (w) => w.copyWith(applyGlobalCrop: !w.applyGlobalCrop));
  }

  void setPage(String id, int page, {int? totalPages}) {
    _update(id, (w) {
      final total = totalPages ?? w.totalPages;
      final clamped = total > 0 ? page.clamp(0, total - 1) : max(0, page);
      return w.copyWith(currentPage: clamped, totalPages: total);
    });
  }

  void setZoom(String id, double zoom) {
    _update(id, (w) => w.copyWith(zoom: zoom.clamp(0.5, 2.5)));
  }

  void closeWindow(String id) {
    final remaining = state.windows.where((w) => w.id != id).toList();
    emit(
      state.copyWith(
        windows: remaining,
        dockVisible: remaining.isNotEmpty || state.dockVisible,
      ),
    );
  }

  void minimizeAll() {
    emit(
      state.copyWith(
        windows: [for (final w in state.windows) w.copyWith(minimized: true)],
      ),
    );
  }

  void restoreAll() {
    var z = state.nextZOrder;
    emit(
      state.copyWith(
        windows: [
          for (final w in state.windows) w.copyWith(minimized: false, zOrder: z++),
        ],
        nextZOrder: z,
      ),
    );
  }

  void closeAll() {
    emit(const MultiPdfWindowState());
  }

  void tileWindows(Size viewportSize) {
    if (state.windows.isEmpty) return;
    final list = List<PdfWindowSession>.from(state.windows);
    final count = list.length;
    final cols = count <= 1
        ? 1
        : (viewportSize.width >= 900 ? min(3, count) : min(2, count));
    final rows = (count / cols).ceil();
    const topMargin = 62.0;
    const bottomDockSpace = 68.0;
    const gap = 10.0;
    final usableW = max(320.0, viewportSize.width - 24.0);
    final usableH = max(260.0, viewportSize.height - topMargin - bottomDockSpace);
    final cellW = max(280.0, (usableW - gap * (cols - 1)) / cols);
    final cellH = max(240.0, (usableH - gap * (rows - 1)) / rows);

    var z = state.nextZOrder;
    for (var i = 0; i < count; i++) {
      final col = i % cols;
      final row = i ~/ cols;
      final x = 12.0 + col * (cellW + gap);
      final y = topMargin + row * (cellH + gap);
      list[i] = list[i].copyWith(
        minimized: false,
        offset: Offset(x, y),
        size: Size(cellW, cellH),
        zOrder: z++,
      );
    }
    emit(
      state.copyWith(
        windows: list,
        dockVisible: true,
        nextZOrder: z,
      ),
    );
  }
}

MultiPdfWindowCubit? maybeMultiPdfWindowCubit(BuildContext context) {
  try {
    return BlocProvider.of<MultiPdfWindowCubit>(context);
  } catch (_) {
    return null;
  }
}
