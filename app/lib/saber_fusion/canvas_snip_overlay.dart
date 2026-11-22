import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'pdf_study_service.dart';
import 'study_state.dart';

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

  Future<void> _confirmCapture() async {
    final rect = _selectionRect;
    if (rect == null || rect.width < 12 || rect.height < 12 || _capturing) {
      return;
    }
    setState(() => _capturing = true);
    try {
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
        return;
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
        return;
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
        if (byteData == null || !mounted) return;

        final transform = context.read<TransformCubit>().state;
        final canvasRect = transform.localToGlobalRect(localRect);

        final docState = context.read<DocumentBloc>().state;
        int? pdfPageNumber;
        var documentName = '';
        if (docState is DocumentLoadSuccess) {
          documentName = docState.metadata.name;
          for (final pdf in docState.page.content.whereType<PdfElement>()) {
            final bounds = PdfStudyService.computePdfBounds(pdf);
            if (bounds.overlaps(canvasRect)) {
              pdfPageNumber = pdf.page + 1;
              break;
            }
          }
        }

        final studyCubit = context.read<StudyModeCubit>();
        studyCubit.setPendingSnip(
          SnippedRegion(
            pngBytes: byteData.buffer.asUint8List(),
            canvasRect: canvasRect,
            pdfPageNumber: pdfPageNumber,
            documentName: documentName,
          ),
        );
        studyCubit.setAiSnippingMode(false);
        studyCubit.openStudyPanel(StudyPanelTab.aiTutor);
      } finally {
        croppedImage?.dispose();
        fullImage.dispose();
      }
    } finally {
      if (mounted) {
        setState(() => _capturing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final hasValidSelection =
        _selectionRect != null &&
        _selectionRect!.width >= 12 &&
        _selectionRect!.height >= 12;

    return Positioned.fill(
      child: Stack(
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
                accentColor: colorScheme.primary,
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 24, left: 16, right: 16),
                child: Card(
                  elevation: 8,
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
                        const PhosphorIcon(PhosphorIconsLight.crop, size: 18),
                        Text(
                          hasValidSelection
                              ? '已框选 ${_selectionRect!.width.round()}×${_selectionRect!.height.round()}'
                              : '用笔或鼠标拖动框选题目 / 公式',
                          style: TextTheme.of(context).bodyMedium,
                        ),
                        TextButton.icon(
                          onPressed: _capturing
                              ? null
                              : () => context
                                    .read<StudyModeCubit>()
                                    .setAiSnippingMode(false),
                          icon: const PhosphorIcon(
                            PhosphorIconsLight.x,
                            size: 16,
                          ),
                          label: const Text('取消'),
                        ),
                        FilledButton.icon(
                          onPressed: hasValidSelection && !_capturing
                              ? _confirmCapture
                              : null,
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
                                  size: 16,
                                ),
                          label: const Text('确认框选问 AI'),
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
    final scrimPaint = Paint()..color = const Color(0x66000000);

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
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_SnipScrimPainter oldDelegate) =>
      oldDelegate.selectionRect != selectionRect ||
      oldDelegate.accentColor != accentColor;
}
