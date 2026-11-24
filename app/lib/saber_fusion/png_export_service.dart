import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:butterfly/api/save.dart';
import 'package:flutter/foundation.dart';
import 'package:lw_file_system/lw_file_system.dart';
import 'package:lw_sysapi/lw_sysapi.dart' show SystemFileDialogs;
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import 'pdf_reading_models.dart';

class PngExportService {
  const PngExportService._();

  static String detectPaperLabel(PdfPage? page) {
    if (page == null) return 'A4';
    final w = math.min(page.width, page.height);
    final h = math.max(page.width, page.height);
    if ((w - 595).abs() <= 24 && (h - 842).abs() <= 24) return 'A4';
    if ((w - 842).abs() <= 28 && (h - 1191).abs() <= 28) return 'A3';
    if ((w - 420).abs() <= 20 && (h - 595).abs() <= 20) return 'A5';
    if ((w - 499).abs() <= 24 && (h - 709).abs() <= 24) return 'B5';
    if ((w - 612).abs() <= 24 && (h - 792).abs() <= 24) return 'Letter';
    final ratio = h / math.max(1.0, w);
    if ((ratio - 1.414).abs() < 0.08) return 'A4';
    return '${w.round()}×${h.round()}';
  }

  static Future<Uint8List?> renderCroppedPagePng({
    required PdfPage page,
    required int pageIndex,
    required PdfMarginCropConfig crop,
    double dpi = 144.0,
  }) async {
    final scale = (dpi / 72.0).clamp(1.0, 3.0);
    final fullW = math.max(1, (page.width * scale).round());
    final fullH = math.max(1, (page.height * scale).round());

    final raster = await page.render(
      width: fullW,
      height: fullH,
      fullWidth: fullW.toDouble(),
      fullHeight: fullH.toDouble(),
    );
    if (raster == null) return null;

    ui.Image? srcImage;
    try {
      srcImage = await raster.createImage();
    } finally {
      raster.dispose();
    }

    ui.Image? outImage;
    try {
      final lFrac = crop.effectiveLeftForPage(pageIndex);
      final rFrac = crop.effectiveRightForPage(pageIndex);
      final tFrac = crop.top;
      final bFrac = crop.bottom;

      final srcRect = Rect.fromLTRB(
        srcImage.width * lFrac,
        srcImage.height * tFrac,
        srcImage.width * (1.0 - rFrac),
        srcImage.height * (1.0 - bFrac),
      );
      final outW = math.max(1, srcRect.width.round());
      final outH = math.max(1, srcRect.height.round());
      final dstRect = Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(dstRect, Paint()..color = Colors.white);
      canvas.drawImageRect(
        srcImage,
        srcRect,
        dstRect,
        Paint()
          ..filterQuality = FilterQuality.high
          ..isAntiAlias = true,
      );
      final picture = recorder.endRecording();
      try {
        outImage = await picture.toImage(outW, outH);
      } finally {
        picture.dispose();
      }
      final data = await outImage.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      outImage?.dispose();
      srcImage.dispose();
    }
  }

  static Future<bool> exportCurrentPagePng(
    BuildContext context, {
    required String documentTitle,
    required PdfDocument pdf,
    required int pageIndex,
    required PdfMarginCropConfig crop,
  }) async {
    if (pageIndex < 0 || pageIndex >= pdf.pages.length) return false;
    final pngBytes = await renderCroppedPagePng(
      page: pdf.pages[pageIndex],
      pageIndex: pageIndex,
      crop: crop,
    );
    if (pngBytes == null || !context.mounted) return false;
    final safeName = sanitizeExportFileName(documentTitle);
    final share = !kIsWeb && !Platform.isWindows;
    await exportFile(
      context: context,
      bytes: pngBytes,
      mimeType: 'image/png',
      uniformTypeIdentifier: 'public.png',
      share: share,
      fileName: '${safeName}_第${pageIndex + 1}页.png',
      label: '导出本页 PNG',
    );
    return true;
  }

  static Future<String?> exportAllPagesPng(
    BuildContext context, {
    required String documentTitle,
    required PdfDocument pdf,
    required PdfMarginCropConfig crop,
    void Function(int done, int total)? onProgress,
  }) async {
    final total = pdf.pages.length;
    if (total == 0) return null;
    final safeName = sanitizeExportFileName(documentTitle);

    if (!kIsWeb) {
      final folder = await SystemFileDialogs.getDirectoryPath();
      if (folder == null || folder.trim().isEmpty) return null;
      final dir = Directory(folder);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final padWidth = total.toString().length.clamp(2, 4);
      for (var i = 0; i < total; i++) {
        final png = await renderCroppedPagePng(
          page: pdf.pages[i],
          pageIndex: i,
          crop: crop,
        );
        if (png != null) {
          final numStr = (i + 1).toString().padLeft(padWidth, '0');
          final file = File(
            '${dir.path}${Platform.pathSeparator}${safeName}_$numStr.png',
          );
          await file.writeAsBytes(png, flush: true);
        }
        onProgress?.call(i + 1, total);
      }
      return dir.path;
    }

    final archive = Archive();
    final padWidth = total.toString().length.clamp(2, 4);
    for (var i = 0; i < total; i++) {
      final png = await renderCroppedPagePng(
        page: pdf.pages[i],
        pageIndex: i,
        crop: crop,
      );
      if (png != null) {
        final numStr = (i + 1).toString().padLeft(padWidth, '0');
        archive.addFile(
          ArchiveFile('${safeName}_$numStr.png', png.length, png),
        );
      }
      onProgress?.call(i + 1, total);
    }
    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
    if (!context.mounted) return null;
    await exportFile(
      context: context,
      bytes: zipBytes,
      mimeType: 'application/zip',
      uniformTypeIdentifier: 'public.zip-archive',
      share: false,
      fileName: '${safeName}_png_pages.zip',
      label: '导出全部页 PNG',
    );
    return 'zip';
  }
}
