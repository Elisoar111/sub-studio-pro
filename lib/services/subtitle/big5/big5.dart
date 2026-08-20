/// 内置 BIG5 编解码器。
///
/// Vendor 自 flutter_big5 0.0.6（github.com/bakboem/big5，BSD 3-Clause，
/// 表数据源自 gist.github.com/shiedman/5477198）。该 pub 包已停止维护
/// （v1.2.x 移除依赖，直接内置源码）；decode 对无效序列静默产出
/// U+FFFD（永不抛异常），[EncodingDetector] 的 GBK/BIG5 双向判别依赖此行为。
library big5;

part 'table.dart';

// only non-stream version
class Big5Codec {
  static int compare(String a, String b) {
    final aBytes = encode(a);
    final bBytes = encode(b);
    if (_listEquals(aBytes, bBytes)) {
      return 0;
    }
    final aLen = aBytes.length;
    final bLen = bBytes.length;
    if (aLen == bLen) {
      for (int index = 0; index < aLen; index++) {
        final aVal = aBytes[index];
        final bVal = bBytes[index];
        if (aVal == bVal) continue;
        return aVal.compareTo(bVal);
      }
    }
    return aLen.compareTo(bLen);
  }

  static String decode(List<int> src) {
    return _big5TransformDecode(src);
  }

  static List<int> encode(String src) {
    return _big5TransformEncode(src);
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    if (identical(a, b)) return true;
    for (int index = 0; index < a.length; index += 1) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static String _big5TransformDecode(List<int> src) {
    var r = 0;
    var size = 0;
    var nDst = '';

    void write(input) => nDst += (String.fromCharCode(input));

    for (var nSrc = 0; nSrc < src.length; nSrc += size) {
      var c0 = src[nSrc];
      if (c0 < 0x80) {
        r = c0;
        size = 1;
      } else if (0x81 <= c0 && c0 < 0xFF) {
        if (nSrc + 1 >= src.length) {
          r = runeError;
          size = 1;
          write(r);
          continue;
        }
        var c1 = src[nSrc + 1];
        r = 0xfffd;
        size = 2;

        var i = c0 * 16 * 16 + c1;
        var s = _decodeMap[i];
        if (s != null) {
          write(s);
          continue;
        }
      } else {
        r = runeError;
        size = 1;
      }
      write(r);
      continue;
    }
    return nDst;
  }

  static List<int> _big5TransformEncode(String src) {
    var runes = Runes(src).toList();

    var r = 0;
    var size = 0;
    List<int> dst = [];

    void write2(int r) {
      dst.add(r >> 8);
      dst.add(r % 256);
    }

    for (var nSrc = 0; nSrc < runes.length; nSrc += size) {
      r = runes[nSrc];

      // Decode a 1-byte rune.
      if (r < runeSelf) {
        size = 1;
        dst.add(r);
        continue;
      } else {
        // Decode a multi-byte rune.
        // TODO handle some error
        size = 1;
      }

      if (r >= runeSelf) {
        if (encode0Low <= r && r < encode0High) {
          r = _encode0[r - encode0Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        } else if (encode1Low <= r && r < encode1High) {
          r = _encode1[r - encode1Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        } else if (encode2Low <= r && r < encode2High) {
          r = _encode2[r - encode2Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        } else if (encode3Low <= r && r < encode3High) {
          r = _encode3[r - encode3Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        } else if (encode4Low <= r && r < encode4High) {
          r = _encode4[r - encode4Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        } else if (encode5Low <= r && r < encode5High) {
          r = _encode5[r - encode5Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        } else if (encode6Low <= r && r < encode6High) {
          r = _encode6[r - encode6Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        } else if (encode7Low <= r && r < encode7High) {
          r = _encode7[r - encode7Low]!;
          if (r != 0) {
            write2(r);
            continue;
          }
        }
        break;
      }
    }
    return dst;
  }
}
