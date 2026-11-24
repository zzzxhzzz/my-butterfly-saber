part of '../view.dart';

class _ViewportCanvas extends StatefulWidget {
  const _ViewportCanvas({
    super.key,
    this.canvasCaptureKey,
    required this.rendererState,
    required this.documentState,
    required this.delayBake,
  });

  final GlobalKey? canvasCaptureKey;
  final RendererRuntimeState rendererState;
  final DocumentLoaded documentState;
  final VoidCallback delayBake;

  @override
  State<_ViewportCanvas> createState() => _ViewportCanvasState();
}

class _ViewportCanvasState extends State<_ViewportCanvas>
    with SingleTickerProviderStateMixin {
  static const _slideCurve = Curves.easeOutCubic;

  late final AnimationController _animationController;
  Animation<Offset>? _positionAnimation;
  Animation<double>? _sizeAnimation;
  int _slideAnimationId = 0;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void settleSlide(TransformCubit transformCubit) {
    final transform = transformCubit.state;
    if (transform.friction == null) return;
    final settled = _visibleTransform(transform);
    transformCubit.teleport(settled.position, settled.size, settled.rotation);
  }

  void _clearSlideAnimation() {
    _slideAnimationId++;
    _animationController.stop();
    _positionAnimation = null;
    _sizeAnimation = null;
  }

  void _handleSlideAnimation(CameraTransform transform) {
    final friction = transform.friction;
    if (friction == null) {
      _clearSlideAnimation();
      return;
    }

    final slideAnimationId = ++_slideAnimationId;
    final curve = CurvedAnimation(
      parent: _animationController,
      curve: _slideCurve,
    );
    _positionAnimation = Tween<Offset>(
      begin: friction.beginOffset - (_positionAnimation?.value ?? Offset.zero),
      end: .zero,
    ).animate(curve);
    _sizeAnimation = Tween<double>(
      begin: friction.beginSize - (_sizeAnimation?.value ?? 0),
      end: 0,
    ).animate(curve);

    final previousDurationMs =
        _animationController.duration?.inMilliseconds ?? 0;
    final remainingDurationMs = _animationController.isAnimating
        ? ((1 - _animationController.value) * previousDurationMs).round()
        : 0;
    final durationMs = remainingDurationMs + (friction.duration * 1000).round();
    if (durationMs <= 0) {
      _clearSlideAnimation();
      return;
    }

    _animationController.duration = Duration(milliseconds: durationMs);
    unawaited(
      _animationController.forward(from: 0).then((_) {
        if (!mounted || slideAnimationId != _slideAnimationId) return;
        widget.delayBake();
      }),
    );
  }

  CameraTransform _visibleTransform(CameraTransform transform) =>
      transform.withFrictionless(
        _positionAnimation?.value ?? Offset.zero,
        _sizeAnimation?.value ?? 0,
      );

  @override
  Widget build(BuildContext context) {
    final state = widget.documentState;
    final studyCubit = maybeStudyModeCubit(context);
    if (studyCubit != null) {
      final rendererCubit = context.read<RendererCubit>();
      rendererCubit.perfectHighlighter = studyCubit.state.perfectHighlighter;
      rendererCubit.pdfDisplayOptions = studyCubit.state.pdfCrop;
    }

    Widget buildCanvas({
      required CameraTransform visibleTransform,
      required bool perfectHighlighter,
      required PdfMarginCropConfig pdfDisplayOptions,
    }) {
      return RepaintBoundary(
        key: widget.canvasCaptureKey,
        child: Stack(
          children: [
            Container(color: ColorScheme.of(context).surfaceDim),
            RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: ViewPainter(
                  state.data,
                  state.page,
                  state.info,
                  repaint: context.read<RendererCubit>().repaint,
                  cameraViewport: widget.rendererState.cameraViewport,
                  transform: visibleTransform,
                  invisibleLayers: state.invisibleLayers,
                  currentArea: state.currentArea,
                  colorScheme: ColorScheme.of(context),
                  perfectHighlighter: perfectHighlighter,
                  pdfDisplayOptions: pdfDisplayOptions,
                ),
                isComplex: true,
              ),
            ),
            if (maybeOcrCubit(context) case final ocrCubit?)
              BlocBuilder<OcrCubit, OcrState>(
                bloc: ocrCubit,
                builder: (context, ocrState) => IgnorePointer(
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: OcrTextLayerPainter(
                      page: state.page,
                      transform: visibleTransform,
                      pdfCrop: pdfDisplayOptions,
                      ocrState: ocrState,
                      selectionColor: YingPdfPalette.of(
                        context,
                      ).selectionHighlight,
                    ),
                  ),
                ),
              ),
            BlocBuilder<ToolCubit, ToolRuntimeState>(
              buildWhen: (previous, current) =>
                  previous.foregrounds != current.foregrounds ||
                  previous.temporaryForegrounds !=
                      current.temporaryForegrounds ||
                  previous.toggleableForegrounds !=
                      current.toggleableForegrounds ||
                  previous.networkingForegrounds !=
                      current.networkingForegrounds ||
                  previous.selection != current.selection,
              builder: (context, toolState) => RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: ForegroundPainter(
                    toolState.getAllForegrounds(),
                    state.data,
                    state.page,
                    state.info,
                    ColorScheme.of(context),
                    visibleTransform,
                    toolState.selection,
                    state.settingsCubit.state.navigatorPosition,
                    perfectHighlighter,
                  ),
                  willChange: true,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final child = BlocListener<TransformCubit, CameraTransform>(
      listenWhen: (previous, current) =>
          previous.friction?.lastUpdate != current.friction?.lastUpdate,
      listener: (_, transform) => _handleSlideAnimation(transform),
      child: BlocBuilder<TransformCubit, CameraTransform>(
        builder: (context, transform) => AnimatedBuilder(
          animation: _animationController,
          builder: (context, _) {
            final visibleTransform = _visibleTransform(transform);
            if (studyCubit == null) {
              return buildCanvas(
                visibleTransform: visibleTransform,
                perfectHighlighter: true,
                pdfDisplayOptions: const PdfMarginCropConfig.vanilla(),
              );
            }
            return BlocBuilder<StudyModeCubit, StudyModeState>(
              bloc: studyCubit,
              buildWhen: (previous, current) =>
                  previous.colorMode != current.colorMode ||
                  previous.perfectHighlighter != current.perfectHighlighter ||
                  previous.pdfCrop != current.pdfCrop,
              builder: (context, studyState) {
                final canvas = buildCanvas(
                  visibleTransform: visibleTransform,
                  perfectHighlighter: studyState.perfectHighlighter,
                  pdfDisplayOptions: studyState.pdfCrop,
                );
                final filter = canvasColorFilterFor(studyState.colorMode);
                if (filter == null) return canvas;
                return ColorFiltered(colorFilter: filter, child: canvas);
              },
            );
          },
        ),
      ),
    );

    if (studyCubit == null) return child;
    return BlocListener<StudyModeCubit, StudyModeState>(
      bloc: studyCubit,
      listenWhen: (previous, current) =>
          previous.perfectHighlighter != current.perfectHighlighter ||
          previous.pdfCrop != current.pdfCrop,
      listener: (context, studyState) {
        final controller = context.read<EditorController>();
        final rendererCubit = context.read<RendererCubit>();
        rendererCubit.perfectHighlighter = studyState.perfectHighlighter;
        rendererCubit.pdfDisplayOptions = studyState.pdfCrop;
        if (studyState.pdfCrop.showCropGuides) {
          if (rendererCubit.state.cameraViewport.baked) {
            unawaited(rendererCubit.unbake(controller, state));
          }
          rendererCubit.notifyRepaint();
        } else {
          rendererCubit.notifyRepaint();
          context.read<DocumentBloc>().delayedBake(
            viewportSize: MediaQuery.sizeOf(context),
            pixelRatio: MediaQuery.devicePixelRatioOf(context),
            testTransform: false,
          );
        }
      },
      child: child,
    );
  }
}
