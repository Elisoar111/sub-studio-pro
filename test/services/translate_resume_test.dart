import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// 批间上下文 + 断点续传（v1.2）：
/// 用 chatOverride 注入缝捕获每批请求，不发真实 HTTP。
/// 65 cue = 3 批（30+30+5）。
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

  group('批间上下文携带', () {
    test('首批无 context；后续批携带前批尾部 3 条（原文+已译文）', () async {
      final payloads = <Map<String, dynamic>>[];
      final result = await TranslationService.instance.translateDocument(
        doc(65),
        config: config,
        target: zh,
        chatOverride: ({required system, required user}) async {
          payloads.add(jsonDecode(user) as Map<String, dynamic>);
          final n = (payloads.last['lines'] as List).length;
          return jsonEncode([for (var i = 0; i < n; i++) '译$i']);
        },
      );
      expect(result.cues.length, 65);

      expect(payloads.length, 3, reason: '65 cue = 3 批');
      expect(payloads[0].containsKey('context'), isFalse,
          reason: '首批无上下文');
      expect((payloads[0]['lines'] as List).length, 30);

      // 第二批 context = 第一批尾部 3 条
      final ctx2 = payloads[1]['context'] as List;
      expect(ctx2.length, 3);
      expect((ctx2[0] as List)[0], 'line 27');
      expect((ctx2[0] as List)[1], '译27');
      expect((ctx2[2] as List)[0], 'line 29');

      // 第三批（尾批仅 5 条）context = 第二批尾部 3 条
      final ctx3 = payloads[2]['context'] as List;
      expect(ctx3.length, 3);
      expect((ctx3[2] as List)[0], 'line 59');
    });

    test('单批文档不携带 context', () async {
      final payloads = <Map<String, dynamic>>[];
      await TranslationService.instance.translateDocument(
        doc(10),
        config: config,
        target: zh,
        chatOverride: ({required system, required user}) async {
          payloads.add(jsonDecode(user) as Map<String, dynamic>);
          return jsonEncode([for (var i = 0; i < 10; i++) '译']);
        },
      );
      expect(payloads.single.containsKey('context'), isFalse);
    });
  });

  group('断点续传（checkpoint）', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('v12_ckpt');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('失败批次重跑不重译已成功批次；成功后删除 checkpoint', () async {
      final output = '${tmp.path}${Platform.pathSeparator}demo_zh.srt';
      final ckptPath = TranslateCheckpoint.pathFor(output);
      var calls = 0;

      // 第一轮：批 1 成功，批 2 失败（重试 2 次后抛错）
      await expectLater(
        TranslationService.instance.translateDocument(
          doc(65),
          config: config,
          target: zh,
          checkpointPath: ckptPath,
          checkpointMtimeMs: 123,
          chatOverride: ({required system, required user}) async {
            calls++;
            if (calls > 1) throw const HttpException('boom');
            final n = (jsonDecode(user) as Map)['lines'] as List;
            return jsonEncode([for (var i = 0; i < n.length; i++) 'A$i']);
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(File(ckptPath).existsSync(), isTrue,
          reason: '失败后 checkpoint 保留供恢复');
      final saved = TranslateCheckpoint.load(ckptPath)!;
      expect(saved.batches.length, 1, reason: '只有批 1 完成');
      expect(saved.cueCount, 65);
      expect(saved.lang, 'zh');
      expect(saved.inputMtimeMs, 123);

      // 第二轮：全部成功 → 只补批 2、批 3（2 次请求）
      final calls2 = <int>[];
      final result = await TranslationService.instance.translateDocument(
        doc(65),
        config: config,
        target: zh,
        checkpointPath: ckptPath,
        checkpointMtimeMs: 123,
        chatOverride: ({required system, required user}) async {
          calls2.add(1);
          final n = (jsonDecode(user) as Map)['lines'] as List;
          return jsonEncode([for (var i = 0; i < n.length; i++) 'B$i']);
        },
      );
      expect(calls2.length, 2, reason: '批 1 已在 checkpoint，不得重译');
      expect(result.cues.length, 65);
      expect(result.cues.first.rawText, 'A0', reason: '批 1 译文来自 checkpoint');
      expect(result.cues[30].rawText, 'B0', reason: '批 2 重新翻译');
      expect(File(ckptPath).existsSync(), isFalse,
          reason: '全部成功后 checkpoint 删除');
    });

    test('取消保留 checkpoint（批间检查点）', () async {
      final output = '${tmp.path}${Platform.pathSeparator}cancel_zh.srt';
      final ckptPath = TranslateCheckpoint.pathFor(output);
      var cancel = false;
      await expectLater(
        TranslationService.instance.translateDocument(
          doc(65),
          config: config,
          target: zh,
          checkpointPath: ckptPath,
          checkpointMtimeMs: 1,
          shouldCancel: () => cancel,
          chatOverride: ({required system, required user}) async {
            final n = (jsonDecode(user) as Map)['lines'] as List;
            final r = jsonEncode([for (var i = 0; i < n.length; i++) 'C$i']);
            cancel = true; // 批 1 完成后触发取消
            return r;
          },
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
      expect(File(ckptPath).existsSync(), isTrue,
          reason: '取消后 checkpoint 保留');
      expect(TranslateCheckpoint.load(ckptPath)!.batches.length, 1);
    });

    test('mtime 不符丢弃 checkpoint 全部重译', () async {
      final output = '${tmp.path}${Platform.pathSeparator}stale_zh.srt';
      final ckptPath = TranslateCheckpoint.pathFor(output);
      TranslateCheckpoint(
        cueCount: 65,
        inputMtimeMs: 111,
        lang: 'zh',
        batches: [
          [for (var i = 0; i < 30; i++) 'OLD$i'],
        ],
      ).save(ckptPath);

      var calls = 0;
      await TranslationService.instance.translateDocument(
        doc(65),
        config: config,
        target: zh,
        checkpointPath: ckptPath,
        checkpointMtimeMs: 999, // mtime 不匹配
        chatOverride: ({required system, required user}) async {
          calls++;
          final n = (jsonDecode(user) as Map)['lines'] as List;
          return jsonEncode([for (var i = 0; i < n.length; i++) 'N$i']);
        },
      );
      expect(calls, 3, reason: 'checkpoint 失效 → 3 批全部重新翻译');
    });
  });

  group('译文润色模式（v1.2）', () {
    test('polishSystemPrompt 锁定不改语义/保留标签/等长输出规则', () {
      final p = polishSystemPrompt(zh);
      expect(p, contains('proofreader'));
      expect(p, contains('punctuation'));
      expect(p, contains('do NOT change the meaning'));
      expect(p, contains(r'{\i1}'));
      expect(p.toLowerCase(), contains('backslash-n'));
      expect(p, contains('same length'));
      expect(p, contains('ONLY a JSON object'),
          reason: 'v2.2.1 契约改为 {"lines":[...]}（json_object 模式）');
      expect(p, contains(zh.prompt), reason: '润色目标语言与翻译一致');
    });

    test('polishDocument 二阶段调用：每批译文送润色，产物取润色结果', () async {
      final systems = <String>[];
      var offset = 0;
      final polished = await TranslationService.instance.polishDocument(
        doc(35),
        config: config,
        target: zh,
        chatOverride: ({required system, required user}) async {
          systems.add(system);
          final n = (jsonDecode(user) as Map)['lines'] as List;
          final r = jsonEncode(
              [for (var i = 0; i < n.length; i++) '润${offset + i}']);
          offset += n.length;
          return r;
        },
      );
      expect(systems.length, 2, reason: '35 cue = 2 批润色');
      expect(systems.every((s) => s.contains('proofreader')), isTrue,
          reason: '润色阶段必须用润色 system prompt');
      expect(polished.cues.first.rawText, '润0');
      expect(polished.cues[30].rawText, '润30', reason: '时间轴索引不变');
      expect(polished.cues[30].start, doc(35).cues[30].start);
    });

    test('润色取消抛 TranslationCancelledException', () async {
      var cancel = false;
      await expectLater(
        TranslationService.instance.polishDocument(
          doc(65),
          config: config,
          target: zh,
          shouldCancel: () => cancel,
          chatOverride: ({required system, required user}) async {
            final n = (jsonDecode(user) as Map)['lines'] as List;
            final r = jsonEncode([for (var i = 0; i < n.length; i++) 'P$i']);
            cancel = true;
            return r;
          },
        ),
        throwsA(isA<TranslationCancelledException>()),
      );
    });
  });
}
