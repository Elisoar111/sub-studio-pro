import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/subtitle/big5/big5.dart';

/// 内置 BIG5 编解码器（vendor 自 flutter_big5 0.0.6，BSD）：
/// v1.2.x 替换停维护的 pub 依赖，行为必须与原包一致。
void main() {
  group('Big5Codec decode', () {
    test('繁体常用文本 round-trip（encode → decode 无损）', () {
      const text = '這是繁體中文字幕測試，含常用字與標點。';
      final bytes = Big5Codec.encode(text);
      expect(Big5Codec.decode(bytes), text);
    });

    test('已知限制（原包行为保留）：部分字 encode 产出无效序列', () {
      // 「包」在原 flutter_big5 0.0.6 的编码表中缺失/无效，编码后解不回原字。
      // vendored 版本行为保留（项目 decode 路径不受影响；encode 仅用于
      // BIG5 写出，字表缺字为上游表数据问题，待上游更新表后修复）
      final bytes = Big5Codec.encode('包');
      expect(Big5Codec.decode(bytes), isNot('包'));
    });

    test('ASCII 直通', () {
      expect(Big5Codec.decode([0x41, 0x42, 0x43]), 'ABC');
    });

    test('「一」BIG5 编码 0xA4 0x40 可解', () {
      final out = Big5Codec.decode([0xA4, 0x40]);
      expect(out, '一');
    });

    test('无效序列静默产出 U+FFFD（与原包行为一致，检测器依赖此特性）', () {
      // 0x81 0x40 不在 BIG5 双字节合法区
      final out = Big5Codec.decode([0x81, 0x40]);
      expect(out, contains('\uFFFD'));
    });

    test('GBK 简体文本按 BIG5 解码产出错字/替换符（双向判别前提）', () {
      // GBK「一」= 0xD2 0xBB；按 BIG5 解不是「一」
      final out = Big5Codec.decode([0xD2, 0xBB]);
      expect(out, isNot('一'));
    });

    test('utf8 中文按 BIG5 解必含替换符', () {
      final utf8Bytes = Uint8List.fromList(utf8.encode('简体字'));
      expect(Big5Codec.decode(utf8Bytes), contains('\uFFFD'));
    });
  });
}
