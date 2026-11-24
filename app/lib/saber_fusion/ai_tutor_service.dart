import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:http/http.dart' as http;

import 'ocr_models.dart';
import 'study_state.dart';

class AiProviderPreset {
  final String name;
  final String baseUrl;
  final String defaultModel;
  final String defaultVisionModel;

  const AiProviderPreset({
    required this.name,
    required this.baseUrl,
    required this.defaultModel,
    this.defaultVisionModel = '',
  });
}

class AiTutorException implements Exception {
  final String message;

  const AiTutorException(this.message);

  @override
  String toString() => message;
}

class AiTutorService {
  const AiTutorService._();

  static const providerPresets = <AiProviderPreset>[
    AiProviderPreset(
      name: 'OpenAI (GPT-4o-mini)',
      baseUrl: 'https://api.openai.com/v1',
      defaultModel: 'gpt-4o-mini',
      defaultVisionModel: 'gpt-4o-mini',
    ),
    AiProviderPreset(
      name: 'DeepSeek (V3)',
      baseUrl: 'https://api.deepseek.com/v1',
      defaultModel: 'deepseek-chat',
    ),
    AiProviderPreset(
      name: '通义千问 (Qwen)',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      defaultModel: 'qwen-plus',
      defaultVisionModel: 'qwen-vl-max',
    ),
    AiProviderPreset(
      name: '硅基流动 (SiliconFlow)',
      baseUrl: 'https://api.siliconflow.cn/v1',
      defaultModel: 'Qwen/Qwen2.5-72B-Instruct',
      defaultVisionModel: 'Qwen/Qwen2.5-VL-72B-Instruct',
    ),
    AiProviderPreset(
      name: 'Gemini (OpenAI 兼容)',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      defaultModel: 'gemini-2.5-flash',
      defaultVisionModel: 'gemini-2.5-flash',
    ),
    AiProviderPreset(
      name: '智谱 GLM',
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      defaultModel: 'glm-4-flash',
      defaultVisionModel: 'glm-4v-flash',
    ),
    AiProviderPreset(
      name: '本地 Ollama',
      baseUrl: 'http://127.0.0.1:11434/v1',
      defaultModel: 'qwen2.5vl:7b',
      defaultVisionModel: 'qwen2.5vl:7b',
    ),
  ];

  static const promptPresets = <(String label, String prompt)>[
    (
      '分步讲解',
      '请先识别图片中的题目或内容，然后给出清晰的分步解题思路、关键公式与最终答案。',
    ),
    (
      '只给提示',
      '请不要直接给出完整答案，先帮我分析题干关键条件，只提供下一步切入点与思路提示。',
    ),
    (
      '批改解答',
      '请检查图片中我的手写解题步骤是否正确，指出哪一步有误或可以优化，并给出订正方法。',
    ),
    (
      '提取考点',
      '请总结图片内容涉及的核心概念、公式定理、常见易错点，并给出记忆口诀或变形方向。',
    ),
  ];

  static bool isLocalUrl(String rawUrl) =>
      rawUrl.contains('127.0.0.1') || rawUrl.contains('localhost');

