import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';

import 'big5/big5.dart';

/// 解码结果：文本 + 判定编码名。
class DecodedText {
  final String text;
  final String encodingName;

  const DecodedText(this.text, this.encodingName);
}

/// 字幕文件编码检测与解码。
///
/// 字幕组最常见的坑：网盘/旧压制组字幕大量使用 GBK / BIG5 编码，
/// 直接按 UTF-8 读取会乱码。检测策略：
/// 1. BOM 优先（UTF-8 / UTF-16 LE / BE）；
/// 2. 严格 UTF-8 校验；
/// 3. GBK / BIG5 双向解码：
///    - BIG5 常用字区几乎全部落入 GBK 已填充区，GBK 解码 BIG5 字节
///      不报错但产出大量错字 —— 仅靠"解码成功与否"无法区分；
///    - 因此两套都试，比较解码文本的 CJK 常用字命中率（错字几乎
///      不会命中常用字），BIG5 需显著更高才判定为 BIG5；
///    - flutter_big5 的 decode 对无效序列静默写 U+FFFD（永不抛异常），
///      含替换符即否决 BIG5 候选；
/// 4. 兜底 Latin-1（永不失败，至少不崩溃）。
class EncodingDetector {
  EncodingDetector._();

  /// 解码字节；[forcedEncoding] 非空时跳过检测直接使用（用户手动指定）。
  static DecodedText decode(Uint8List bytes, {String? forcedEncoding}) {
    if (forcedEncoding != null && forcedEncoding.isNotEmpty) {
      final lower = forcedEncoding.toLowerCase();
      final name = _normalizeName(lower);
      return DecodedText(_decodeWith(bytes, lower) ?? '', name);
    }

    // 1) BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return DecodedText(
        utf8.decode(bytes.sublist(3), allowMalformed: true),
        'utf-8',
      );
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return DecodedText(_decodeUtf16(bytes.sublist(2), littleEndian: true), 'utf-16le');
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return DecodedText(_decodeUtf16(bytes.sublist(2), littleEndian: false), 'utf-16be');
    }

    // 2) UTF-8 严格校验
    try {
      final text = utf8.decode(bytes, allowMalformed: false);
      if (_looksLikeText(text)) return DecodedText(text, 'utf-8');
    } catch (_) {/* 继续尝试 GBK */}

    // 3) GBK / BIG5：双向解码 + CJK 常用字命中率判别
    String? gbkText;
    try {
      final t = gbk.decode(bytes);
      if (_looksLikeText(t)) gbkText = t;
    } catch (_) {}
    String? big5Text;
    try {
      final t = Big5Codec.decode(bytes);
      // Big5Codec.decode 永不抛异常；产出 U+FFFD 说明字节不是合法 BIG5
      if (!t.contains('\uFFFD') && _looksLikeText(t)) big5Text = t;
    } catch (_) {}

    if (gbkText != null && big5Text != null) {
      final g = _cjkHitRate(gbkText);
      final b = _cjkHitRate(big5Text);
      // BIG5 需显著更高才判 BIG5；打不出分（无 CJK，如纯 ASCII）默认 GBK
      if (b != null && g != null && b > g + 0.15) {
        return DecodedText(big5Text, 'big5');
      }
      return DecodedText(gbkText, 'gbk');
    }
    if (big5Text != null) return DecodedText(big5Text, 'big5');
    if (gbkText != null) return DecodedText(gbkText, 'gbk');

    // 4) Latin-1 兜底
    return DecodedText(latin1.decode(bytes), 'latin-1');
  }

  /// 高频汉字表（简繁并收）：正确解码的简/繁文本命中率高；
  /// 错误解码（如 GBK 读 BIG5 字节）产出的是随机生僻字，命中率极低。
  static const String _commonHan =
      '的一是不了人我在有他这中大来上国个到说们为子和你地出道也'
      '時年得就那要下以生会自着去之过家学对可她里后小么心多天而'
      '能好都然没日於起还发成事只作当想看文无开手十用主行方又'
      '這個們為來國說學對後麼著過會裏沒還發開無當時間話樣種能'
      '電影集字幕繁體簡體中文請謝謝我們你們什麼怎麼因為所以但是'
      '知道現在可以沒有這樣那樣自己大家先生小姐真的不是就是還是';

  /// CJK 字符中常用字的命中率；无 CJK 或样本太少返回 null。
  static double? _cjkHitRate(String text, {int minCjk = 10}) {
    var cjk = 0;
    var hit = 0;
    for (final cu in text.codeUnits) {
      if (cu < 0x4E00 || cu > 0x9FFF) continue;
      cjk++;
      if (_commonHan.contains(String.fromCharCode(cu))) hit++;
    }
    if (cjk < minCjk) return null;
    return hit / cjk;
  }

  /// 规范化编码名（'utf8'→'utf-8' 等），供写出时选择编码器。
  static String _normalizeName(String lower) {
    switch (lower) {
      case 'utf8':
      case 'utf-8':
      case 'unicode':
        return 'utf-8';
      case 'utf16':
      case 'utf-16':
      case 'utf16le':
      case 'utf-16le':
        return 'utf-16le';
      case 'big5':
      case 'big-5':
        return 'big5';
      case 'gbk':
      case 'gb2312':
      case 'gb18030':
        return 'gbk';
      default:
        return 'utf-8';
    }
  }

  static String? _decodeWith(Uint8List bytes, String lower) {
    final name = _normalizeName(lower);
    switch (name) {
      case 'utf-8':
        return utf8.decode(bytes, allowMalformed: true);
      case 'utf-16le':
        final len = bytes.length - (bytes.length.isEven ? 0 : 1);
        return _decodeUtf16(bytes.sublist(0, len), littleEndian: true);
      case 'big5':
        try {
          return Big5Codec.decode(bytes);
        } catch (_) {
          return latin1.decode(bytes);
        }
      case 'gbk':
        // 强制 GBK 读到非 GBK 字节会抛 FormatException，
        // 降级 Latin-1 保证不崩（宁可乱码不可崩溃）
        try {
          return gbk.decode(bytes);
        } catch (_) {
          return latin1.decode(bytes);
        }
      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// 简单启发：文本中可打印字符占比足够高才算"像文本"，
  /// 避免把二进制误判成 GBK 成功。
  static bool _looksLikeText(String text, {int sample = 400}) {
    if (text.isEmpty) return false;
    final s = text.length <= sample ? text : text.substring(0, sample);
    var ok = 0;
    for (final unit in s.codeUnits) {
      // 控制字符（除 \n \r \t）算非法
      if (unit < 32 && unit != 10 && unit != 13 && unit != 9) return false;
      ok++;
    }
    return ok > 0;
  }
}
