import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// 设置页「测试连接」（v2.2）：发送最小 chat 请求验证 AI 配置可用，
/// 用 chatOverride 注入缝替代真实 HTTP。
void main() {
  const config =
      AiApiConfig(baseUrl: 'https://api.test', apiKey: 'k', model: 'm');

  group('testConnection', () {
    test('成功：ok=true、延迟非负、reply 为模型回复', () async {
      final result = await TranslationService.instance.testConnection(
        config,
        chatOverride: ({required system, required user}) async => ' pong ',
      );
      expect(result.ok, isTrue);
      expect(result.latencyMs, greaterThanOrEqualTo(0));
      expect(result.reply, 'pong');
      expect(result.error, isEmpty);
    });

    test('失败：ok=false、error 携带异常信息', () async {
      final result = await TranslationService.instance.testConnection(
        config,
        chatOverride: ({required system, required user}) async =>
            throw const HttpException('HTTP 401: invalid key'),
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('401'));
    });

    test('配置不全：ok=false 且不发请求', () async {
      const empty = AiApiConfig(baseUrl: '', apiKey: '', model: '');
      var called = false;
      final result = await TranslationService.instance.testConnection(
        empty,
        chatOverride: ({required system, required user}) async {
          called = true;
          return 'pong';
        },
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('配置'));
      expect(called, isFalse, reason: '配置不全时不应发出请求');
    });
  });
}
