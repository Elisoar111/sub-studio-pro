import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// AI 翻译 system prompt 构造（v1.1 P2 测试补齐）：
/// prompt 直接决定译文质量，必须锁定关键规则不回归——
/// ASS 标签保留、硬换行保留、行数一致、纯 JSON 数组输出、目标语言注入。
void main() {
  group('translateSystemPrompt', () {
    for (final lang in TranslateLanguage.presets) {
      test('包含目标语言「${lang.name}」的指令', () {
        final p = translateSystemPrompt(lang);
        expect(p, contains(lang.prompt),
            reason: 'prompt 必须按目标语言参数化（${lang.code}）');
      });
    }

    test('锁定 ASS override 标签保留规则', () {
      final p = translateSystemPrompt(TranslateLanguage.presets.first);
      expect(p.toLowerCase(), contains('ass'));
      expect(p, contains(r'{\i1}'),
          reason: '样式标签示例必须原样出现在规则里');
    });

    test('锁定硬换行（\\N）保留规则', () {
      final p = translateSystemPrompt(TranslateLanguage.presets.first);
      // 规则原文使用 "backslash-N" 表述，避免字面 \N 转义歧义
      expect(p.toLowerCase(), contains('backslash-n'));
    });

    test('锁定行数一致与纯 JSON 数组输出要求', () {
      final p = translateSystemPrompt(TranslateLanguage.presets.first);
      expect(p, contains('same length'));
      expect(p, contains('JSON array'));
      expect(p, contains('ONLY'), reason: '禁止模型输出解释性文字');
    });
  });

  group('术语表注入（v1.2）', () {
    const glossary = [
      GlossaryTerm(source: 'Aria', translation: '亚里亚'),
      GlossaryTerm(source: 'K-ON!', translation: ''), // 空译文 = 不译
      GlossaryTerm(source: 'Sakura', translation: '小樱'),
    ];

    test('术语表注入「原文→译文」锁定段', () {
      final p = translateSystemPrompt(TranslateLanguage.presets.first,
          glossary: glossary);
      expect(p, contains('Glossary'));
      expect(p, contains('Aria => 亚里亚'));
      expect(p, contains('Sakura => 小樱'));
    });

    test('空译文条目生成「do not translate」指令', () {
      final p = translateSystemPrompt(TranslateLanguage.presets.first,
          glossary: glossary);
      expect(p, contains('K-ON! => do not translate'),
          reason: '「本片中 Aria 不译」类需求：译文留空即锁定原文');
    });

    test('无术语表时 prompt 与旧版一致（无 Glossary 段）', () {
      final p = translateSystemPrompt(TranslateLanguage.presets.first);
      expect(p.contains('Glossary'), isFalse);
    });
  });
}
