import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// v2.2.1 超时 / 重试参数可调（服务层）：
/// translateDocument / polishDocument 接受 `retries`（默认 2）与
/// `timeout`（默认 120s），不再写死常量——设置页暴露后由 runner 传入。
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

  setUp(() {
    TranslationService.retryDelayOverride = (_) => Duration.zero;
  });
  tearDown(() {
    TranslationService.retryDelayOverride = null;
  });

  group('retries 参数', () {
    test('retries=0：失败仅尝试 1 次即抛', () async {
      var calls = 0;
      await expectLater(
        TranslationService.instance.translateDocument(
          doc(5),
          config: config,
          target: zh,
          retries: 0,
          chatOverride: ({required system, required user}) async {
            calls++;
            throw const HttpException('HTTP 500');
          },
        ),
        throwsStateError,
      );
      expect(calls, 1);
    });

    test('retries=4：共尝试 5 次', () async {
      var calls = 0;
      await expectLater(
        TranslationService.instance.translateDocument(
          doc(5),
          config: config,
          target: zh,
          retries: 4,
          chatOverride: ({required system, required user}) async {
            calls++;
            throw const HttpException('HTTP 500');
          },
        ),
        throwsStateError,
      );
      expect(calls, 5);
    });

    test('retries 可调且成功路径不受影响（含 timeout 透传）', () async {
      final out = await TranslationService.instance.translateDocument(
        doc(5),
        config: config,
        target: zh,
        retries: 4,
        timeout: const Duration(seconds: 60),
        chatOverride: ({required system, required user}) async {
          final lines = (jsonDecode(user) as Map)['lines'] as List;
          return jsonEncode({
            'lines': [for (var i = 0; i < lines.length; i++) '译$i'],
          });
        },
      );
      expect(out.cues.length, 5);
      expect(out.cues.first.rawText, '译0');
    });
  });

  group('polishDocument retries 参数', () {
    test('retries=0：失败仅尝试 1 次', () async {
      var calls = 0;
      await expectLater(
        TranslationService.instance.polishDocument(
          doc(5),
          config: config,
          target: zh,
          retries: 0,
          chatOverride: ({required system, required user}) async {
            calls++;
            throw const HttpException('HTTP 500');
          },
        ),
        throwsStateError,
      );
      expect(calls, 1);
    });
  });
}
