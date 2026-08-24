import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

/// v2.2.1 JSON 输出模式：
/// - 请求体加 `response_format: json_object`（减少非 JSON 输出→重试计费）
/// - 输出契约改为 JSON 对象 `{"lines":[...]}`（json_object 模式下多数
///   服务商强制输出对象，纯数组会被拒绝）
/// - 解析兼容旧纯数组输出（老版本 checkpoint / 不支持该参数的服务商）
void main() {
  group('chatRequestBody', () {
    test('包含 response_format json_object、stream 与 model', () {
      final body = TranslationService.chatRequestBody(
        model: 'deepseek-chat',
        system: 'sys',
        user: 'usr',
      );
      expect(body['model'], 'deepseek-chat');
      expect(body['stream'], true);
      expect(body['response_format'], {'type': 'json_object'},
          reason: 'json_object 模式强制模型输出合法 JSON，降低重试率');
      expect(body['messages'], [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': 'usr'},
      ]);
    });
  });

  group('parseModelOutput', () {
    test('解析 {"lines":[...]} 对象输出', () {
      final r = TranslationService.parseModelOutput(
          '{"lines":["甲","乙","丙"]}', 3);
      expect(r, ['甲', '乙', '丙']);
    });

    test('兼容旧纯数组输出', () {
      final r = TranslationService.parseModelOutput('["a","b"]', 2);
      expect(r, ['a', 'b']);
    });

    test('兼容 ```json 围栏包裹的对象', () {
      final r = TranslationService.parseModelOutput(
          '```json\n{"lines":["x","y"]}\n```', 2);
      expect(r, ['x', 'y']);
    });

    test('对象前后混有解释文字时提取载荷', () {
      final r = TranslationService.parseModelOutput(
          '好的，以下是翻译：{"lines":["x","y"]}', 2);
      expect(r, ['x', 'y']);
    });

    test('长度不符：截断/补齐空串（缺失项回退原文由调用方处理）', () {
      final r = TranslationService.parseModelOutput('{"lines":["a"]}', 3);
      expect(r, ['a', '', '']);
    });

    test('lines 非数组 / 非 JSON / 既无对象又无数组：抛 FormatException', () {
      expect(() => TranslationService.parseModelOutput('{"lines":"no"}', 1),
          throwsFormatException);
      expect(() => TranslationService.parseModelOutput('not json', 1),
          throwsFormatException);
      expect(() => TranslationService.parseModelOutput('{"other":1}', 1),
          throwsFormatException);
    });
  });

  group('prompt 契约（JSON 对象输出）', () {
    test('translateSystemPrompt 要求输出含 "lines" 的 JSON 对象', () {
      final p = translateSystemPrompt(TranslateLanguage.presets.first);
      expect(p, contains('JSON object'));
      expect(p, contains('"lines"'),
          reason: 'json_object 模式要求输出对象，契约必须显式给出结构');
      expect(p, contains('ONLY'));
    });

    test('polishSystemPrompt 同步 JSON 对象契约', () {
      final p = polishSystemPrompt(TranslateLanguage.presets.first);
      expect(p, contains('JSON object'));
      expect(p, contains('"lines"'));
    });
  });
}
