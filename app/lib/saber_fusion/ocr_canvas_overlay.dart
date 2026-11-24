import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'ocr_cubit.dart';
import 'ocr_models.dart';
import 'pdf_reading_models.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';
import 'ying_pdf_theme.dart';

bool _isAsciiAlnum(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7A);

String _joinWordsSmart(List<String> parts) {
  final buf = StringBuffer();
  for (final raw in parts) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    if (buf.isNotEmpty) {
      final prevStr = buf.toString();
      final prevCode = prevStr.codeUnitAt(prevStr.length - 1);
      final nextCode = part.codeUnitAt(0);
      if (_isAsciiAlnum(prevCode) && _isAsciiAlnum(nextCode)) {
        buf.write(' ');
      }
    }
    buf.write(part);
  }
  return buf.toString();
}

Future<bool> insertTextExcerptToCanvas(
  BuildContext context, {
  required String text,
  Rect? anchorWorldRect,
}) async {
  final clean = text.trim();
  if (clean.isEmpty) return false;
  final bloc = context.read<DocumentBloc>();
  final docState = bloc.state;
  if (docState is! DocumentLoadSuccess) return false;

  final transform = context.read<TransformCubit>().state;
  final screenSize = MediaQuery.sizeOf(context);
  final fallbackPos = transform.localToGlobal(
    Offset(screenSize.width * 0.45, screenSize.height * 0.35),
  );
  final insertPoint = anchorWorldRect != null
      ? math.Point<double>(anchorWorldRect.right + 28, anchorWorldRect.top)
      : math.Point<double>(fallbackPos.dx, fallbackPos.dy);

  final element = MarkdownElement(
    id: createUniqueId(),
    position: insertPoint,
    scale: 1.0,
    text: clean,
    constraint: const ElementConstraint(size: 460),
    foreground: SRGBColor.black,
    collection: docState.currentCollection,
  );

  bloc.add(
    ElementsCreated(
      [element],
      pageName: docState.pageName,
      layer: docState.currentLayer,
    ),
  );
  maybeStudyModeCubit(context)?.incrementCanvasExcerptCount();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已添加摘录到画布（可在右上角切到「画布」整理）'),
        duration: Duration(seconds: 2),
      ),
    );
  }
  return true;
}

Future<bool> insertImageExcerptToCanvas(
  BuildContext context, {
  required Uint8List pngBytes,
  Rect? anchorWorldRect,
}) async {
  if (pngBytes.isEmpty) return false;
  final bloc = context.read<DocumentBloc>();
  final docState = bloc.state;
  if (docState is! DocumentLoadSuccess) return false;

  final codec = await ui.instantiateImageCodec(pngBytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  final rawWidth = image.width.toDouble();
  final rawHeight = image.height.toDouble();
  image.dispose();
  codec.dispose();

  if (rawWidth <= 0 || rawHeight <= 0 || !context.mounted) return false;
  final dataUri = Uri.dataFromBytes(pngBytes, mimeType: 'image/png').toString();

  final targetScale = rawWidth > 360.0 ? (360.0 / rawWidth) : 1.0;
  final insertPoint = anchorWorldRect != null
      ? math.Point<double>(anchorWorldRect.right + 28, anchorWorldRect.top)
      : const math.Point<double>(40, 40);

  final element = ImageElement(
    height: rawHeight,
    width: rawWidth,
    collection: docState.currentCollection,
    source: dataUri,
    constraints: ElementConstraints.scaled(
      scaleX: targetScale,
      scaleY: targetScale,
    ),
    position: insertPoint,
  );

  bloc.add(
    ElementsCreated(
      [element],
      pageName: docState.pageName,
      layer: docState.currentLayer,
    ),
  );
  maybeStudyModeCubit(context)?.incrementCanvasExcerptCount();
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已将区域截图添加到画布'),
        duration: Duration(seconds: 2),
      ),
    );
  }
  return true;
}

class _CachedLineLayout {
  final TextPainter painter;
  final Offset topLeft;
  final double sx;
  final double sy;

  const _CachedLineLayout({
    required this.painter,
    required this.topLeft,
    required this.sx,
    required this.sy,
  });
}

class OcrTextLayerPainter extends CustomPainter {
  static final Map<String, List<_CachedLineLayout>> _layoutCache = {};

