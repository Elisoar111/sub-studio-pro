import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// v2.2.1 失败批次拆分重试：
/// 长批次（>8 条）解析失败（模型输出非 JSON / 截断）时自动切半重试
/// （30→15→8），长批次解析失败的主要救星；
/// ≤8 条的小批与 HTTP 类错误不拆分（重试耗尽即失败，避免调用爆炸）。
void main() {
  const config =
      AiApiConfig(baseUrl: 'https://api.test', apiKey: 'k', model: 'm');
  final zh = TranslateLanguage.presets.first;

  SubtitleDocument doc(int n, {String prefix = 'line'}) => SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [
          for (var i = 0; i < n; i++)
            SubtitleCue(
              index: i,
              start: Duration(milliseconds: i * 1000),
              end: Duration(milliseconds: i * 1000 + 900),
              rawText: '$prefix $i',
            ),
        ],
      );

  setUp(() {
    TranslationService.retryDelayOverride = (_) => Duration.zero;
  });
  tearDown(() {
    TranslationService.retryDelayOverride = null;
  });

  group('失败批次拆分重试', () {
    test('整批（10 条）解析失败 → 切半 5+5 重试成功，译文顺序正确', () async {
      final events = <TranslateEvent>[];
      var badCount = 0;
      final out = await TranslationService.instance.translateDocument(
        doc(10),
        config: config,
        target: zh,
        onEvent: events.add,
        chatOverride: ({required system, required user}) async {
          final lines = parseUserLines(user);
          if (lines.length == 10) {
            badCount++;
            return 'oops 不是 JSON'; // 解析失败
          }
          return jsonEncode({
            'lines': [
              for (final l in lines) '译${l.split(' ').last}',
            ],
          });
        },
      );
      expect(badCount, 3, reason: '整批重试 3 次（1+2）均解析失败后才拆分');
      expect(out.cues.length, 10);
      for (var i = 0; i < 10; i++) {
        expect(out.cues[i].rawText, '译$i', reason: '拆分结果按原顺序回填');
      }
      final splits = events
          .where((e) => e.kind == TranslateEventKind.retry)
          .where((e) => e.text.contains('拆分'))
          .toList();
      expect(splits, isNotEmpty, reason: '拆分动作通过 retry 事件直播提示');
      expect(splits.first.text, contains('5'),
          reason: '提示拆分后每半批条数');
    });

    test('半批（≤8 条）仍解析失败 → 不再拆分，任务失败', () async {
      var calls = 0;
      await expectLater(
        TranslationService.instance.translateDocument(
          doc(10),
          config: config,
          target: zh,
          chatOverride: ({required system, required user}) async {
            calls++;
            return '坏输出'; // 所有批次（10 / 5+5）都解析失败
          },
        ),
        throwsStateError,
      );
      // 整批 3 次 + 左半批 3 次 = 6 次；左半批 ≤8 不再拆且失败即快速失败
      // （右半批不再调用，避免无谓计费）
      expect(calls, 6);
    });

    test('HTTP 类错误不触发拆分：重试耗尽直接失败', () async {
      final events = <TranslateEvent>[];
      var calls = 0;
      await expectLater(
        TranslationService.instance.translateDocument(
          doc(10),
          config: config,
          target: zh,
          onEvent: events.add,
          chatOverride: ({required system, required user}) async {
            calls++;
            throw const HttpException('HTTP 401: Unauthorized');
          },
        ),
        throwsStateError,
      );
      expect(calls, 3, reason: '仅整批 3 次尝试，无拆分调用');
      expect(events.where((e) => e.text.contains('拆分')), isEmpty,
          reason: 'HTTP 错误（网络/鉴权）拆分无意义');
    });
  });
}

/// 从 user payload JSON 取 lines 列表。
List<String> parseUserLines(String user) {
  final m = jsonDecode(user) as Map<String, dynamic>;
  return [for (final e in m['lines'] as List) '$e'];
}