  static String normalizeBaseRoot(String rawBaseUrl) {
    var u = rawBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isEmpty) {
      throw const AiTutorException('请先填写 OpenAI 兼容接口地址（Base URL）。');
    }
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(u)) {
      u = '${isLocalUrl(u) ? 'http' : 'https'}://$u';
    }
    return u;
  }

  static Uri normalizeCompletionsUri(String rawBaseUrl) {
    var u = normalizeBaseRoot(rawBaseUrl);
    if (RegExp(r'/chat/completions$', caseSensitive: false).hasMatch(u)) {
      return Uri.parse(u);
    }
    if (!RegExp(r'/v\d+(?:[A-Za-z]*)(?:/|$)', caseSensitive: false).hasMatch(u)) {
      u = '$u/v1';
    }
    return Uri.parse('$u/chat/completions');
  }

  static Uri normalizeModelsUri(String rawBaseUrl) {
    var u = normalizeBaseRoot(rawBaseUrl).replaceFirst(
      RegExp(r'/chat/completions$', caseSensitive: false),
      '',
    );
    if (!RegExp(r'/v\d+(?:[A-Za-z]*)(?:/|$)', caseSensitive: false).hasMatch(u)) {
      u = '$u/v1';
    }
    return Uri.parse('$u/models');
  }

  static AiTutorException _classifyHttp(int status, String bodyText) {
    var detail = '';
    try {
      final decoded = jsonDecode(bodyText);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] != null) {
          detail = err['message'].toString();
        } else if (decoded['message'] != null) {
          detail = decoded['message'].toString();
        }
      }
    } catch (_) {
      detail = bodyText;
    }
    if (detail.isEmpty) detail = bodyText;
    if (detail.length > 200) {
      detail = '${detail.substring(0, 200)}...';
    }

    final prefix = switch (status) {
      400 => '请求被拒绝（请检查模型名或参数）',
      401 => 'API Key 无效或未授权',
      403 => '无权访问该接口或模型',
      404 => '接口地址或模型不存在（检查 Base URL 是否需带 /v1）',
      429 => '触发限流，请稍后再试',
      500 => '服务端内部错误',
      502 => '网关错误',
      503 => '服务暂不可用',
      _ => 'HTTP $status',
    };
    return AiTutorException(detail.isEmpty ? prefix : '$prefix：$detail');
  }

  static Future<({String content, String model, int latencyMs})> chat({
    required AiTutorConfig config,
    required List<Map<String, dynamic>> messages,
    bool isVision = false,
    String? modelOverride,
    int? maxTokens,
    double? temperature,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final modelName = (modelOverride?.trim().isNotEmpty == true)
        ? modelOverride!.trim()
        : (isVision ? config.effectiveVisionModel : config.model.trim());
    if (config.baseUrl.trim().isEmpty || modelName.isEmpty) {
      throw const AiTutorException('请先在 AI 设置中填写 Base URL 与模型名称。');
    }
    if (config.apiKey.trim().isEmpty && !isLocalUrl(config.baseUrl)) {
      throw const AiTutorException('请先在 AI 设置中填写 API Key。');
    }

    final uri = normalizeCompletionsUri(config.baseUrl);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (config.apiKey.trim().isNotEmpty)
        'Authorization': 'Bearer ${config.apiKey.trim()}',
    };
    final body = jsonEncode({
      'model': modelName,
      'messages': [
        if (config.systemPrompt.trim().isNotEmpty)
          {'role': 'system', 'content': config.systemPrompt.trim()},
        ...messages,
      ],
      'stream': false,
      'temperature': temperature ?? config.temperature,
      'max_tokens': maxTokens ?? config.maxTokens,
    });

    final stopwatch = Stopwatch()..start();
    final http.Response response;
    try {
      response = await http
          .post(uri, headers: headers, body: body)
          .timeout(timeout);
    } catch (error) {
      throw AiTutorException('网络请求失败：$error');
    }

    final decodedText = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _classifyHttp(response.statusCode, decodedText);
    }

    final dynamic parsed;
    try {
      parsed = jsonDecode(decodedText);
    } catch (_) {
      throw const AiTutorException('模型返回了非 JSON 内容。');
    }
    if (parsed is! Map<String, dynamic>) {
      throw const AiTutorException('模型响应格式无效。');
    }
    final choices = parsed['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiTutorException('模型未返回有效回答。');
    }
    final message = choices.first is Map ? choices.first['message'] : null;
    final content = message is Map ? message['content'] : null;
    String textOut = '';
    if (content is String) {
      textOut = content.trim();
    } else if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map && part['text'] is String) {
          buffer.write(part['text']);
        }
      }
      textOut = buffer.toString().trim();
    }
    if (textOut.isEmpty) {
      throw const AiTutorException('未能从模型响应中解析文本内容。');
    }
    return (
      content: textOut,
      model: (parsed['model'] as String?) ?? modelName,
      latencyMs: stopwatch.elapsedMilliseconds,
    );
  }

  static Future<String> askTutor({
    required AiTutorConfig config,
    required Uint8List imageBytes,
    required String prompt,
  }) async {
    final contentParts = <Map<String, dynamic>>[
      {
        'type': 'text',
        'text': prompt.trim().isEmpty ? promptPresets.first.$2 : prompt.trim(),
      },
      if (imageBytes.isNotEmpty)
        {
          'type': 'image_url',
          'image_url': {
            'url': 'data:image/png;base64,${base64Encode(imageBytes)}',
          },
        },
    ];
    final result = await chat(
      config: config,
      isVision: imageBytes.isNotEmpty,
      messages: [
        {'role': 'user', 'content': contentParts},
      ],
    );
    return result.content;
  }

  static Future<List<String>> fetchAvailableModels(AiTutorConfig config) async {
    final uri = normalizeModelsUri(config.baseUrl);
    if (config.apiKey.trim().isEmpty && !isLocalUrl(config.baseUrl)) {
      throw const AiTutorException('请先填写 API Key 再拉取模型列表。');
    }
    final headers = <String, String>{
      if (config.apiKey.trim().isNotEmpty)
        'Authorization': 'Bearer ${config.apiKey.trim()}',
    };
    final http.Response response;
    try {
      response = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));
    } catch (e) {
      throw AiTutorException('拉取模型失败：$e');
    }
    final decodedText = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _classifyHttp(response.statusCode, decodedText);
    }
    final parsed = jsonDecode(decodedText);
    final rawList = parsed is Map ? parsed['data'] : null;
    if (rawList is! List) return const [];
    final ids = <String>[];
    for (final item in rawList) {
      if (item is Map && item['id'] is String) {
        ids.add((item['id'] as String).trim());
      }
    }
    ids.sort();
    return ids;
  }

  static Future<({String reply, String model, int latencyMs})>
  testTextConnection(AiTutorConfig config) async {
    final res = await chat(
      config: config.copyWith(systemPrompt: ''),
      isVision: false,
      maxTokens: 32,
      timeout: const Duration(seconds: 25),
      messages: const [
        {'role': 'user', 'content': '请只回复两个字：正常'},
      ],
    );
    return (reply: res.content, model: res.model, latencyMs: res.latencyMs);
  }

  static Future<Uint8List> _solidTestPngBytes() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 24, 24),
      ui.Paint()..color = const ui.Color(0xFFB83253),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(24, 24);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List() ?? Uint8List(0);
    } finally {
      image.dispose();
    }
  }

  static Future<({String reply, String model, int latencyMs})>
  testVisionConnection(AiTutorConfig config) async {
    final png = await _solidTestPngBytes();
    final res = await chat(
      config: config.copyWith(systemPrompt: ''),
      isVision: true,
      maxTokens: 64,
      timeout: const Duration(seconds: 35),
      messages: [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '这张图片是什么颜色？只回答颜色名。'},
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/png;base64,${base64Encode(png)}',
                'detail': 'low',
              },
            },
          ],
        },
      ],
    );
    return (reply: res.content, model: res.model, latencyMs: res.latencyMs);
  }

  static Future<List<OcrTextLine>> ocrImageViaOpenAi({
    required AiTutorConfig config,
    required Uint8List pngBytes,
    required OcrLanguage language,
  }) async {
    if (pngBytes.isEmpty) return const [];
    final langHint = switch (language) {
      OcrLanguage.zhEn => '中文与英文',
      OcrLanguage.zhOnly => '简体/繁体中文',
      OcrLanguage.enOnly => '英文',
      OcrLanguage.jaEn => '日文与英文',
    };
    final res = await chat(
      config: config.copyWith(
        systemPrompt:
            '你是高精度学术教材与试卷 OCR 识别引擎。请逐行忠实转录图片中的所有文字与数学公式（以 $langHint 为主），保持原有换行结构；数学公式尽量用易读的符号或行内 LaTeX；不要添加任何解释、总结或 Markdown 代码围栏。',
      ),
      isVision: true,
      temperature: 0.0,
      maxTokens: math.max(1024, config.maxTokens),
      messages: [
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': '请直接按原顺序逐行输出图中全部文字：',
            },
            {
              'type': 'image_url',
              'image_url': {
                'url': 'data:image/png;base64,${base64Encode(pngBytes)}',
                'detail': 'high',
              },
            },
          ],
        },
      ],
    );

    final lines = res.content
        .split(RegExp(r'\r?\n'))
        .map((e) => e.trimRight())
        .where((e) => e.trim().isNotEmpty)
        .toList(growable: false);
    if (lines.isEmpty) return const [];

    final count = lines.length;
    final out = <OcrTextLine>[];
    for (var i = 0; i < count; i++) {
      final top = (0.04 + (i / math.max(1, count)) * 0.90).clamp(0.0, 0.98);
      final height = (0.86 / math.max(1, count)).clamp(0.015, 0.055);
      final bottom = (top + height).clamp(top + 0.01, 0.99);
      out.add(
        OcrTextLine(
          text: lines[i],
          left: 0.06,
          top: top,
          right: 0.94,
          bottom: bottom,
          words: [
            OcrWordBox(
              text: lines[i],
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
  }
}
