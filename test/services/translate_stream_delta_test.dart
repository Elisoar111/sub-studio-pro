import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// v2.2.1 流式译文上屏：
/// SSE content delta 逐字回调（此前只在批完成时显示预览），
/// 直播面板实时显示当前批次译文增量。
void main() {
  group('SseStreamParser：SSE 行流 → reasoning/content 增量回调', () {
    test('content 增量按到达顺序逐段回调', () {
      final chunks = <String>[];
      final parser = SseStreamParser(onContent: chunks.add);
      parser
        ..feed('data: {"choices":[{"delta":{"content":"你"}}]}')
        ..feed('')
        ..feed('data: {"choices":[{"delta":{"content":"好，"}}]}')
        ..feed('')
        ..feed('data: {"choices":[{"delta":{"content":"世界"}}]}')
        ..feed('')
        ..close();
      expect(chunks, ['你', '好，', '世界']);
    });

    test('reasoning 与 content 混合到达时分发到各自回调', () {
      final think = <String>[];
      final content = <String>[];
      final parser = SseStreamParser(onThinking: think.add, onContent: content.add);
      parser
        ..feed('data: {"choices":[{"delta":{"reasoning_content":"先想"}}]}')
        ..feed('')
        ..feed('data: {"choices":[{"delta":{"content":"后说"}}]}')
        ..feed('')
        ..close();
      expect(think, ['先想']);
      expect(content, ['后说']);
    });

    test('多行 data: 拼接为单个载荷（跨行 JSON）', () {
      final content = <String>[];
      final parser = SseStreamParser(onContent: content.add);
      parser
        ..feed('data: {"choices":[{"delta":{"content":"跨')
        ..feed('data: 行载荷"}}]}')
        ..feed('')
        ..close();
      expect(content, ['跨行载荷']);
    });

    test('close() 冲刷未遇空行的尾包', () {
      final content = <String>[];
      final parser = SseStreamParser(onContent: content.add);
      parser
        ..feed('data: {"choices":[{"delta":{"content":"尾包"}}]}')
        ..close();
      expect(content, ['尾包']);
    });

    test('[DONE] / 空载荷 / 非 JSON 行 / 注释行：忽略不抛异常', () {
      final parser = SseStreamParser(onContent: (_) => fail('不应回调'));
      parser
        ..feed('data: [DONE]')
        ..feed('')
        ..feed('data: not-json')
        ..feed('')
        ..feed(': keep-alive comment')
        ..feed('event: message')
        ..feed('')
        ..close();
    });
  });

  group('流式译文事件契约', () {
    test('TranslateEventKind.delta 存在（译文增量事件）', () {
      expect(TranslateEventKind.values, contains(TranslateEventKind.delta));
    });
  });

  group('parseSseUsage（S3 预留验证：usage 尾包可独立解析）', () {
    test('usage 尾包：choices 为空 + usage 字段', () {
      final payload = jsonEncode({
        'choices': [],
        'usage': {
          'prompt_tokens': 120,
          'completion_tokens': 80,
          'total_tokens': 200,
        },
      });
      final u = TranslationService.parseSseUsage(payload);
      expect(u, isNotNull);
      expect(u!.promptTokens, 120);
      expect(u.completionTokens, 80);
      expect(u.totalTokens, 200);
    });

    test('无 usage 的载荷返回 null', () {
      expect(
        TranslationService.parseSseUsage('{"choices":[{"delta":{"content":"x"}}]}'),
        isNull,
      );
      expect(TranslationService.parseSseUsage('[DONE]'), isNull);
    });
  });
}
