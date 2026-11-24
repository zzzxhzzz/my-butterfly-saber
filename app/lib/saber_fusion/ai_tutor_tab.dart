import 'dart:math';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:material_leap/material_leap.dart';
import 'package:material_ui/material_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'ai_tutor_service.dart';
import 'mistake_bank_service.dart';
import 'study_state.dart';

Future<void> showOpenAiApiSettingsDialog(BuildContext context) async {
  final studyCubit = maybeStudyModeCubit(context);
  if (studyCubit == null) return;
  final current = studyCubit.state.aiConfig;
  final urlCtrl = TextEditingController(text: current.baseUrl);
  final modelCtrl = TextEditingController(text: current.model);
  final visionCtrl = TextEditingController(text: current.visionModel);
  final keyCtrl = TextEditingController(text: current.apiKey);
  final tempCtrl = TextEditingController(
    text: current.temperature.toStringAsFixed(1),
  );
  final tokensCtrl = TextEditingController(text: '${current.maxTokens}');
  final promptCtrl = TextEditingController(text: current.systemPrompt);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _OpenAiApiSettingsDialog(
      urlCtrl: urlCtrl,
      modelCtrl: modelCtrl,
      visionCtrl: visionCtrl,
      keyCtrl: keyCtrl,
      tempCtrl: tempCtrl,
      tokensCtrl: tokensCtrl,
      promptCtrl: promptCtrl,
      onSave: (cfg) => studyCubit.updateAiConfig(cfg),
    ),
  );

  urlCtrl.dispose();
  modelCtrl.dispose();
  visionCtrl.dispose();
  keyCtrl.dispose();
  tempCtrl.dispose();
  tokensCtrl.dispose();
  promptCtrl.dispose();
}

class _OpenAiApiSettingsDialog extends StatefulWidget {
  final TextEditingController urlCtrl;
  final TextEditingController modelCtrl;
  final TextEditingController visionCtrl;
  final TextEditingController keyCtrl;
  final TextEditingController tempCtrl;
  final TextEditingController tokensCtrl;
  final TextEditingController promptCtrl;
  final Future<void> Function(AiTutorConfig config) onSave;

  const _OpenAiApiSettingsDialog({
    required this.urlCtrl,
    required this.modelCtrl,
    required this.visionCtrl,
    required this.keyCtrl,
    required this.tempCtrl,
    required this.tokensCtrl,
    required this.promptCtrl,
    required this.onSave,
  });

  @override
  State<_OpenAiApiSettingsDialog> createState() =>
      _OpenAiApiSettingsDialogState();
}

class _OpenAiApiSettingsDialogState extends State<_OpenAiApiSettingsDialog> {
  bool _obscureKey = true;
  bool _testing = false;
  bool _fetchingModels = false;
  String? _statusText;
  bool _statusIsError = false;

  AiTutorConfig _draftConfig() {
    final parsedTemp = double.tryParse(widget.tempCtrl.text.trim()) ?? 0.2;
    final parsedTokens = int.tryParse(widget.tokensCtrl.text.trim()) ?? 2048;
    return AiTutorConfig(
      baseUrl: widget.urlCtrl.text.trim(),
      model: widget.modelCtrl.text.trim(),
      visionModel: widget.visionCtrl.text.trim(),
      apiKey: widget.keyCtrl.text.trim(),
      systemPrompt: widget.promptCtrl.text.trim(),
      temperature: parsedTemp.clamp(0.0, 2.0),
      maxTokens: parsedTokens.clamp(64, 32768),
    );
  }

