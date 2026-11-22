import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/widgets/color_field.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:butterfly/src/generated/i18n/app_localizations.dart';
import 'package:material_leap/material_leap.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../pages.dart';

const _defaultScalePercent = 100.0;
const _maxLazyThumbnails = 40;

@immutable
class PageDialogCallback {
  final List<int> pages;
  final bool spreadToPages, createAreas, createExportPreset, invert;
  final SRGBColor background;
  final String name;
  final double scale;
  final double draftMarginRightPercent;
  final double draftMarginBottomPercent;
  final double pageGap;
  final bool includeMarginInArea;

  const PageDialogCallback(
    this.pages,
    this.spreadToPages,
    this.createAreas,
    this.createExportPreset,
    this.background,
    this.invert,
    this.name, {
    required this.scale,
    this.draftMarginRightPercent = 0,
    this.draftMarginBottomPercent = 0,
    this.pageGap = 0,
    this.includeMarginInArea = true,
  });
}

class ImportPagesDialog extends StatefulWidget {
  final List<ui.Image>? pages;
  final PdfDocument? pdfDocument;
  final String? name;

  const ImportPagesDialog({
    super.key,
    this.pages,
    this.pdfDocument,
    this.name,
  }) : assert(pages != null || pdfDocument != null);

  @override
  State<ImportPagesDialog> createState() => _ImportPagesDialogState();
}

class _ImportPagesDialogState extends State<ImportPagesDialog> {
  final Set<int> _selected = {};
  final _thumbnailScroll = ScrollController();
  final Map<int, ui.Image> _lazyThumbnails = {};
  final Map<int, Future<void>> _pendingThumbnails = {};
  final List<int> _thumbnailLru = [];
  bool _disposed = false;
  bool _spreadToPages = false,
      _createAreas = true,
      _createExportPreset = true,
      _invert = false,
      _includeMarginInArea = true;
  SRGBColor _background = BasicColors.whiteTransparent;
  String _name = '';
  double _scalePercent = _defaultScalePercent;
  double _draftMarginRightPercent = 0;
  double _draftMarginBottomPercent = 0;
  double _pageGap = 0;

  int get _pageCount =>
      widget.pages?.length ?? widget.pdfDocument?.pages.length ?? 0;

  Iterable<int> get _pageIndexes => Iterable<int>.generate(_pageCount);

  @override
  void initState() {
    super.initState();
    _selected.addAll(_pageIndexes);
    _name = widget.name ?? '';
    _spreadToPages = context.read<SettingsCubit>().state.spreadPages;
  }

  @override
  void dispose() {
    _disposed = true;
    _thumbnailScroll.dispose();
    for (final image in _lazyThumbnails.values) {
      image.dispose();
    }
    _lazyThumbnails.clear();
    _thumbnailLru.clear();
    super.dispose();
  }

  ui.Image? _thumbnailFor(int index) {
    final preRendered = widget.pages;
    if (preRendered != null) {
      return index >= 0 && index < preRendered.length ? preRendered[index] : null;
    }
    final cached = _lazyThumbnails[index];
    if (cached != null) {
      _thumbnailLru.remove(index);
      _thumbnailLru.add(index);
      return cached;
    }
    _requestLazyThumbnail(index);
    return null;
  }

  void _requestLazyThumbnail(int index) {
    if (_disposed || _pendingThumbnails.containsKey(index)) return;
    final pdfDoc = widget.pdfDocument;
    if (pdfDoc == null || index < 0 || index >= pdfDoc.pages.length) return;
    _pendingThumbnails[index] = () async {
      try {
        final page = pdfDoc.pages[index];
        final scale = min(1.0, 512 / max(page.width, page.height));
        final width = max(1, (page.width * scale).round());
        final height = max(1, (page.height * scale).round());
        final raster = await page.render(
          width: width,
          height: height,
          fullWidth: width.toDouble(),
          fullHeight: height.toDouble(),
        );
        if (raster == null) return;
        ui.Image? image;
        try {
          image = await raster.createImage();
        } finally {
          raster.dispose();
        }
        if (_disposed || !mounted) {
          image.dispose();
          return;
        }
        _lazyThumbnails[index] = image;
        _thumbnailLru.remove(index);
        _thumbnailLru.add(index);
        while (_thumbnailLru.length > _maxLazyThumbnails) {
          final evictedIndex = _thumbnailLru.removeAt(0);
          _lazyThumbnails.remove(evictedIndex)?.dispose();
        }
        setState(() {});
      } catch (_) {
      } finally {
        _pendingThumbnails.remove(index);
      }
    }();
  }

