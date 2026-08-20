import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart'
    show polishSystemPrompt, TranslateLanguage;

/// v1.3 自定义润色指令：用户可在设置页编辑润色 system prompt 附加段
/// （如「保留口语语气词」），拼接到内置润色规则之后。
void main() {
  final zh = TranslateLanguage.presets.first;

  test('附加段拼接到内置规则之后', () {
    final p = polishSystemPrompt(zh, customRules: '保留口语语气词与称呼');
    expect(p, contains('保留口语语气词与称呼'));
    expect(p.endsWith('保留口语语气词与称呼。'), isTrue,
        reason: '附加段应在末尾，保持内置规则前缀不变');
    expect(p.indexOf('proofreader'), lessThan(p.indexOf('保留口语')));
  });

  test('无附加段时 prompt 与 v1.2 基线一致', () {
    expect(polishSystemPrompt(zh, customRules: ''),
        polishSystemPrompt(zh));
    expect(polishSystemPrompt(zh), isNot(contains('Custom')));
  });

  test('附加段多行文本原样保留', () {
    final p = polishSystemPrompt(zh, customRules: '第一行\n第二行');
    expect(p, contains('第一行\n第二行'));
  });
}
