import 'dart:math';
import 'dart:ui' as ui;

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_leap/material_leap.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'mistake_bank_service.dart';

class MistakeBankTab extends StatefulWidget {
  const MistakeBankTab({super.key});

  @override
  State<MistakeBankTab> createState() => _MistakeBankTabState();
}

class _MistakeBankTabState extends State<MistakeBankTab> {
  final TextEditingController _filterCtrl = TextEditingController();
  MistakeMastery? _masteryFilter;
  String? _expandedId;

  @override
  void initState() {
    super.initState();
    MistakeBankService.instance.ensureLoaded();
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  List<MistakeEntry> _filtered(List<MistakeEntry> all) {
    final query = _filterCtrl.text.trim().toLowerCase();
    return all.where((entry) {
      if (_masteryFilter != null && entry.mastery != _masteryFilter) {
        return false;
      }
      if (query.isNotEmpty) {
        final haystack =
            '${entry.subject} ${entry.documentName} ${entry.note} ${entry.aiExplanation}'
                .toLowerCase();
        if (!haystack.contains(query)) return false;
      }
      return true;
    }).toList();
  }

  Future<void> _insertToCanvas(MistakeEntry entry) async {
    final bloc = context.read<DocumentBloc>();
    final state = bloc.state;
    if (state is! DocumentLoadSuccess) return;
    final bytes = await MistakeBankService.instance.readImageBytes(entry);
    if (bytes == null || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到该错题的截图文件')),
        );
      }
      return;
    }

    final codec = await ui.instantiateImageCodec(bytes);
    late final ui.Image decoded;
    try {
      final frame = await codec.getNextFrame();
      decoded = frame.image;
    } finally {
      codec.dispose();
    }
    final rawWidth = decoded.width.toDouble();
    final rawHeight = decoded.height.toDouble();
    decoded.dispose();

    final targetScale = rawWidth > 0 ? min(1.0, 360.0 / rawWidth) : 1.0;
    final displayW = rawWidth * targetScale;
    final displayH = rawHeight * targetScale;

    final viewportCenter = context.read<TransformCubit>().state.localToGlobal(
      MediaQuery.sizeOf(context).center(Offset.zero),
    );
    final topLeft = Point<double>(
      viewportCenter.dx - displayW / 2,
      viewportCenter.dy - displayH / 2,
    );

    final dataUrl = Uri.dataFromBytes(bytes, mimeType: 'image/png').toString();
    final elements = <PadElement>[
      ImageElement(
        id: createUniqueId(),
        position: topLeft,
        width: rawWidth,
        height: rawHeight,
        constraints: ElementConstraints.scaled(
          scaleX: targetScale,
          scaleY: targetScale,
        ),
        source: dataUrl,
        collection: state.currentCollection,
      ),
    ];

    final textParts = <String>[
      '**【${entry.subject}错题】**',
      if (entry.note.isNotEmpty) '错因：${entry.note}',
      if (entry.aiExplanation.isNotEmpty) entry.aiExplanation,
    ];
    if (textParts.length > 1) {
      elements.add(
        MarkdownElement(
          id: createUniqueId(),
          position: Point<double>(topLeft.x, topLeft.y + displayH + 16),
          scale: 1.0,
          text: textParts.join('\n\n'),
          constraint: const ElementConstraint(size: 500),
          foreground: SRGBColor.black,
          collection: state.currentCollection,
        ),
      );
    }

    bloc.add(
      ElementsCreated(
        elements,
        pageName: state.pageName,
        layer: state.currentLayer,
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已将错题贴入当前画布')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = MistakeBankService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final items = _filtered(service.entries);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _filterCtrl,
                      decoration: const InputDecoration(
                        hintText: '搜索科目 / 笔记 / 知识点',
                        isDense: true,
                        filled: true,
                        prefixIcon: PhosphorIcon(
                          PhosphorIconsLight.magnifyingGlass,
                          size: 16,
                        ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: '复制导出全部筛选错题 (Markdown)',
                    onPressed: items.isEmpty
                        ? null
                        : () {
                            final md = service.exportMarkdown(items);
                            Clipboard.setData(ClipboardData(text: md));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('已复制 ${items.length} 条错题 Markdown'),
                              ),
                            );
                          },
                    icon: const PhosphorIcon(PhosphorIconsLight.copy),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  ChoiceChip(
                    label: Text('全部 (${service.entries.length})'),
                    selected: _masteryFilter == null,
                    onSelected: (_) => setState(() => _masteryFilter = null),
                  ),
                  const SizedBox(width: 6),
                  for (final mastery in MistakeMastery.values) ...[
                    ChoiceChip(
                      label: Text(mastery.label),
                      selected: _masteryFilter == mastery,
                      onSelected: (_) =>
                          setState(() => _masteryFilter = mastery),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '暂无错题记录。\n使用顶部「框选问 AI」截图后，可点击「存入错题本」归档复习。',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(10),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _buildCard(context, items[index]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, MistakeEntry entry) {
    final colorScheme = ColorScheme.of(context);
    final expanded = _expandedId == entry.id;
    final pageText =
        entry.pageNumber != null ? '第 ${entry.pageNumber} 页' : '';

    return Card.outlined(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    entry.subject,
                    style: TextTheme.of(context).labelSmall?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(entry.mastery.label),
                  onPressed: () => MistakeBankService.instance.updateMastery(
                    entry.id,
                    entry.mastery.next,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '贴入当前画布复习',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _insertToCanvas(entry),
                  icon: const PhosphorIcon(
                    PhosphorIconsLight.arrowSquareIn,
                    size: 18,
                  ),
                ),
                IconButton(
                  tooltip: '删除错题',
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      MistakeBankService.instance.deleteMistake(entry.id),
                  icon: const PhosphorIcon(PhosphorIconsLight.trash, size: 18),
                ),
              ],
            ),
            if (entry.documentName.isNotEmpty || pageText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [entry.documentName, pageText]
                      .where((s) => s.isNotEmpty)
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextTheme.of(context).bodySmall,
                ),
              ),
            const SizedBox(height: 6),
            InkWell(
              onTap: () => setState(
                () => _expandedId = expanded ? null : entry.id,
              ),
              child: FutureBuilder<Uint8List?>(
                future: MistakeBankService.instance.readImageBytes(entry),
                builder: (context, snapshot) {
                  final bytes = snapshot.data;
                  if (bytes == null) {
                    return const SizedBox(
                      height: 64,
                      child: Center(child: Text('题目截图加载中...')),
                    );
                  }
                  return Container(
                    constraints: BoxConstraints(
                      maxHeight: expanded ? 220 : 96,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colorScheme.outlineVariant),
                    ),
                    child: Image.memory(bytes, fit: BoxFit.contain),
                  );
                },
              ),
            ),
            if (entry.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '笔记：${entry.note}',
                  maxLines: expanded ? null : 2,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: TextTheme.of(context).bodySmall,
                ),
              ),
            if (entry.aiExplanation.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                onTap: () => setState(
                  () => _expandedId = expanded ? null : entry.id,
                ),
                child: Text(
                  expanded
                      ? entry.aiExplanation
                      : 'AI 讲解：${entry.aiExplanation}',
                  maxLines: expanded ? null : 2,
                  overflow: expanded ? null : TextOverflow.ellipsis,
                  style: TextTheme.of(context).bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