  String _endpointPreview() {
    final raw = widget.urlCtrl.text.trim();
    if (raw.isEmpty) return '填写后自动归一化为 .../v1/chat/completions';
    try {
      return '实际请求端点：${AiTutorService.normalizeCompletionsUri(raw)}';
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> _testConnection({required bool vision}) async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _statusText = vision ? '正在测试视觉识图连通性…' : '正在测试文本对话连通性…';
      _statusIsError = false;
    });
    try {
      final cfg = _draftConfig();
      if (vision) {
        final r = await AiTutorService.testVisionConnection(cfg);
        if (!mounted) return;
        setState(() {
          _statusText =
              '视觉识图正常（${r.latencyMs}ms · ${r.model}）回复：${r.reply}';
          _statusIsError = false;
        });
      } else {
        final r = await AiTutorService.testTextConnection(cfg);
        if (!mounted) return;
        setState(() {
          _statusText =
              '文本连通正常（${r.latencyMs}ms · ${r.model}）回复：${r.reply}';
          _statusIsError = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = e.toString();
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _fetchAndPickModel() async {
    if (_fetchingModels) return;
    setState(() {
      _fetchingModels = true;
      _statusText = '正在从 /models 拉取可用模型…';
      _statusIsError = false;
    });
    try {
      final models = await AiTutorService.fetchAvailableModels(_draftConfig());
      if (!mounted) return;
      if (models.isEmpty) {
        setState(() {
          _statusText = '接口未返回可用模型列表，请手动输入模型名。';
          _statusIsError = true;
        });
        return;
      }
      setState(() {
        _statusText = '成功拉取 ${models.length} 个模型，点击下方列表即可填入。';
        _statusIsError = false;
      });
      await showDialog<void>(
        context: context,
        builder: (pickCtx) => AlertDialog(
          title: Text('选择模型（共 ${models.length} 个）'),
          content: SizedBox(
            width: 380,
            height: 340,
            child: ListView.builder(
              itemCount: models.length,
              itemBuilder: (_, idx) {
                final id = models[idx];
                return ListTile(
                  dense: true,
                  title: Text(id),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          widget.modelCtrl.text = id;
                          Navigator.pop(pickCtx);
                        },
                        child: const Text('设为对话'),
                      ),
                      TextButton(
                        onPressed: () {
                          widget.visionCtrl.text = id;
                          Navigator.pop(pickCtx);
                        },
                        child: const Text('设为识图'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(pickCtx),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = e.toString();
        _statusIsError = true;
      });
    } finally {
      if (mounted) setState(() => _fetchingModels = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return AlertDialog(
      title: const Row(
        children: [
          PhosphorIcon(PhosphorIconsLight.sparkle, size: 18),
          SizedBox(width: 8),
          Text('OpenAI 格式 API 接口配置'),
        ],
      ),
      content: SizedBox(
        width: 470,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '常用 OpenAI 兼容服务商预设：',
                style: TextTheme.of(context).labelMedium,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final preset in AiTutorService.providerPresets)
                    ActionChip(
                      label: Text(
                        preset.name,
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () {
                        setState(() {
                          widget.urlCtrl.text = preset.baseUrl;
                          widget.modelCtrl.text = preset.defaultModel;
                          widget.visionCtrl.text = preset.defaultVisionModel;
                        });
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: widget.urlCtrl,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Base URL (支持 /v1、中转站、Ollama 等)',
                  hintText: 'https://api.openai.com/v1',
                  filled: true,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _endpointPreview(),
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: widget.keyCtrl,
                obscureText: _obscureKey,
                decoration: InputDecoration(
                  labelText: 'API Key（加密保存于本机安全存储）',
                  hintText: 'sk-...',
                  filled: true,
                  isDense: true,
                  suffixIcon: TextButton(
                    onPressed: () => setState(() => _obscureKey = !_obscureKey),
                    child: Text(_obscureKey ? '显示' : '隐藏'),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.modelCtrl,
                      decoration: const InputDecoration(
                        labelText: '对话模型名称',
                        hintText: 'gpt-4o-mini / deepseek-chat / qwen-plus',
                        filled: true,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _fetchingModels ? null : _fetchAndPickModel,
                    child: Text(_fetchingModels ? '拉取中…' : '拉取模型'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: widget.visionCtrl,
                decoration: const InputDecoration(
                  labelText: '视觉识图模型（可选，留空同对话模型）',
                  hintText: 'gpt-4o / qwen-vl-max / gemini-2.5-flash',
                  filled: true,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.tempCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Temperature (0~2)',
                        filled: true,
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: widget.tokensCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Max Tokens',
                        filled: true,
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: widget.promptCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '系统提示词',
                  filled: true,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  OutlinedButton(
                    onPressed: _testing
                        ? null
                        : () => _testConnection(vision: false),
                    child: const Text('测试文本连通'),
                  ),
                  OutlinedButton(
                    onPressed: _testing
                        ? null
                        : () => _testConnection(vision: true),
                    child: const Text('测试识图能力'),
                  ),
                ],
              ),
              if (_statusText != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _statusIsError
                        ? colorScheme.errorContainer
                        : colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    _statusText!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _statusIsError
                          ? colorScheme.onErrorContainer
                          : colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            await widget.onSave(_draftConfig());
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('保存配置'),
        ),
      ],
    );
  }
}

class AiTutorTab extends StatefulWidget {
  const AiTutorTab({super.key});

  @override
  State<AiTutorTab> createState() => _AiTutorTabState();
}

class _AiTutorTabState extends State<AiTutorTab> {
  final TextEditingController _promptController = TextEditingController();
  bool _loading = false;
  String? _response;
  String? _error;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _sendPrompt([String? presetPrompt]) async {
    final studyCubit = context.read<StudyModeCubit>();
    final snip = studyCubit.state.pendingSnip;
    if (snip == null || _loading) return;
    final rawPrompt = (presetPrompt ?? _promptController.text).trim();
    final basePrompt =
        rawPrompt.isEmpty ? AiTutorService.promptPresets.first.$2 : rawPrompt;
    final ocrText = snip.ocrText?.trim() ?? '';
    final effectivePrompt = ocrText.isEmpty
        ? basePrompt
        : '选中的文字内容：\n$ocrText\n\n请求：$basePrompt';
    if (presetPrompt != null) {
      _promptController.text = presetPrompt;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final answer = await AiTutorService.askTutor(
        config: studyCubit.state.aiConfig,
        imageBytes: snip.pngBytes,
        prompt: effectivePrompt,
      );
      if (!mounted) return;
      setState(() {
        _response = answer;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _insertNoteToCanvas() {
    final response = _response;
    final snip = context.read<StudyModeCubit>().state.pendingSnip;
    final bloc = context.read<DocumentBloc>();
    final state = bloc.state;
    if (response == null ||
        response.trim().isEmpty ||
        snip == null ||
        state is! DocumentLoadSuccess) {
      return;
    }

    final element = MarkdownElement(
      id: createUniqueId(),
      position: Point<double>(
        snip.canvasRect.right + 24,
        snip.canvasRect.top,
      ),
      scale: 1.0,
      text: response,
      constraint: const ElementConstraint(size: 520),
      foreground: SRGBColor.black,
      collection: state.currentCollection,
    );

    bloc.add(
      ElementsCreated(
        [element],
        pageName: state.pageName,
        layer: state.currentLayer,
      ),
    );
    context.read<StudyModeCubit>().incrementCanvasExcerptCount();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已将 AI 讲解贴到试卷旁（可拖动排版）')),
    );
  }

  Future<void> _saveToMistakeBank() async {
    final snip = context.read<StudyModeCubit>().state.pendingSnip;
    if (snip == null) return;
    final subjectCtrl = TextEditingController(text: '数学');
    final noteCtrl = TextEditingController(text: snip.ocrText ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('存入错题本'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: subjectCtrl,
              decoration: const InputDecoration(
                labelText: '科目 / 分类标签',
                hintText: '例如：高数 / 线代 / 物理 / 英语',
                filled: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '个人错因 / 备注（可选）',
                hintText: '例如：符号漏负号、公式记忆混淆',
                filled: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('保存错题'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await MistakeBankService.instance.addMistake(
        imageBytes: snip.pngBytes,
        subject: subjectCtrl.text,
        documentName: snip.documentName,
        pageNumber: snip.pdfPageNumber,
        note: noteCtrl.text,
        aiExplanation: _response ?? '',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已存入错题本')),
        );
      }
    }
    subjectCtrl.dispose();
    noteCtrl.dispose();
  }

  Future<void> _openAiSettingsDialog() => showOpenAiApiSettingsDialog(context);

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return BlocBuilder<StudyModeCubit, StudyModeState>(
      builder: (context, studyState) {
        final snip = studyState.pendingSnip;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          context.read<StudyModeCubit>().setAiSnippingMode(true),
                      icon: const PhosphorIcon(
                        PhosphorIconsLight.crop,
                        size: 16,
                      ),
                      label: Text(snip == null ? '框选题目/公式' : '重新框选'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'AI 接口与密钥设置',
                    onPressed: _openAiSettingsDialog,
                    icon: const PhosphorIcon(PhosphorIconsLight.gear),
                  ),
                ],
              ),
            ),
            if (!studyState.aiConfig.isConfigured &&
                !studyState.aiConfig.baseUrl.contains('127.0.0.1') &&
                !studyState.aiConfig.baseUrl.contains('localhost'))
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Card.outlined(
                  child: ListTile(
                    dense: true,
                    leading: const PhosphorIcon(PhosphorIconsLight.gear),
                    title: const Text('尚未配置 API Key'),
                    subtitle: const Text('点击右侧齿轮配置 OpenAI / 通义千问 / Gemini / Ollama'),
                    onTap: _openAiSettingsDialog,
                  ),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (snip == null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Column(
                        children: [
                          Icon(
                            PhosphorIconsLight.sparkle,
                            size: 40,
                            color: colorScheme.primary,
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            '点击上方「框选题目/公式」直接在试卷或教材上拖选区域，\nAI 将直接识图讲解，并支持一键贴回画布或存入错题本。',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    )
                  else ...[
                    if (snip.pngBytes.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 160),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.memory(
                          snip.pngBytes,
                          fit: BoxFit.contain,
                        ),
                      ),
                    if ((snip.ocrText ?? '').trim().isNotEmpty) ...[
                      if (snip.pngBytes.isNotEmpty) const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHigh,
                          border: Border.all(color: colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          snip.ocrText!.trim(),
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: TextTheme.of(context).bodySmall,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final preset in AiTutorService.promptPresets)
                          ActionChip(
                            label: Text(preset.$1),
                            onPressed: _loading
                                ? null
                                : () => _sendPrompt(preset.$2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _promptController,
                            minLines: 1,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              hintText: '输入追问（如：为什么这一步要换元？）',
                              isDense: true,
                              filled: true,
                            ),
                            onSubmitted: (_) => _sendPrompt(),
                          ),
                        ),
                        const SizedBox(width: 6),
                        IconButton.filled(
                          tooltip: '发送给 AI',
                          onPressed: _loading ? null : () => _sendPrompt(),
                          icon: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const PhosphorIcon(
                                  PhosphorIconsLight.paperPlaneRight,
                                  size: 18,
                                ),
                        ),
                      ],
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 10),
                      Card(
                        color: colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: SelectableText(
                            _error!,
                            style: TextStyle(
                              color: colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (_response != null) ...[
                      const SizedBox(height: 10),
                      Card.outlined(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: _MathFormattedText(_response!),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonalIcon(
                            onPressed: _insertNoteToCanvas,
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.arrowSquareIn,
                              size: 16,
                            ),
                            label: const Text('贴到试卷旁'),
                          ),
                          OutlinedButton.icon(
                            onPressed: _saveToMistakeBank,
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.notebook,
                              size: 16,
                            ),
                            label: const Text('存入错题本'),
                          ),
                          IconButton(
                            tooltip: '复制讲解文本',
                            onPressed: () {
                              Clipboard.setData(
                                ClipboardData(text: _response!),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已复制 AI 讲解内容')),
                              );
                            },
                            icon: const PhosphorIcon(
                              PhosphorIconsLight.copy,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ] else if (!_loading) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _saveToMistakeBank,
                        icon: const PhosphorIcon(
                          PhosphorIconsLight.notebook,
                          size: 16,
                        ),
                        label: const Text('直接存图到错题本'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MathFormattedText extends StatelessWidget {
  final String text;

  const _MathFormattedText(this.text);

  @override
  Widget build(BuildContext context) {
    final segments = _splitMathSegments(text);
    final baseStyle = TextTheme.of(context).bodyMedium ?? const TextStyle();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final seg in segments)
          if (seg.isDisplayMath)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Math.tex(
                  seg.content,
                  mathStyle: MathStyle.display,
                  textStyle: baseStyle,
                  onErrorFallback: (_) => SelectableText(seg.raw),
                ),
              ),
            )
          else if (seg.isInlineMath)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Math.tex(
                  seg.content,
                  mathStyle: MathStyle.text,
                  textStyle: baseStyle,
                  onErrorFallback: (_) => SelectableText(seg.raw),
                ),
              ),
            )
          else
            SelectableText(seg.content, style: baseStyle),
      ],
    );
  }
}

class _MathSegment {
  final String content;
  final String raw;
  final bool isDisplayMath;
  final bool isInlineMath;

  const _MathSegment({
    required this.content,
    required this.raw,
    this.isDisplayMath = false,
    this.isInlineMath = false,
  });
}

List<_MathSegment> _splitMathSegments(String input) {
  final regex = RegExp(
    r'\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\$([^\$\n]+?)\$|\\\(([^\n]+?)\\\)',
  );
  final result = <_MathSegment>[];
  var lastIndex = 0;
  for (final match in regex.allMatches(input)) {
    if (match.start > lastIndex) {
      final plain = input.substring(lastIndex, match.start).trim();
      if (plain.isNotEmpty) {
        result.add(_MathSegment(content: plain, raw: plain));
      }
    }
    final displayExpr = match.group(1) ?? match.group(2);
    final inlineExpr = match.group(3) ?? match.group(4);
    if (displayExpr != null) {
      result.add(
        _MathSegment(
          content: displayExpr.trim(),
          raw: match.group(0) ?? '',
          isDisplayMath: true,
        ),
      );
    } else if (inlineExpr != null) {
      result.add(
        _MathSegment(
          content: inlineExpr.trim(),
          raw: match.group(0) ?? '',
          isInlineMath: true,
        ),
      );
    }
    lastIndex = match.end;
  }
  if (lastIndex < input.length) {
    final tail = input.substring(lastIndex).trim();
    if (tail.isNotEmpty) {
      result.add(_MathSegment(content: tail, raw: tail));
    }
  }
  if (result.isEmpty && input.trim().isNotEmpty) {
    result.add(_MathSegment(content: input.trim(), raw: input.trim()));
  }
  return result;
}
