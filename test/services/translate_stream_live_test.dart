import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// v2.2.1 流式译文上屏 + token 用量统计（服务层端到端）：
/// - 本地 SSE 服务器模拟 chat/completions 流式响应，验证
///   content 增量以 delta 事件实时回调、尾包 usage 解析累计
/// - parseLiveTranscript：累积的原始 JSON 增量 → 可读译文预览
void main() {
  final zh = TranslateLanguage.presets.first;

  SubtitleDocument doc(int n) => SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [
          for (var i = 0; i < n; i++)
            SubtitleCue(
              index: i,
              start: Duration(milliseconds: i * 1000),
              end: Duration(milliseconds: i * 1000 + 900),
              rawText: 'line $i',
            ),
        ],
      );

  group('SSE 端到端（localhost）：delta 事件与 usage 尾包', () {
    test('content 增量 → delta 事件实时回调；尾包 usage → onUsage', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final usages = <AiUsage>[];
      final events = <TranslateEvent>[];
      const contentChunks = [
        '{"lines":["',
        '你好',
        '","',
        '世界',
        '"]}',
      ];
      const usageJson =
          '{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":40,"total_tokens":140}}';
      final sub = server.listen((req) async {
        req.response.headers.contentType =
            ContentType.parse('text/event-stream; charset=utf-8');
        for (final c in contentChunks) {
          req.response.write(
              'data: ${jsonEncode({'choices': [ {'delta': {'content': c}} ]})}\n\n');
        }
        req.response.write('data: $usageJson\n\n');
        req.response.write('data: [DONE]\n\n');
        await req.response.close();
      });

      final config = AiApiConfig(
        baseUrl: 'http://127.0.0.1:${server.port}',
        apiKey: 'k',
        model: 'm',
      );
      final out = await TranslationService.instance.translateDocument(
        doc(2),
        config: config,
        target: zh,
        onEvent: events.add,
        onUsage: usages.add,
      );
      await sub.cancel();
      await server.close();

      expect(out.cues[0].rawText, '你好');
      expect(out.cues[1].rawText, '世界');

      final deltas =
          events.where((e) => e.kind == TranslateEventKind.delta).toList();
      expect(deltas, isNotEmpty, reason: 'content 增量应产生 delta 事件');
      expect(deltas.map((e) => e.text).toList(), contentChunks,
          reason: 'delta 事件按到达顺序携带原始增量');
      // 顺序：batchStart → deltas… → batchDone
      final kinds = [for (final e in events) e.kind];
      expect(kinds.indexOf(TranslateEventKind.batchStart),
          lessThan(kinds.indexOf(TranslateEventKind.delta)));
      expect(kinds.lastIndexOf(TranslateEventKind.delta),
          lessThan(kinds.indexOf(TranslateEventKind.batchDone)));

      expect(usages, hasLength(1), reason: 'usage 尾包解析一次');
      expect(usages.single.totalTokens, 140);
      expect(usages.single.promptTokens, 100);
      expect(usages.single.completionTokens, 40);
    });
  });

  group('parseLiveTranscript：累积原始增量 → 可读译文', () {
    test('完整 JSON 对象：仅提取 lines 值，键与脚手架不出现', () {
      expect(
        TranslationService.parseLiveTranscript('{"lines":["你好","世界"]}'),
        '你好\n世界',
      );
    });

    test('部分增量：尾部未闭合字符串逐字上屏', () {
      expect(
        TranslationService.parseLiveTranscript('{"lines":["你好","世'),
        '你好\n世',
      );
    });

    test('旧契约纯数组同样支持', () {
      expect(TranslationService.parseLiveTranscript('["a","b"]'), 'a\nb');
    });

    test('转义还原：\\n / \\" / \\\\ / \\uXXXX', () {
      expect(
        TranslationService.parseLiveTranscript(
            '{"lines":["行一\\n行二","带\\"引号\\"","反\\\\斜杠","\\u4e16界"]}'),
        '行一\n行二\n带"引号"\n反\\斜杠\n世界',
      );
    });

    test('非 JSON 流（模型直接输出文本）：原样返回尾部', () {
      expect(TranslationService.parseLiveTranscript('好的，正在翻译'), '好的，正在翻译');
    });
  });

  group('AiUsage', () {
    test('operator+ 累计', () {
      const a = AiUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15);
      const b = AiUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3);
      expect(a + b, const AiUsage(promptTokens: 11, completionTokens: 7, totalTokens: 18));
    });
  });
}