  final DocumentPage page;
  final CameraTransform transform;
  final PdfMarginCropConfig pdfCrop;
  final OcrState ocrState;
  final Color selectionColor;

  OcrTextLayerPainter({
    required this.page,
    required this.transform,
    required this.pdfCrop,
    required this.ocrState,
    required this.selectionColor,
  });

  List<_CachedLineLayout> _resolveLineLayouts(
    OcrPageResult ocrPage,
    Rect fullBounds,
  ) {
    final key =
        '${ocrState.docHash}_${ocrPage.langTag}_${ocrPage.pageIndex}_${fullBounds.left.round()}_${fullBounds.top.round()}_${fullBounds.width.round()}_${fullBounds.height.round()}_${ocrPage.lines.length}';
    final existing = _layoutCache[key];
    if (existing != null) return existing;

    if (_layoutCache.length > 48) {
      _layoutCache.clear();
    }

    final layouts = <_CachedLineLayout>[];
    for (final line in ocrPage.lines) {
      final text = line.text.trim();
      if (text.isEmpty) continue;
      final rect = line.toWorldRect(fullBounds);
      if (rect.width < 2 || rect.height < 2) continue;

      final baseFontSize = rect.height.clamp(6.0, 42.0) * 0.84;
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.black,
            fontSize: baseFontSize,
            height: 1.05,
            fontWeight: FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();

      if (painter.width <= 0 || painter.height <= 0) continue;
      final sx = rect.width / painter.width;
      final sy = rect.height / painter.height;
      layouts.add(
        _CachedLineLayout(
          painter: painter,
          topLeft: rect.topLeft,
          sx: sx.clamp(0.45, 2.2),
          sy: sy.clamp(0.55, 1.8),
        ),
      );
    }
    _layoutCache[key] = layouts;
    return layouts;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final drawWhiteBg =
        ocrState.whiteBgVisible && ocrState.whiteBgOpacity > 0.005;
    final selection = ocrState.selection;
    final drawSelection = selection != null && selection.isNotEmpty;
    if (!drawWhiteBg && !drawSelection) return;

    final visibleWorld = transform.localToGlobalRect(Offset.zero & size);
    canvas.save();
    transform.applyToCanvas(canvas);

    if (drawWhiteBg) {
      final bgOpacity = ocrState.whiteBgOpacity.clamp(0.0, 1.0);
      final bgPaint = Paint()..color = Colors.white.withValues(alpha: bgOpacity);
      final textAlpha = (0.35 + bgOpacity * 0.65).clamp(0.0, 1.0);
      final layerPaint = Paint()
        ..color = Color.fromARGB((textAlpha * 255).round(), 255, 255, 255);

      for (final pdf in page.content.whereType<PdfElement>()) {
        if (ocrState.activePdfSource != null &&
            pdf.source != ocrState.activePdfSource) {
          continue;
        }
        final fullBounds = PdfStudyService.computePdfBounds(pdf);
        final croppedWorld = pdfCrop.croppedWorldRect(fullBounds, pdf.page);
        if (!croppedWorld.overlaps(visibleWorld)) continue;

        final ocrPage = ocrState.pages[pdf.page];
        canvas.save();
        canvas.clipRect(croppedWorld);
        canvas.drawRect(croppedWorld, bgPaint);

        if (ocrPage != null && ocrPage.lines.isNotEmpty) {
          final layouts = _resolveLineLayouts(ocrPage, fullBounds);
          if (textAlpha < 0.99) {
            canvas.saveLayer(croppedWorld, layerPaint);
          }
          for (final item in layouts) {
            canvas.save();
            canvas.translate(item.topLeft.dx, item.topLeft.dy);
            canvas.scale(item.sx, item.sy);
            item.painter.paint(canvas, Offset.zero);
            canvas.restore();
          }
          if (textAlpha < 0.99) {
            canvas.restore();
          }
        }
        canvas.restore();
      }
    }

    if (drawSelection) {
      final fillPaint = Paint()..color = selectionColor;
      final borderPaint = Paint()
        ..color = selectionColor.withValues(alpha: 0.72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 / math.max(transform.size, 0.3);
      for (final rect in selection.worldRects) {
        if (!rect.overlaps(visibleWorld)) continue;
        final rrect = RRect.fromRectAndRadius(rect.inflate(1.5), const Radius.circular(2));
        canvas.drawRRect(rrect, fillPaint);
        canvas.drawRRect(rrect, borderPaint);
      }
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(OcrTextLayerPainter oldDelegate) =>
      oldDelegate.page != page ||
      oldDelegate.transform != transform ||
      oldDelegate.pdfCrop != pdfCrop ||
      oldDelegate.ocrState.whiteBgVisible != ocrState.whiteBgVisible ||
      oldDelegate.ocrState.whiteBgOpacity != ocrState.whiteBgOpacity ||
      oldDelegate.ocrState.pages != ocrState.pages ||
      oldDelegate.ocrState.selection != ocrState.selection ||
      oldDelegate.selectionColor != selectionColor;
}

class OcrReadingInteractionOverlay extends StatefulWidget {
  const OcrReadingInteractionOverlay({super.key});

  @override
  State<OcrReadingInteractionOverlay> createState() =>
      _OcrReadingInteractionOverlayState();
}

class _OcrReadingInteractionOverlayState
    extends State<OcrReadingInteractionOverlay> {
  final Set<int> _touchPointers = {};
  PdfElement? _dragPdf;
  Rect? _dragFullBounds;
  OcrPageResult? _dragOcrPage;
  Offset? _dragStartWorld;

  bool _hitTestOcrLine(
    Offset localPosition, {
    required DocumentLoadSuccess docState,
    required CameraTransform transform,
    required PdfMarginCropConfig crop,
    required OcrState ocrState,
  }) {
    if (_touchPointers.length >= 2 || ocrState.pages.isEmpty) return false;
    final worldPos = transform.localToGlobal(localPosition);
    final pad = 8.0 / math.max(transform.size, 0.35);

    for (final pdf in docState.page.content.whereType<PdfElement>()) {
      if (ocrState.activePdfSource != null &&
          pdf.source != ocrState.activePdfSource) {
        continue;
      }
      final fullBounds = PdfStudyService.computePdfBounds(pdf);
      final croppedWorld = crop.croppedWorldRect(fullBounds, pdf.page);
      if (!croppedWorld.contains(worldPos)) continue;
      final ocrPage = ocrState.pages[pdf.page];
      if (ocrPage == null || ocrPage.lines.isEmpty) continue;
      for (final line in ocrPage.lines) {
        if (line.toWorldRect(fullBounds).inflate(pad).contains(worldPos)) {
          return true;
        }
      }
    }
    return false;
  }

  ({PdfElement pdf, Rect fullBounds, OcrPageResult ocrPage})? _findTargetPage(
    Offset worldPos,
    DocumentLoadSuccess docState,
    PdfMarginCropConfig crop,
    OcrState ocrState,
  ) {
    for (final pdf in docState.page.content.whereType<PdfElement>()) {
      if (ocrState.activePdfSource != null &&
          pdf.source != ocrState.activePdfSource) {
        continue;
      }
      final fullBounds = PdfStudyService.computePdfBounds(pdf);
      final croppedWorld = crop.croppedWorldRect(fullBounds, pdf.page);
      if (!croppedWorld.contains(worldPos)) continue;
      final ocrPage = ocrState.pages[pdf.page];
      if (ocrPage != null) {
        return (pdf: pdf, fullBounds: fullBounds, ocrPage: ocrPage);
      }
    }
    return null;
  }

  int _findClosestLineIndex(List<OcrTextLine> lines, Offset normPt) {
    var bestIdx = 0;
    var bestScore = double.infinity;
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      final cy = (l.top + l.bottom) * 0.5;
      final dy = (normPt.dy - cy).abs();
      final dx = normPt.dx < l.left
          ? l.left - normPt.dx
          : (normPt.dx > l.right ? normPt.dx - l.right : 0.0);
      final score = dy * 4.0 + dx * 0.4;
      if (score < bestScore) {
        bestScore = score;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  OcrSelectionState? _buildSelection({
    required PdfElement pdf,
    required Rect fullBounds,
    required OcrPageResult ocrPage,
    required CameraTransform transform,
    required Offset startWorld,
    required Offset endWorld,
  }) {
    if (ocrPage.lines.isEmpty ||
        fullBounds.width <= 0 ||
        fullBounds.height <= 0) {
      return null;
    }

    var startNorm = Offset(
      ((startWorld.dx - fullBounds.left) / fullBounds.width).clamp(0.0, 1.0),
      ((startWorld.dy - fullBounds.top) / fullBounds.height).clamp(0.0, 1.0),
    );
    var endNorm = Offset(
      ((endWorld.dx - fullBounds.left) / fullBounds.width).clamp(0.0, 1.0),
      ((endWorld.dy - fullBounds.top) / fullBounds.height).clamp(0.0, 1.0),
    );

    final sortedLines = List<OcrTextLine>.from(ocrPage.lines)
      ..sort((a, b) {
        final aCy = (a.top + a.bottom) * 0.5;
        final bCy = (b.top + b.bottom) * 0.5;
        final minH = math.min(a.bottom - a.top, b.bottom - b.top);
        if ((aCy - bCy).abs() > math.max(0.006, minH * 0.45)) {
          return aCy.compareTo(bCy);
        }
        return a.left.compareTo(b.left);
      });

    var firstIdx = _findClosestLineIndex(sortedLines, startNorm);
    var lastIdx = _findClosestLineIndex(sortedLines, endNorm);
    if (firstIdx > lastIdx) {
      final tmpIdx = firstIdx;
      firstIdx = lastIdx;
      lastIdx = tmpIdx;
      final tmpPt = startNorm;
      startNorm = endNorm;
      endNorm = tmpPt;
    } else if (firstIdx == lastIdx && startNorm.dx > endNorm.dx) {
      final tmpPt = startNorm;
      startNorm = endNorm;
      endNorm = tmpPt;
    }

    final selectedLinesText = <String>[];
    final selectedWorldRects = <Rect>[];

    for (var i = firstIdx; i <= lastIdx; i++) {
      final line = sortedLines[i];
      final xStart = i == firstIdx ? startNorm.dx : 0.0;
      final xEnd = i == lastIdx ? endNorm.dx : 1.0;
      final rangeLeft = math.min(xStart, xEnd);
      final rangeRight = math.max(xStart, xEnd);
      if (i == firstIdx && i == lastIdx && (rangeRight - rangeLeft) < 0.005) {
        continue;
      }

      if (line.words.isNotEmpty) {
        final pickedWords = <OcrWordBox>[];
        for (final w in line.words) {
          final overlap =
              math.min(w.right, rangeRight) - math.max(w.left, rangeLeft);
          final wordW = math.max(0.0001, w.right - w.left);
          if (overlap > wordW * 0.25) {
            pickedWords.add(w);
          }
        }
        if (pickedWords.isEmpty && i != firstIdx && i != lastIdx) {
          pickedWords.addAll(line.words);
        }
        if (pickedWords.isNotEmpty) {
          if (pickedWords.length == 1 &&
              pickedWords.first.text.length >= 4 &&
              (i == firstIdx || i == lastIdx)) {
            final single = pickedWords.first;
            final wWidth = math.max(0.0001, single.right - single.left);
            final fracStart = ((rangeLeft - single.left) / wWidth).clamp(0.0, 1.0);
            final fracEnd = ((rangeRight - single.left) / wWidth).clamp(0.0, 1.0);
            final len = single.text.length;
            final charStart = (fracStart * len).floor().clamp(0, len);
            final charEnd = (fracEnd * len).ceil().clamp(charStart, len);
            final slice = single.text.substring(charStart, charEnd);
            if (slice.trim().isNotEmpty) {
              selectedLinesText.add(slice);
              final boxL = single.left + wWidth * (charStart / len);
              final boxR = single.left + wWidth * (charEnd / len);
              selectedWorldRects.add(
                Rect.fromLTRB(
                  fullBounds.left + fullBounds.width * boxL,
                  fullBounds.top + fullBounds.height * single.top,
                  fullBounds.left + fullBounds.width * boxR,
                  fullBounds.top + fullBounds.height * single.bottom,
                ),
              );
            }
            continue;
          }

          selectedLinesText.add(
            _joinWordsSmart([for (final w in pickedWords) w.text]),
          );
          var minL = 1.0;
          var minT = 1.0;
          var maxR = 0.0;
          var maxB = 0.0;
          for (final w in pickedWords) {
            minL = math.min(minL, w.left);
            minT = math.min(minT, w.top);
            maxR = math.max(maxR, w.right);
            maxB = math.max(maxB, w.bottom);
          }
          selectedWorldRects.add(
            Rect.fromLTRB(
              fullBounds.left + fullBounds.width * minL,
              fullBounds.top + fullBounds.height * minT,
              fullBounds.left + fullBounds.width * maxR,
              fullBounds.top + fullBounds.height * maxB,
            ),
          );
        }
      } else {
        final lineW = math.max(0.0001, line.right - line.left);
        final fracStart = ((rangeLeft - line.left) / lineW).clamp(0.0, 1.0);
        final fracEnd = ((rangeRight - line.left) / lineW).clamp(0.0, 1.0);
        final len = line.text.length;
        final charStart = (fracStart * len).floor().clamp(0, len);
        final charEnd = (fracEnd * len).ceil().clamp(charStart, len);
        if (charEnd > charStart) {
          final slice = line.text.substring(charStart, charEnd);
          if (slice.trim().isNotEmpty) {
            selectedLinesText.add(slice);
            final boxL = line.left + lineW * (charStart / len);
            final boxR = line.left + lineW * (charEnd / len);
            selectedWorldRects.add(
              Rect.fromLTRB(
                fullBounds.left + fullBounds.width * boxL,
                fullBounds.top + fullBounds.height * line.top,
                fullBounds.left + fullBounds.width * boxR,
                fullBounds.top + fullBounds.height * line.bottom,
              ),
            );
          }
        }
      }
    }

    if (selectedLinesText.isEmpty || selectedWorldRects.isEmpty) return null;
    final lastWorld = selectedWorldRects.last;
    final anchorLocal = transform.globalToLocal(
      Offset(lastWorld.right, lastWorld.bottom + 8),
    );
    return OcrSelectionState(
      pdfSource: pdf.source,
      pageIndex: pdf.page,
      text: selectedLinesText.join('\n'),
      worldRects: List.unmodifiable(selectedWorldRects),
      menuAnchorLocal: anchorLocal,
    );
  }

  Rect _unionWorldRects(List<Rect> rects) {
    var r = rects.first;
    for (var i = 1; i < rects.length; i++) {
      r = r.expandToInclude(rects[i]);
    }
    return r;
  }

  @override
  Widget build(BuildContext context) {
    final ocrCubit = maybeOcrCubit(context);
    final studyCubit = maybeStudyModeCubit(context);
    if (ocrCubit == null || studyCubit == null) {
      return const SizedBox.shrink();
    }

    return BlocBuilder<StudyModeCubit, StudyModeState>(
      bloc: studyCubit,
      buildWhen: (prev, curr) =>
          prev.yingPdfStyle != curr.yingPdfStyle ||
          prev.workspaceMode != curr.workspaceMode ||
          prev.aiSnippingMode != curr.aiSnippingMode ||
          prev.pdfCrop != curr.pdfCrop,
      builder: (context, studyState) {
        if (!studyState.yingPdfStyle ||
            studyState.workspaceMode != StudyWorkspaceMode.reading ||
            studyState.aiSnippingMode) {
          return const SizedBox.shrink();
        }
        return BlocBuilder<OcrCubit, OcrState>(
          bloc: ocrCubit,
          builder: (context, ocrState) {
            return BlocBuilder<DocumentBloc, DocumentState>(
              builder: (context, docState) {
                if (docState is! DocumentLoadSuccess) {
                  return const SizedBox.shrink();
                }
                return BlocBuilder<TransformCubit, CameraTransform>(
                  builder: (context, transform) {
                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final selection = ocrState.selection;
                        return Stack(
                          children: [
                            Positioned.fill(
                              child: Listener(
                                behavior: HitTestBehavior.translucent,
                                onPointerSignal: (event) {
                                  if (event is PointerScrollEvent &&
                                      _hitTestOcrLine(
                                        event.localPosition,
                                        docState: docState,
                                        transform: transform,
                                        crop: studyState.pdfCrop,
                                        ocrState: ocrState,
                                      )) {
                                    final kb = HardwareKeyboard.instance;
                                    final tc = context.read<TransformCubit>();
                                    if (kb.isControlPressed) {
                                      final factor =
                                          (-(event.scrollDelta.dx +
                                                  event.scrollDelta.dy / 2) *
                                              0.002) +
                                          1.0;
                                      tc.zoom(factor, event.localPosition);
                                    } else {
                                      final delta = kb.isShiftPressed
                                          ? Offset(
                                              -event.scrollDelta.dy,
                                              -event.scrollDelta.dx,
                                            )
                                          : -event.scrollDelta;
                                      tc.move(tc.state.localToGlobalDelta(delta));
                                    }
                                    context.read<DocumentBloc>().delayedBake(
                                      viewportSize: constraints.biggest,
                                      pixelRatio: MediaQuery.devicePixelRatioOf(
                                        context,
                                      ),
                                      testTransform: false,
                                    );
                                  }
                                },
                                onPointerDown: (event) {
                                  if (event.kind == PointerDeviceKind.touch) {
                                    _touchPointers.add(event.pointer);
                                    if (_touchPointers.length >= 2) {
                                      ocrCubit.clearSelection();
                                      return;
                                    }
                                  }
                                  if (event.buttons != kPrimaryMouseButton &&
                                      event.kind == PointerDeviceKind.mouse) {
                                    return;
                                  }
                                  if (ocrState.selection != null &&
                                      !_hitTestOcrLine(
                                        event.localPosition,
                                        docState: docState,
                                        transform: transform,
                                        crop: studyState.pdfCrop,
                                        ocrState: ocrState,
                                      )) {
                                    ocrCubit.clearSelection();
                                  }
                                },
                                onPointerUp: (event) {
                                  _touchPointers.remove(event.pointer);
                                },
                                onPointerCancel: (event) {
                                  _touchPointers.remove(event.pointer);
                                },
                                child: _SelectiveHitTestWidget(
                                  onHitTest: (localPos) => _hitTestOcrLine(
                                    localPos,
                                    docState: docState,
                                    transform: transform,
                                    crop: studyState.pdfCrop,
                                    ocrState: ocrState,
                                  ),
                                  child: MouseRegion(
                                    opaque: false,
                                    cursor: SystemMouseCursors.text,
                                    child: RawGestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      gestures: <Type, GestureRecognizerFactory>{
                                        _PrimaryOnlyPanRecognizer:
                                            GestureRecognizerFactoryWithHandlers<
                                              _PrimaryOnlyPanRecognizer
                                            >(
                                              () => _PrimaryOnlyPanRecognizer(),
                                              (_PrimaryOnlyPanRecognizer instance) {
                                                instance
                                                  ..onStart = (details) {
                                                    final worldPos = transform
                                                        .localToGlobal(
                                                          details.localPosition,
                                                        );
                                                    final target = _findTargetPage(
                                                      worldPos,
                                                      docState,
                                                      studyState.pdfCrop,
                                                      ocrState,
                                                    );
                                                    _dragPdf = target?.pdf;
                                                    _dragFullBounds =
                                                        target?.fullBounds;
                                                    _dragOcrPage = target?.ocrPage;
                                                    _dragStartWorld = worldPos;
                                                    ocrCubit.clearSelection();
                                                  }
                                                  ..onUpdate = (details) {
                                                    final pdf = _dragPdf;
                                                    final bounds = _dragFullBounds;
                                                    final ocrPage = _dragOcrPage;
                                                    final startWorld =
                                                        _dragStartWorld;
                                                    if (pdf == null ||
                                                        bounds == null ||
                                                        ocrPage == null ||
                                                        startWorld == null) {
                                                      return;
                                                    }
                                                    final endWorld = transform
                                                        .localToGlobal(
                                                          details.localPosition,
                                                        );
                                                    final nextSelection =
                                                        _buildSelection(
                                                          pdf: pdf,
                                                          fullBounds: bounds,
                                                          ocrPage: ocrPage,
                                                          transform: transform,
                                                          startWorld: startWorld,
                                                          endWorld: endWorld,
                                                        );
                                                    ocrCubit.setSelection(
                                                      nextSelection,
                                                    );
                                                  }
                                                  ..onEnd = (_) {
                                                    _dragPdf = null;
                                                    _dragFullBounds = null;
                                                    _dragOcrPage = null;
                                                    _dragStartWorld = null;
                                                  }
                                                  ..onCancel = () {
                                                    _dragPdf = null;
                                                    _dragFullBounds = null;
                                                    _dragOcrPage = null;
                                                    _dragStartWorld = null;
                                                  };
                                              },
                                            ),
                                      },
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (selection != null && selection.isNotEmpty)
                              _FloatingSelectionMenu(
                                maxWidth: constraints.maxWidth,
                                maxHeight: constraints.maxHeight,
                                selection: selection,
                                onCopy: () async {
                                  await Clipboard.setData(
                                    ClipboardData(text: selection.text),
                                  );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        '已复制 ${selection.text.length} 个字符',
                                      ),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                  ocrCubit.clearSelection();
                                },
                                onAddToCanvas: () async {
                                  await insertTextExcerptToCanvas(
                                    context,
                                    text: selection.text,
                                    anchorWorldRect: _unionWorldRects(
                                      selection.worldRects,
                                    ),
                                  );
                                  ocrCubit.clearSelection();
                                },
                                onAskAi: () {
                                  final unionRect = _unionWorldRects(
                                    selection.worldRects,
                                  );
                                  studyCubit.setPendingSnip(
                                    SnippedRegion(
                                      pngBytes: Uint8List(0),
                                      canvasRect: unionRect,
                                      pdfPageNumber: selection.pageIndex + 1,
                                      documentName: docState.metadata.name,
                                      ocrText: selection.text,
                                    ),
                                  );
                                  studyCubit.setInspectorOpen(true);
                                  studyCubit.openStudyPanel(StudyPanelTab.aiTutor);
                                  ocrCubit.clearSelection();
                                },
                              ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _FloatingSelectionMenu extends StatelessWidget {
  final double maxWidth;
  final double maxHeight;
  final OcrSelectionState selection;
  final VoidCallback onCopy;
  final VoidCallback onAddToCanvas;
  final VoidCallback onAskAi;

  const _FloatingSelectionMenu({
    required this.maxWidth,
    required this.maxHeight,
    required this.selection,
    required this.onCopy,
    required this.onAddToCanvas,
    required this.onAskAi,
  });

  @override
  Widget build(BuildContext context) {
    final palette = YingPdfPalette.of(context);
    const menuW = 205.0;
    const menuH = 112.0;
    final left = selection.menuAnchorLocal.dx.clamp(
      12.0,
      math.max(12.0, maxWidth - menuW - 12.0),
    );
    final top = selection.menuAnchorLocal.dy.clamp(
      12.0,
      math.max(12.0, maxHeight - menuH - 12.0),
    );

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 8,
        color: palette.controlSurface,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: menuW,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: palette.borderSubtle),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SelectionMenuRow(
                icon: PhosphorIconsLight.copy,
                label: '复制',
                shortcut: 'Ctrl+C',
                onTap: onCopy,
              ),
              _SelectionMenuRow(
                icon: PhosphorIconsLight.plusSquare,
                label: '添加到画布',
                shortcut: 'R',
                onTap: onAddToCanvas,
              ),
              _SelectionMenuRow(
                icon: PhosphorIconsLight.sparkle,
                label: '问 AI 助教',
                shortcut: null,
                onTap: onAskAi,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectionMenuRow extends StatelessWidget {
  final PhosphorIconData icon;
  final String label;
  final String? shortcut;
  final VoidCallback onTap;

  const _SelectionMenuRow({
    required this.icon,
    required this.label,
    required this.shortcut,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = YingPdfPalette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(7),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            PhosphorIcon(icon, size: 15, color: palette.inkSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: palette.inkPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (shortcut != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: palette.pillSurface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: palette.borderSubtle),
                ),
                child: Text(
                  shortcut!,
                  style: TextStyle(
                    fontSize: 10,
                    color: palette.inkMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryOnlyPanRecognizer extends PanGestureRecognizer {
  @override
  bool isPointerAllowed(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons != kPrimaryMouseButton) {
      return false;
    }
    return super.isPointerAllowed(event);
  }
}

class _SelectiveHitTestWidget extends SingleChildRenderObjectWidget {
  final bool Function(Offset localPosition) onHitTest;

  const _SelectiveHitTestWidget({
    required this.onHitTest,
    required super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _SelectiveHitTestBox(onHitTest);

  @override
  void updateRenderObject(
    BuildContext context,
    _SelectiveHitTestBox renderObject,
  ) {
    renderObject.onHitTest = onHitTest;
  }
}

class _SelectiveHitTestBox extends RenderProxyBox {
  bool Function(Offset localPosition) onHitTest;

  _SelectiveHitTestBox(this.onHitTest);

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || !onHitTest(position)) {
      return false;
    }
    return super.hitTest(result, position: position);
  }
}
