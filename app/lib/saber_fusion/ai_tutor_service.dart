import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'study_state.dart';

class AiProviderPreset {
  final String name;
  final String baseUrl;
  final String defaultModel;

  const AiProviderPreset({
    required this.name,
    required this.baseUrl,
    required this.defaultModel,
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
    ),
    AiProviderPreset(
      name: '通义千问 VL (阿里云百炼)',
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      defaultModel: 'qwen-vl-max',
    ),
    AiProviderPreset(
      name: '硅基流动 (Qwen2.5-VL)',
      baseUrl: 'https://api.siliconflow.cn/v1',
      defaultModel: 'Qwen/Qwen2.5-VL-72B-Instruct',
    ),
    AiProviderPreset(
      name: 'Gemini (OpenAI 兼容)',
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
      defaultModel: 'gemini-2.5-flash',
    ),
    AiProviderPreset(
      name: '本地 Ollama (视觉模型)',
      baseUrl: 'http://127.0.0.1:11434/v1',
      defaultModel: 'qwen2.5vl:7b',
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

  static Uri _buildCompletionsUri(String rawBaseUrl) {
    var normalized = rawBaseUrl.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    if (normalized.endsWith('/chat/completions')) {
      return Uri.parse(normalized);
    }
    return Uri.parse('$normalized/chat/completions');
  }

  static Future<String> askTutor({
    required AiTutorConfig config,
    required Uint8List imageBytes,
    required String prompt,
  }) async {
    if (config.baseUrl.trim().isEmpty || config.model.trim().isEmpty) {
      throw const AiTutorException('请先在设置中填写 API Base URL 与模型名称。');
    }
    final isLocal =
        config.baseUrl.contains('127.0.0.1') ||
        config.baseUrl.contains('localhost');
    if (config.apiKey.trim().isEmpty && !isLocal) {
      throw const AiTutorException('请先在 AI 设置中填写 API Key。');
    }

    final uri = _buildCompletionsUri(config.baseUrl);
    final b64 = base64Encode(imageBytes);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      if (config.apiKey.trim().isNotEmpty)
        'Authorization': 'Bearer ${config.apiKey.trim()}',
    };
    final body = jsonEncode({
      'model': config.model.trim(),
      'messages': [
        if (config.systemPrompt.trim().isNotEmpty)
          {'role': 'system', 'content': config.systemPrompt.trim()},
        {
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text': prompt.trim().isEmpty
                  ? promptPresets.first.$2
                  : prompt.trim(),
            },
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,$b64'},
            },
          ],
        },
      ],
      'temperature': 0.3,
    });

    final http.Response response;
    try {
      response = await http
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 90));
    } catch (error) {
      throw AiTutorException('网络请求失败：$error');
    }

    final decodedText = utf8.decode(response.bodyBytes);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      String detail = decodedText;
      try {
        final jsonMap = jsonDecode(decodedText);
        if (jsonMap is Map && jsonMap['error'] is Map) {
          detail =
              (jsonMap['error']['message'] as String?) ?? decodedText;
        }
      } catch (_) {}
      throw AiTutorException('模型返回错误 (${response.statusCode})：$detail');
    }

    final dynamic parsed = jsonDecode(decodedText);
    if (parsed is! Map<String, dynamic>) {
      throw const AiTutorException('模型响应格式无效。');
    }
    final choices = parsed['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const AiTutorException('模型未返回有效回答。');
    }
    final message = choices.first['message'];
    final content = message is Map ? message['content'] : null;
    if (content is String) {
      return content.trim();
    }
    if (content is List) {
      final buffer = StringBuffer();
      for (final part in content) {
        if (part is Map && part['text'] is String) {
          buffer.write(part['text']);
        }
      }
      final joined = buffer.toString().trim();
      if (joined.isNotEmpty) return joined;
    }
    throw const AiTutorException('未能从模型响应中解析文本内容。');
  }
}
