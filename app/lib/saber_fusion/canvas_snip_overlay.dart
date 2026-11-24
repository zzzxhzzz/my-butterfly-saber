import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'ocr_canvas_overlay.dart';
import 'ocr_cubit.dart';
import 'pdf_study_service.dart';
import 'study_state.dart';
import 'ying_pdf_theme.dart';

enum _SnipAction { addToCanvas, ocrText, askAi }

class CanvasSnipOverlay extends StatefulWidget {
  final GlobalKey canvasCaptureKey;

  const CanvasSnipOverlay({
    super.key,
    required this.canvasCaptureKey,
  });

  @override
  State<CanvasSnipOverlay> createState() => _CanvasSnipOverlayState();
}

class _CanvasSnipOverlayState extends State<CanvasSnipOverlay> {
  Offset? _dragStart;
  Rect? _selectionRect;
  bool _capturing = false;

  void _updateDrag(Offset current) {
    final start = _dragStart;
    if (start == null) return;
    setState(() {
      _selectionRect = Rect.fromPoints(start, current);
    });
  }

  Future<({Uint8List pngBytes, Rect canvasRect})?> _captureSelection() async {
    final rect = _selectionRect;
    if (rect == null || rect.width < 12 || rect.height < 12) return null;

    final overlayObject = context.findRenderObject();
    final boundaryObject =
        widget.canvasCaptureKey.currentContext?.findRenderObject();
    if (overlayObject is! RenderBox ||
        boundaryObject is! RenderRepaintBoundary) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法获取画布截图，请先确保文档已加载')),
        );
      }
      return null;
    }

    final topLeftInBoundary = boundaryObject.globalToLocal(
      overlayObject.localToGlobal(rect.topLeft),
    );
    final bottomRightInBoundary = boundaryObject.globalToLocal(
      overlayObject.localToGlobal(rect.bottomRight),
    );
    final boundarySize = boundaryObject.size;
    final localRect = Rect.fromPoints(
      topLeftInBoundary,
      bottomRightInBoundary,
    ).intersect(Offset.zero & boundarySize);

    if (localRect.isEmpty || localRect.width < 8 || localRect.height < 8) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('框选区域过小或超出画布，请重新框选')),
        );
      }
      return null;
    }

    final pixelRatio = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.5);
    final fullImage = await boundaryObject.toImage(pixelRatio: pixelRatio);
    ui.Image? croppedImage;
    try {
      final scaleX = fullImage.width / max(1.0, boundarySize.width);
      final scaleY = fullImage.height / max(1.0, boundarySize.height);
      final srcX = (localRect.left * scaleX).round().clamp(
        0,
        fullImage.width - 1,
      );
      final srcY = (localRect.top * scaleY).round().clamp(
        0,
        fullImage.height - 1,
      );
      final srcW = (localRect.width * scaleX).round().clamp(
        1,
        fullImage.width - srcX,
      );
      final srcH = (localRect.height * scaleY).round().clamp(
        1,
        fullImage.height - srcY,
      );

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        fullImage,
        Rect.fromLTWH(
          srcX.toDouble(),
          srcY.toDouble(),
          srcW.toDouble(),
          srcH.toDouble(),
        ),
        Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
        Paint(),
      );
      final picture = recorder.endRecording();
      try {
        croppedImage = await picture.toImage(srcW, srcH);
      } finally {
        picture.dispose();
      }
      final byteData = await croppedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null || !mounted) return null;

      final transform = context.read<TransformCubit>().state;
      final canvasRect = transform.localToGlobalRect(localRect);
      return (
        pngBytes: byteData.buffer.asUint8List(),
        canvasRect: canvasRect,
      );
    } finally {
      croppedImage?.dispose();
      fullImage.dispose();
    }
  }

  Future<void> _executeAction(_SnipAction action) async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      final captured = await _captureSelection();
      if (captured == null || !mounted) return;

      final docState = context.read<DocumentBloc>().state;
      int? pdfPageNumber;
      var documentName = '';
      if (docState is DocumentLoadSuccess) {
        documentName = docState.metadata.name;
        for (final pdf in docState.page.content.whereType<PdfElement>()) {
          final bounds = PdfStudyService.computePdfBounds(pdf);
          if (bounds.overlaps(captured.canvasRect)) {
            pdfPageNumber = pdf.page + 1;
            break;
          }
        }
      }

      final studyCubit = context.read<StudyModeCubit>();
      switch (action) {
        case _SnipAction.addToCanvas:
          await insertImageExcerptToCanvas(
            context,
            pngBytes: captured.pngBytes,
            anchorWorldRect: captured.canvasRect,
          );
          if (mounted) {
            studyCubit.setAiSnippingMode(false);
          }
          break;

        case _SnipAction.ocrText:
          final ocrCubit = maybeOcrCubit(context);
          final text = await ocrCubit?.recognizeRegionPng(captured.pngBytes);
          if (!mounted) return;
          if (text == null || text.trim().isEmpty) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('未识别到清晰文字，可调整区域或放大后重试')),
            );
            return;
          }
          await _showOcrExtractResultDialog(
            text: text.trim(),
            pngBytes: captured.pngBytes,
            canvasRect: captured.canvasRect,
            pdfPageNumber: pdfPageNumber,
            documentName: documentName,
          );
          break;

        case _SnipAction.askAi:
          studyCubit.setPendingSnip(
            SnippedRegion(
              pngBytes: captured.pngBytes,
              canvasRect: captured.canvasRect,
              pdfPageNumber: pdfPageNumber,
              documentName: documentName,
            ),
          );
          studyCubit.setAiSnippingMode(false);
          studyCubit.setInspectorOpen(true);
          studyCubit.openStudyPanel(StudyPanelTab.aiTutor);
          break;
      }
    } finally {
      if (mounted) {
        setState(() => _capturing = false);
      }
    }
  }

  Future<void> _showOcrExtractResultDialog({
    required String text,
    required Uint8List pngBytes,
    required Rect canvasRect,
    required int? pdfPageNumber,
    required String documentName,
  }) async {
    final studyCubit = context.read<StudyModeCubit>();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            PhosphorIcon(PhosphorIconsLight.textT, size: 18),
            SizedBox(width: 8),
            Text('区域 OCR 提取结果'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: SelectableText(
            text,
            style: const TextStyle(height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
              if (mounted) {
                studyCubit.setAiSnippingMode(false);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('已复制提取的文字')),
                );
              }
            },
            child: const Text('复制'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await insertTextExcerptToCanvas(
                context,
                text: text,
                anchorWorldRect: canvasRect,
              );
              if (mounted) {
                studyCubit.setAiSnippingMode(false);
              }
            },
            child: const Text('添加到画布'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(dialogContext);
              studyCubit.setPendingSnip(
                SnippedRegion(
                  pngBytes: pngBytes,
                  canvasRect: canvasRect,
                  pdfPageNumber: pdfPageNumber,
                  documentName: documentName,
                  ocrText: text,
                ),
              );
              studyCubit.setAiSnippingMode(false);
              studyCubit.setInspectorOpen(true);
              studyCubit.openStudyPanel(StudyPanelTab.aiTutor);
            },
            icon: const PhosphorIcon(PhosphorIconsLight.sparkle, size: 16),
            label: const Text('问 AI'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = YingPdfPalette.of(context);
    final hasValidSelection =
        _selectionRect != null &&
        _selectionRect!.width >= 12 &&
        _selectionRect!.height >= 12;

    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) {
                if (_capturing) return;
                setState(() {
                  _dragStart = details.localPosition;
                  _selectionRect = Rect.fromLTWH(
                    details.localPosition.dx,
                    details.localPosition.dy,
                    0,
                    0,
                  );
                });
              },
              onPanUpdate: (details) {
                if (_capturing) return;
                _updateDrag(details.localPosition);
              },
              child: CustomPaint(
                size: Size.infinite,
                painter: _SnipScrimPainter(
                  selectionRect: _selectionRect,
                  accentColor: palette.accentBerry,
                ),
              ),
            ),
            if (hasValidSelection)
              Positioned(
                left: (_selectionRect!.center.dx - 170).clamp(
                  12.0,
                  max(12.0, constraints.maxWidth - 352.0),
                ),
                top: (_selectionRect!.bottom + 10).clamp(
                  12.0,
                  max(12.0, constraints.maxHeight - 64.0),
                ),
                child: Material(
                  elevation: 8,
                  color: palette.controlSurface,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: palette.borderSubtle),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          onPressed: _capturing
                              ? null
                              : () => _executeAction(_SnipAction.addToCanvas),
                          icon: const PhosphorIcon(
                            PhosphorIconsLight.plusSquare,
                            size: 15,
                          ),
                          label: const Text('添加到画布'),
                        ),
                        TextButton.icon(
                          onPressed: _capturing
                              ? null
                              : () => _executeAction(_SnipAction.ocrText),
                          icon: const PhosphorIcon(
                            PhosphorIconsLight.textT,
                            size: 15,
                          ),
                          label: const Text('OCR 文字'),
                        ),
                        FilledButton.icon(
                          onPressed: _capturing
                              ? null
                              : () => _executeAction(_SnipAction.askAi),
                          icon: _capturing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const PhosphorIcon(
                                  PhosphorIconsLight.sparkle,
                                  size: 15,
                                ),
                          label: const Text('问 AI'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 18, left: 16, right: 16),
                  child: Card(
                    elevation: 6,
                    color: palette.headerSurface,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          PhosphorIcon(
                            PhosphorIconsLight.crop,
                            size: 18,
                            color: palette.accentBerry,
                          ),
                          Text(
                            hasValidSelection
                                ? '已框选 ${_selectionRect!.width.round()}×${_selectionRect!.height.round()}，请在选框下方选择动作'
                                : '用鼠标或触控笔拖动框选区域（支持截图贴画布 / OCR 取字 / AI 讲解）',
                            style: TextTheme.of(context).bodySmall,
                          ),
                          TextButton.icon(
                            onPressed: _capturing
                                ? null
                                : () => context
                                      .read<StudyModeCubit>()
                                      .setAiSnippingMode(false),
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.x,
                              size: 15,
                            ),
                            label: const Text('取消 (Esc)'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SnipScrimPainter extends CustomPainter {
  final Rect? selectionRect;
  final Color accentColor;

  const _SnipScrimPainter({
    required this.selectionRect,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Offset.zero & size;
    final rect = selectionRect;
    final scrimPaint = Paint()..color = const Color(0x58000000);

    if (rect == null || rect.isEmpty) {
      canvas.drawRect(fullRect, scrimPaint);
      return;
    }

    final cutout = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(fullRect)
      ..addRect(rect);
    canvas.drawPath(cutout, scrimPaint);

    canvas.drawRect(
      rect,
      Paint()
        ..color = accentColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2,
    );
  }

  @override
  bool shouldRepaint(_SnipScrimPainter oldDelegate) =>
      oldDelegate.selectionRect != selectionRect ||
      oldDelegate.accentColor != accentColor;
}
