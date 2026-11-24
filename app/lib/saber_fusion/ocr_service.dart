import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:butterfly/api/file_system.dart';
import 'package:butterfly/services/asset.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import 'ai_tutor_service.dart';
import 'ocr_models.dart';
import 'ocr_win_bridge.dart';
import 'study_state.dart';

class OcrService {
  static const _androidChannel = MethodChannel('butterfly.saber_fusion/ocr');
  static final _pageFilePattern = RegExp(r'^page_(\d+)\.json$');

  final Map<String, OcrPageResult> _memoryCache = {};

  bool get isNativePlatformSupported =>
      isWinNativeOcrSupported ||
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);

  static String cacheTagFor(OcrLanguage language, OcrEngineMode engineMode) =>
      engineMode == OcrEngineMode.openAiVision
      ? '${language.nativeTag}_ai'
      : language.nativeTag;

  /// Computes a sub-millisecond deterministic 16-hex fingerprint using length
  /// plus head/middle/tail slices so large 100MB+ PDFs never stall the UI isolate.
  String computeDocHash(Uint8List pdfBytes) {
    final len = pdfBytes.length;
    if (len <= 256 * 1024) {
      return sha256.convert(pdfBytes).toString().substring(0, 16);
    }
    const chunk = 64 * 1024;
    final midStart = (len ~/ 2) - (chunk ~/ 2);
    final combined = <int>[
      ...utf8.encode('len:$len:'),
      ...Uint8List.sublistView(pdfBytes, 0, chunk),
      ...Uint8List.sublistView(pdfBytes, midStart, midStart + chunk),
      ...Uint8List.sublistView(pdfBytes, len - chunk, len),
    ];
    return sha256.convert(combined).toString().substring(0, 16);
  }

  Future<Uint8List?> readPdfBytes({
    required String source,
    required NoteData document,
    required AssetService assets,
  }) async {
    final uri = Uri.tryParse(source);
    if (uri != null && (!uri.hasScheme || uri.isScheme('file'))) {
      final asset = document.getAsset(uri.path);
      if (asset != null) return asset;
    }
    return assets.computeDataFromSource(source, document);
  }

  String _memKey(String docHash, String cacheTag, int pageIndex) =>
      '${docHash}_${cacheTag}_$pageIndex';

  Future<Directory?> _resolveCacheDir(String docHash, String cacheTag) async {
    if (kIsWeb) return null;
    try {
      final base = await getButterflyDirectory();
      return Directory('$base/OcrCache/${docHash}_$cacheTag');
    } catch (_) {
      return null;
    }
  }

  Future<Set<int>> listCachedPageIndices({
    required String docHash,
    required String cacheTag,
  }) async {
    final found = <int>{};
    final memPrefix = '${docHash}_${cacheTag}_';
    for (final k in _memoryCache.keys) {
      if (k.startsWith(memPrefix)) {
        final pageIdx = int.tryParse(k.substring(memPrefix.length));
        if (pageIdx != null) found.add(pageIdx);
      }
    }
    final dir = await _resolveCacheDir(docHash, cacheTag);
    if (dir == null) return found;
    try {
      if (!await dir.exists()) return found;
      await for (final entity in dir.list(followLinks: false)) {
        final name = entity.uri.pathSegments.lastOrNull ?? '';
        final match = _pageFilePattern.firstMatch(name);
        if (match != null) {
          final idx = int.tryParse(match.group(1)!);
          if (idx != null) found.add(idx);
        }
      }
    } catch (_) {}
    return found;
  }

  Future<OcrPageResult?> loadCachedPage({
    required String docHash,
    required String cacheTag,
    required int pageIndex,
  }) async {
    final mem = _memoryCache[_memKey(docHash, cacheTag, pageIndex)];
    if (mem != null) return mem;

    final dir = await _resolveCacheDir(docHash, cacheTag);
    if (dir == null) return null;
    final file = File('${dir.path}${Platform.pathSeparator}page_$pageIndex.json');
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final parsed = OcrPageResult.fromJson(
          decoded.map((k, v) => MapEntry(k.toString(), v)),
          fromCache: true,
        );
        _memoryCache[_memKey(docHash, cacheTag, pageIndex)] = parsed;
        return parsed;
      }
    } catch (_) {
      // Ignore corrupt cache entries so page will be re-recognized.
    }
    return null;
  }

  Future<void> saveCachedPage({
    required String docHash,
    required String cacheTag,
    required OcrPageResult result,
  }) async {
    _memoryCache[_memKey(docHash, cacheTag, result.pageIndex)] = result;
    final dir = await _resolveCacheDir(docHash, cacheTag);
    if (dir == null) return;
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File(
        '${dir.path}${Platform.pathSeparator}page_${result.pageIndex}.json',
      );
      await file.writeAsString(jsonEncode(result.toJson()));
    } catch (_) {
      // Best-effort persistent disk cache.
    }
  }

  Future<void> clearCacheForDoc({
    required String docHash,
    required String cacheTag,
  }) async {
    final prefix = '${docHash}_${cacheTag}_';
    _memoryCache.removeWhere((key, _) => key.startsWith(prefix));
    final dir = await _resolveCacheDir(docHash, cacheTag);
    if (dir == null) return;
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<OcrPageResult> recognizePdfPage({
    required PdfPage pdfPage,
    required int pageIndex,
    required OcrLanguage language,
    OcrEngineMode engineMode = OcrEngineMode.localNative,
    AiTutorConfig? aiConfig,
  }) async {
    List<OcrTextLine> lines = const [];
    final maxDim = math.max(pdfPage.width, pdfPage.height);
    final targetMax = engineMode == OcrEngineMode.openAiVision ? 1280.0 : 1440.0;
    final scale = (targetMax / math.max(1.0, maxDim)).clamp(1.3, 2.2);
    final pw = math.max(1, (pdfPage.width * scale).round());
    final ph = math.max(1, (pdfPage.height * scale).round());

    if (engineMode == OcrEngineMode.openAiVision) {
      if (aiConfig == null || !aiConfig.isConfigured) {
        throw const AiTutorException('使用 OpenAI 视觉 OCR 前，请先在 AI 设置中配置接口与 Key');
      }
      final pngBytes = await _renderPagePng(pdfPage, pw, ph);
      if (pngBytes != null) {
        lines = await AiTutorService.ocrImageViaOpenAi(
          config: aiConfig,
          pngBytes: pngBytes,
          language: language,
        );
      }
    } else if (isWinNativeOcrSupported) {
      lines = await _recognizePageViaWindows(pdfPage, pw, ph, language.nativeTag);
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      lines = await _recognizePageViaAndroid(pdfPage, pw, ph, language.nativeTag);
    }

    if (lines.isEmpty && engineMode == OcrEngineMode.localNative) {
      lines = await _extractFallbackPdfTextLines(pdfPage);
    }

    return OcrPageResult(
      pageIndex: pageIndex,
      langTag: cacheTagFor(language, engineMode),
      lines: List.unmodifiable(lines),
      fromCache: false,
    );
  }

  Future<Uint8List?> _renderPagePng(PdfPage pdfPage, int width, int height) async {
    final raster = await pdfPage.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (raster == null) return null;
    ui.Image? uiImage;
    try {
      uiImage = await raster.createImage();
    } finally {
      raster.dispose();
    }
    try {
      final bytes = await uiImage.toByteData(format: ui.ImageByteFormat.png);
      return bytes?.buffer.asUint8List();
    } finally {
      uiImage.dispose();
    }
  }

  Future<List<OcrTextLine>> _recognizePageViaWindows(
    PdfPage pdfPage,
    int width,
    int height,
    String langTag,
  ) async {
    final raster = await pdfPage.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (raster == null) return const [];
    ui.Image? uiImage;
    try {
      uiImage = await raster.createImage();
    } finally {
      raster.dispose();
    }
    try {
      final bytes = await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bytes == null) return const [];
      final recognized = await recognizeWinRgba(
        rgbaBytes: bytes.buffer.asUint8List(),
        width: uiImage.width,
        height: uiImage.height,
        langTag: langTag,
      );
      return recognized ?? const [];
    } finally {
      uiImage.dispose();
    }
  }

  Future<List<OcrTextLine>> _recognizePageViaAndroid(
    PdfPage pdfPage,
    int width,
    int height,
    String langTag,
  ) async {
    final pngBytes = await _renderPagePng(pdfPage, width, height);
    if (pngBytes == null) return const [];
    return _invokeAndroidPng(pngBytes, langTag);
  }

  Future<List<OcrTextLine>> _invokeAndroidPng(
    Uint8List pngBytes,
    String langTag,
  ) async {
    final raw = await _androidChannel.invokeMethod<List<dynamic>>(
      'recognizePng',
      <String, dynamic>{'png': pngBytes, 'lang': langTag},
    );
    if (raw == null) return const [];
    final out = <OcrTextLine>[];
    for (final item in raw) {
      if (item is Map) {
        out.add(
          OcrTextLine.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
        );
      }
    }
    return out;
  }

  Future<List<OcrTextLine>> _extractFallbackPdfTextLines(PdfPage pdfPage) async {
    try {
      final rawText = await pdfPage.loadText();
      final text = rawText?.fullText ?? '';
      if (text.trim().isEmpty) return const [];
      final split = text
          .split(RegExp(r'\r?\n'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(growable: false);
      if (split.isEmpty) return const [];
      final count = split.length;
      final out = <OcrTextLine>[];
      for (var i = 0; i < count; i++) {
        final top = (0.04 + (i / math.max(1, count)) * 0.90).clamp(0.0, 0.98);
        final height = (0.85 / math.max(1, count)).clamp(0.015, 0.06);
        final bottom = (top + height).clamp(top + 0.01, 0.99);
        out.add(
          OcrTextLine(
            text: split[i],
            left: 0.06,
            top: top,
            right: 0.94,
            bottom: bottom,
            words: [
              OcrWordBox(
                text: split[i],
                left: 0.06,
                top: top,
                right: 0.94,
                bottom: bottom,
              ),
            ],
          ),
        );
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<String?> recognizeRegionPng({
    required Uint8List pngBytes,
    required OcrLanguage language,
    OcrEngineMode engineMode = OcrEngineMode.localNative,
    AiTutorConfig? aiConfig,
  }) async {
    if (engineMode == OcrEngineMode.openAiVision &&
        aiConfig != null &&
        aiConfig.isConfigured) {
      final lines = await AiTutorService.ocrImageViaOpenAi(
        config: aiConfig,
        pngBytes: pngBytes,
        language: language,
      );
      final joined = lines.map((l) => l.text).join('\n').trim();
      return joined.isEmpty ? null : joined;
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final lines = await _invokeAndroidPng(pngBytes, language.nativeTag);
      final joined = lines.map((l) => l.text).join('\n').trim();
      return joined.isEmpty ? null : joined;
    }
    if (isWinNativeOcrSupported) {
      final codec = await ui.instantiateImageCodec(pngBytes);
      ui.Image? image;
      try {
        final frame = await codec.getNextFrame();
        image = frame.image;
        final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (rgba == null) return null;
        final lines = await recognizeWinRgba(
          rgbaBytes: rgba.buffer.asUint8List(),
          width: image.width,
          height: image.height,
          langTag: language.nativeTag,
        );
        if (lines == null) return null;
        final joined = lines.map((l) => l.text).join('\n').trim();
        return joined.isEmpty ? null : joined;
      } finally {
        image?.dispose();
        codec.dispose();
      }
    }
    return null;
  }
}
