import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/services/ai/ai_providers.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// AI 模型列表：通过 API Key 从服务商 /models 接口获取（不预置模型名）。
void main() {
  group('AiApiConfig.modelsUrl（BaseURL 归一化）', () {
    test('仅 host：自动补 /v1/models', () {
      const c = AiApiConfig(baseUrl: 'https://api.openai.com', apiKey: 'k', model: 'm');
      expect(c.modelsUrl, 'https://api.openai.com/v1/models');
    });

    test('已带 /v1：不重复追加', () {
      const c = AiApiConfig(baseUrl: 'https://api.deepseek.com/v1', apiKey: 'k', model: 'm');
      expect(c.modelsUrl, 'https://api.deepseek.com/v1/models');
    });

    test('尾斜杠：清理后归一化', () {
      const c = AiApiConfig(baseUrl: 'https://api.moonshot.cn/', apiKey: 'k', model: 'm');
      expect(c.modelsUrl, 'https://api.moonshot.cn/v1/models');
    });

    test('带路径的 BaseURL 原样保留（Gemini OpenAI 兼容端点）', () {
      const c = AiApiConfig(
        baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai/',
        apiKey: 'k',
        model: 'm',
      );
      expect(c.modelsUrl,
          'https://generativelanguage.googleapis.com/v1beta/openai/models');
    });

    test('chatCompletionsUrl：带路径 BaseURL 同样原样保留', () {
      const c = AiApiConfig(
        baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
        apiKey: 'k',
        model: 'm',
      );
      expect(c.chatCompletionsUrl,
          'https://open.bigmodel.cn/api/paas/v4/chat/completions');
    });
  });

  group('TranslationService.parseModelsJson', () {
    test('标准 OpenAI 格式：提取 id 并排序', () {
      final ids = TranslationService.parseModelsJson(
        '{"data":[{"id":"gpt-4o"},{"id":"gpt-4o-mini"},{"id":"o3"}]}',
      );
      expect(ids, ['gpt-4o', 'gpt-4o-mini', 'o3']);
    });

    test('重复 id 去重', () {
      final ids = TranslationService.parseModelsJson(
        '{"data":[{"id":"m"},{"id":"a"},{"id":"m"}]}',
      );
      expect(ids, ['a', 'm']);
    });

    test('空 data 返回空列表', () {
      expect(TranslationService.parseModelsJson('{"data":[]}'), isEmpty);
      expect(TranslationService.parseModelsJson('{}'), isEmpty);
    });

    test('非 JSON 内容抛格式异常', () {
      expect(
        () => TranslationService.parseModelsJson('<html>Bad Gateway</html>'),
        throwsFormatException,
      );
    });
  });

  group('aiProviders 预置服务商（仅 BaseURL，不含模型名）', () {
    test('id 唯一且名称非空', () {
      final ids = aiProviders.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final p in aiProviders) {
        expect(p.name.trim(), isNotEmpty);
      }
    });

    test('除自定义外均预置 baseUrl', () {
      for (final p in aiProviders) {
        if (p.id == 'custom') continue;
        expect(p.baseUrl.startsWith('https://'), isTrue,
            reason: '${p.id} 缺少 baseUrl');
      }
    });

    test('末项为自定义（baseUrl 为空）', () {
      final last = aiProviders.last;
      expect(last.id, 'custom');
      expect(last.baseUrl, isEmpty);
    });

    test('含主流服务商：OpenAI/DeepSeek/Gemini/Claude/通义/GLM/Kimi', () {
      final ids = aiProviders.map((p) => p.id).toSet();
      for (final expectId in [
        'openai', 'deepseek', 'gemini', 'anthropic', 'qwen', 'glm', 'moonshot',
      ]) {
        expect(ids, contains(expectId), reason: '缺少预置服务商 $expectId');
      }
    });
  });
}