  Future<void> _selectPages() async {
    final loc = AppLocalizations.of(context);
    final selected = await showDialog<List<String>>(
      context: context,
      builder: (context) => SelectPagesDialog(
        pages: [
          for (final index in _pageIndexes)
            (loc.pageIndex(index + 1), '$index'),
        ],
        initialSelected: _selected.map((index) => '$index'),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(selected.map(int.parse));
    });
  }

  void _submit() => Navigator.pop(
    context,
    PageDialogCallback(
      _pageIndexes.where(_selected.contains).toList(),
      _spreadToPages,
      _createAreas,
      _createExportPreset,
      _background,
      _invert,
      _name,
      scale: _scalePercent / 100,
      draftMarginRightPercent: _draftMarginRightPercent,
      draftMarginBottomPercent: _draftMarginBottomPercent,
      pageGap: _pageGap,
      includeMarginInArea: _includeMarginInArea,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: MediaQuery.sizeOf(context).width < 730 ? 12 : 32,
        vertical: 16,
      ),
      constraints: const BoxConstraints(maxWidth: 940, maxHeight: 660),
      clipBehavior: .antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          crossAxisAlignment: .stretch,
          children: [
            Header(
              centerTitle: false,
              leading: const PhosphorIcon(PhosphorIconsLight.filePdf),
              title: Text(loc.importPdf),
            ),
            const Divider(height: 1),
            Expanded(
              child: constraints.maxWidth < 680
                  ? SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: .stretch,
                        children: [
                          _buildPagePane(context, compact: true),
                          const Divider(height: 1),
                          _buildSettings(context),
                        ],
                      ),
                    )
                  : Row(
                      crossAxisAlignment: .stretch,
                      children: [
                        Expanded(
                          child: _buildPagePane(context, compact: false),
                        ),
                        SizedBox(
                          width: 320,
                          child: SingleChildScrollView(
                            primary: false,
                            child: _buildSettings(context),
                          ),
                        ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: OverflowBar(
                alignment: .end,
                overflowAlignment: .end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      MaterialLocalizations.of(context).cancelButtonLabel,
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _selected.isEmpty ? null : _submit,
                    icon: const PhosphorIcon(PhosphorIconsLight.arrowSquareIn),
                    label: Text(loc.import),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPagePane(BuildContext context, {required bool compact}) {
    final colorScheme = ColorScheme.of(context);
    final loc = AppLocalizations.of(context);
    final pageCount = _pageCount;
    final allSelected = _selected.length == pageCount;
    return Material(
      color: colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(20, 4, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    loc.pdfImportSelectionCount(
                      _selected.length,
                      pageCount,
                    ),
                    style: TextTheme.of(context).titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: allSelected ? loc.deselect : loc.selectAll,
                  icon: PhosphorIcon(
                    allSelected
                        ? PhosphorIconsLight.selectionSlash
                        : PhosphorIconsLight.selectionAll,
                  ),
                  onPressed: pageCount == 0
                      ? null
                      : () => setState(() {
                          _selected.clear();
                          if (!allSelected) _selected.addAll(_pageIndexes);
                        }),
                ),
                IconButton(
                  tooltip: loc.invertSelection,
                  icon: const PhosphorIcon(PhosphorIconsLight.selectionInverse),
                  onPressed: pageCount == 0
                      ? null
                      : () => setState(() {
                          final inverted = _pageIndexes.toSet().difference(
                            _selected,
                          );
                          _selected
                            ..clear()
                            ..addAll(inverted);
                        }),
                ),
                IconButton(
                  tooltip: loc.selectPages,
                  icon: const PhosphorIcon(PhosphorIconsLight.listNumbers),
                  onPressed: pageCount == 0 ? null : _selectPages,
                ),
              ],
            ),
          ),
          if (compact)
            SizedBox(
              height: 152,
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: Scrollbar(
                  controller: _thumbnailScroll,
                  child: ListView.separated(
                    controller: _thumbnailScroll,
                    scrollDirection: .horizontal,
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    itemCount: pageCount,
                    separatorBuilder: (context, index) =>
                        const SizedBox(width: 10),
                    itemBuilder: (context, index) => SizedBox(
                      width: 118,
                      child: _buildThumbnail(context, index),
                    ),
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: GridView.builder(
                primary: false,
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 205,
                  mainAxisExtent: 196,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: pageCount,
                itemBuilder: _buildThumbnail,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context, int index) {
    final label = AppLocalizations.of(context).pageIndex(index + 1);
    final selected = _selected.contains(index);
    final thumbnail = _thumbnailFor(index);
    void setSelected(bool? value) => setState(() {
      if (value == true) {
        _selected.add(index);
      } else {
        _selected.remove(index);
      }
    });

    return Card.filled(
      margin: EdgeInsets.zero,
      clipBehavior: .antiAlias,
      child: InkWell(
        canRequestFocus: false,
        excludeFromSemantics: true,
        onTap: () => setSelected(!selected),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: thumbnail == null
                      ? const SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(color: _background.toColor()),
                          child: RawImage(
                            image: thumbnail,
                            fit: .contain,
                            invertColors: _invert,
                          ),
                        ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: ExcludeSemantics(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: .ellipsis,
                        style: TextTheme.of(context).bodySmall,
                      ),
                    ),
                  ),
                  Checkbox(
                    value: selected,
                    onChanged: setSelected,
                    semanticLabel: label,
                    materialTapTargetSize: .shrinkWrap,
                    visualDensity: .compact,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _applyStudyPreset({
    required double rightMargin,
    required double bottomMargin,
    required double gap,
    required bool spread,
  }) {
    setState(() {
      _draftMarginRightPercent = rightMargin;
      _draftMarginBottomPercent = bottomMargin;
      _pageGap = gap;
      _spreadToPages = spread;
      _createAreas = true;
      _includeMarginInArea = true;
    });
  }

  Widget _buildSettings(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      child: Column(
        crossAxisAlignment: .stretch,
        children: [
          ExactSlider(
            header: Text(loc.pdfScale, style: TextTheme.of(context).titleSmall),
            label: '%',
            value: _scalePercent,
            defaultValue: _defaultScalePercent,
            min: 10,
            max: 1000,
            sliderStep: 1,
            fractionDigits: 0,
            clampValue: true,
            inline: false,
            onChanged: (value) => setState(() => _scalePercent = value),
          ),
          const SizedBox(height: 12),
          TextFormField(
            decoration: InputDecoration(
              labelText: LeapLocalizations.of(context).name,
              filled: true,
            ),
            initialValue: _name,
            onChanged: (value) => _name = value,
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: .zero,
            secondary: const PhosphorIcon(PhosphorIconsLight.files),
            value: _spreadToPages,
            onChanged: (value) => setState(() => _spreadToPages = value),
            title: Text(loc.spreadToPages),
          ),
          const Divider(height: 1),
          ExpansionTile(
            tilePadding: .zero,
            leading: const PhosphorIcon(PhosphorIconsLight.slidersHorizontal),
            title: Text(loc.moreOptions),
            children: [
              CheckboxListTile(
                contentPadding: .zero,
                value: _createAreas,
                onChanged: (value) => setState(() => _createAreas = value!),
                title: Text(loc.createAreas),
              ),
              CheckboxListTile(
                contentPadding: .zero,
                value: _createExportPreset,
                onChanged: (value) =>
                    setState(() => _createExportPreset = value!),
                title: Text(loc.pdfImportCreateExportPreset),
              ),
              const Divider(height: 1),
              ColorField(
                value: _background.withValues(a: 255),
                custom: true,
                onChanged: (value) => setState(() {
                  _background = value.withValues(a: _background.a);
                }),
                title: Text(loc.background),
              ),
              ExactSlider(
                header: Text(loc.alpha),
                value: _background.a.toDouble(),
                fractionDigits: 0,
                min: 0,
                max: 255,
                sliderStep: 1,
                defaultValue: 255,
                clampValue: true,
                inline: false,
                onChanged: (value) => setState(() {
                  _background = _background.withValues(a: value.toInt());
                }),
              ),
              CheckboxListTile(
                contentPadding: .zero,
                value: _invert,
                onChanged: (value) => setState(() => _invert = value!),
                title: Text(loc.invert),
              ),
            ],
          ),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Text(
            '教材 / 试卷快速预设',
            style: TextTheme.of(context).titleSmall,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('原样导入'),
                selected:
                    _draftMarginRightPercent == 0 &&
                    _draftMarginBottomPercent == 0 &&
                    _pageGap == 0,
                onSelected: (_) => _applyStudyPreset(
                  rightMargin: 0,
                  bottomMargin: 0,
                  gap: 0,
                  spread: _spreadToPages,
                ),
              ),
              ChoiceChip(
                label: const Text('刷卷模式(+右侧草稿区)'),
                selected:
                    !_spreadToPages &&
                    _draftMarginRightPercent == 50 &&
                    _draftMarginBottomPercent == 15,
                onSelected: (_) => _applyStudyPreset(
                  rightMargin: 50,
                  bottomMargin: 15,
                  gap: 48,
                  spread: false,
                ),
              ),
              ChoiceChip(
                label: const Text('厚教材模式(分页+笔记栏)'),
                selected:
                    _spreadToPages &&
                    _draftMarginRightPercent == 35 &&
                    _draftMarginBottomPercent == 0,
                onSelected: (_) => _applyStudyPreset(
                  rightMargin: 35,
                  bottomMargin: 0,
                  gap: 0,
                  spread: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(height: 1),
          ExpansionTile(
            tilePadding: .zero,
            leading: const PhosphorIcon(PhosphorIconsLight.arrowsOut),
            title: const Text('草稿区与页面间距'),
            children: [
              ExactSlider(
                header: const Text('右侧草稿边距'),
                label: '%',
                value: _draftMarginRightPercent,
                defaultValue: 0,
                min: 0,
                max: 100,
                sliderStep: 5,
                fractionDigits: 0,
                clampValue: true,
                inline: false,
                onChanged: (value) =>
                    setState(() => _draftMarginRightPercent = value),
              ),
              ExactSlider(
                header: const Text('底部草稿边距'),
                label: '%',
                value: _draftMarginBottomPercent,
                defaultValue: 0,
                min: 0,
                max: 100,
                sliderStep: 5,
                fractionDigits: 0,
                clampValue: true,
                inline: false,
                onChanged: (value) =>
                    setState(() => _draftMarginBottomPercent = value),
              ),
              if (!_spreadToPages)
                ExactSlider(
                  header: const Text('连续页间距'),
                  label: 'px',
                  value: _pageGap,
                  defaultValue: 0,
                  min: 0,
                  max: 120,
                  sliderStep: 8,
                  fractionDigits: 0,
                  clampValue: true,
                  inline: false,
                  onChanged: (value) => setState(() => _pageGap = value),
                ),
              CheckboxListTile(
                contentPadding: .zero,
                value: _includeMarginInArea,
                onChanged: (value) =>
                    setState(() => _includeMarginInArea = value!),
                title: const Text('导出区域包含草稿留白'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
