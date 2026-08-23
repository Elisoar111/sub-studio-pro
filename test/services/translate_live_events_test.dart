import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// v2.2 实时翻译过程：
/// - SSE 流式 chunk 纯解析（reasoning / content delta）
/// - translateDocument onEvent 事件序列（batchStart / batchDone / retry）
void main() {
  const config =
      AiApiConfig(baseUrl: 'https://api.test', apiKey: 'k', model: 'm');
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

  group('parseSseDelta', () {
    test('content chunk：提取 delta.content', () {
      final d = TranslationService.parseSseDelta(
          '{"choices":[{"index":0,"delta":{"content":"你好"}}]}');
      expect(d, isNotNull);
      expect(d!.content, '你好');
      expect(d.reasoning, isEmpty);
    });

    test('reasoning chunk：提取 delta.reasoning_content（DeepSeek R1 系）', () {
      final d = TranslationService.parseSseDelta(
          '{"choices":[{"delta":{"reasoning_content":"先分析语境"}}]}');
      expect(d, isNotNull);
      expect(d!.reasoning, '先分析语境');
      expect(d.content, isEmpty);
    });

    test('[DONE] 与空 choices（usage 尾包）：返回 null', () {
      expect(TranslationService.parseSseDelta('[DONE]'), isNull);
      expect(
        TranslationService.parseSseDelta(
            '{"choices":[],"usage":{"total_tokens":42}}'),
        isNull,
      );
    });

    test('非 JSON 载荷：返回 null 不抛异常', () {
      expect(TranslationService.parseSseDelta('not-json'), isNull);
    });
  });

  group('translateDocument onEvent 事件序列', () {
    test('批次序列：batchStart/batchDone 交替，索引与总数正确', () async {
      final events = <TranslateEvent>[];
      await TranslationService.instance.translateDocument(
        doc(65),
        config: config,
        target: zh,
        onEvent: events.add,
        chatOverride: ({required system, required user}) async {
          final n = (jsonDecode(user) as Map)['lines'] as List;
          return jsonEncode([for (var i = 0; i < n.length; i++) '译$i']);
        },
      );
      final kinds = [for (final e in events) e.kind];
      expect(kinds, [
        TranslateEventKind.batchStart,
        TranslateEventKind.batchDone,
        TranslateEventKind.batchStart,
        TranslateEventKind.batchDone,
        TranslateEventKind.batchStart,
        TranslateEventKind.batchDone,
      ], reason: '65 cue = 3 批，每批 start → done');
      expect(events.first.batchIndex, 0);
      expect(events.first.batchTotal, 3);
      expect(events.first.text, contains('line 0'),
          reason: 'batchStart 携带本批首行预览');
      expect(events.last.batchIndex, 2, reason: '0-based 索引');
    });

    test('batchDone 预览对：前 3 条 [原文, 译文]', () async {
      final events = <TranslateEvent>[];
      await TranslationService.instance.translateDocument(
        doc(35),
        config: config,
        target: zh,
        onEvent: events.add,
        chatOverride: ({required system, required user}) async {
          final n = (jsonDecode(user) as Map)['lines'] as List;
          return jsonEncode([for (var i = 0; i < n.length; i++) '译$i']);
        },
      );
      final done = events
          .lastWhere((e) => e.kind == TranslateEventKind.batchDone);
      expect(done.pairs.length, lessThanOrEqualTo(3));
      expect(done.pairs.first, ['line 30', '译0'],
          reason: '尾批（5 条）预览取前 3，首对为原文→译文');
    });

    test('重试事件：首批失败一次后成功，retry 事件插入 start 与 done 之间', () async {
      final events = <TranslateEvent>[];
      var calls = 0;
      await TranslationService.instance.translateDocument(
        doc(10),
        config: config,
        target: zh,
        onEvent: events.add,
        chatOverride: ({required system, required user}) async {
          calls++;
          if (calls == 1) throw const HttpException('HTTP 503');
          return jsonEncode([for (var i = 0; i < 10; i++) '译$i']);
        },
      );
      final kinds = [for (final e in events) e.kind];
      expect(kinds, contains(TranslateEventKind.retry));
      final retry = events.firstWhere((e) => e.kind == TranslateEventKind.retry);
      expect(retry.text, contains('503'));
      // 顺序：start → retry → done
      final iStart =
          kinds.indexOf(TranslateEventKind.batchStart);
      final iRetry = kinds.indexOf(TranslateEventKind.retry);
      final iDone = kinds.indexOf(TranslateEventKind.batchDone);
      expect(iStart < iRetry, isTrue);
      expect(iRetry < iDone, isTrue);
    });
  });

  group('polishDocument onEvent 事件序列', () {
    test('润色批次事件 tag=润色，start/done 交替', () async {
      final events = <TranslateEvent>[];
      await TranslationService.instance.polishDocument(
        doc(65),
        config: config,
        target: zh,
        onEvent: events.add,
        chatOverride: ({required system, required user}) async {
          final n = (jsonDecode(user) as Map)['lines'] as List;
          return jsonEncode([for (var i = 0; i < n.length; i++) '润$i']);
        },
      );
      expect(events.length, 6, reason: '65 cue = 3 批 × start/done');
      expect(events.every((e) => e.tag == '润色'), isTrue);
      expect(events.first.kind, TranslateEventKind.batchStart);
      expect(events.first.batchTotal, 3);
      expect(events[1].kind, TranslateEventKind.batchDone);
      expect(events[1].pairs.first[0], 'line 0');
      expect(events[1].pairs.first[1], '润0');
    });
  });
}
