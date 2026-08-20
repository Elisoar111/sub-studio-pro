import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/subtitle/big5/big5.dart';
import 'package:subtitle_studio_pro/services/subtitle/encoding_detector.dart';

void main() {
  group('编码检测', () {
    test('BIG5 繁体字幕应判定为 big5 而不是 gbk', () {
      const text = '這是繁體中文字幕測試檔案，請欣賞。今天的天氣很好。';
      final bytes = Uint8List.fromList(Big5Codec.encode(text));
      final r = EncodingDetector.decode(bytes);
      expect(r.encodingName, 'big5',
          reason: 'GBK 解码 BIG5 字节虽然不抛异常但产出大量错字，'
              '需要内容启发式区分');
      expect(r.text, text);
    });

    test('GBK 简体字幕应判定为 gbk', () {
      const text = '这是简体中文字幕测试文件，请欣赏。今天的天气很好。';
      final bytes = Uint8List.fromList(gbk.encode(text));
      final r = EncodingDetector.decode(bytes);
      expect(r.encodingName, 'gbk');
      expect(r.text, text);
    });

    test('UTF-8 文本判定为 utf-8', () {
      const text = '普通 UTF-8 字幕文本';
      final bytes = Uint8List.fromList(utf8.encode(text));
      final r = EncodingDetector.decode(bytes);
      expect(r.encodingName, 'utf-8');
      expect(r.text, text);
    });
  });

  group('编码检测边界（v1.1 P2 补齐）', () {
    test('简繁混排（GBK 编码）判 gbk 且文本无损', () {
      // 字幕组常把繁体专名混进简体字幕，GBK 能编但 BIG5 解会错字
      const text = '这是简体字幕，但是里面有繁体专名：精英字幕組、動漫之家。'
          '今天的劇集很好看，我們一起看吧。';
      final bytes = Uint8List.fromList(gbk.encode(text));
      final r = EncodingDetector.decode(bytes);
      expect(r.encodingName, 'gbk');
      expect(r.text, text);
    });

    test('纯 ASCII 字节判定为 utf-8（严格校验即通过）', () {
      const text = '1\n00:00:01,000 --> 00:00:02,000\nHello world\n';
      final bytes = Uint8List.fromList(ascii.encode(text));
      final r = EncodingDetector.decode(bytes);
      // 纯 ASCII 是合法 UTF-8，第 2 步严格校验直接命中，无需走 GBK 兜底
      expect(r.encodingName, 'utf-8');
      expect(r.text, text);
    });

    test('带 UTF-8 BOM 的文件剥离 BOM 并判 utf-8', () {
      const text = '带BOM的字幕';
      final body = utf8.encode(text);
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...body]);
      final r = EncodingDetector.decode(bytes);
      expect(r.encodingName, 'utf-8');
      expect(r.text, text, reason: 'BOM 必须剥离，不能出现在解码结果里');
    });

    test('空字节序列不抛异常', () {
      final r = EncodingDetector.decode(Uint8List(0));
      expect(r.encodingName, isNotEmpty);
    });

    test('GBK 双字节序列含 BIG5 未定义区时仍稳定判定', () {
      // GBK 用户区扩展（如 emoji 位置的生僻字节），BIG5 解出 U+FFFD 被否决
      const text = '字幕测试，包含特殊符号①②③和生僻字';
      final bytes = Uint8List.fromList(gbk.encode(text));
      final r = EncodingDetector.decode(bytes);
      expect(r.text, text);
    });

    test('forcedEncoding 手动指定优先于自动检测', () {
      const text = '这是简体';
      final utf8Bytes = Uint8List.fromList(utf8.encode(text));
      final r = EncodingDetector.decode(utf8Bytes, forcedEncoding: 'GBK');
      // 强制按 GBK 解 UTF-8 字节是用户显式选择，检测结果标注 gbk
      expect(r.encodingName, 'gbk');
    });
  });
}
