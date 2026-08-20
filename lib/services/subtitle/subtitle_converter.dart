import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:flutter_big5/big5.dart';

import '../../models/subtitle.dart';
import 'subtitle_parser.dart';
import 'subtitle_writer.dart';

/// 转换选项。
class SubtitleConvertOptions {
  final SubtitleFormat targetFormat;

  /// 输出编码：utf-8 / gbk / big5 / auto（沿用源编码，默认 utf-8）
  final String encoding;
  final bool includeBom;

  /// 输出 MicroDVD 时使用的帧率
  final double microDvdFps;

  const SubtitleConvertOptions({
    required this.targetFormat,
    this.encoding = 'utf-8',
    this.includeBom = false,
    this.microDvdFps = 25,
  });

  String get encodingLabel {
    switch (encoding.toLowerCase()) {
      case 'gbk':
        return 'GBK';
      case 'big5':
        return 'BIG5';
      case 'auto':
        return '自动(沿用源)';
      default:
        return 'UTF-8';
    }
  }
}

class SubtitleConversionResult {
  final String outputPath;
  final int cueCount;
  final String sourceEncoding;

  const SubtitleConversionResult({
    required this.outputPath,
    required this.cueCount,
    required this.sourceEncoding,
  });
}

/// 字幕格式转换器（纯 Dart，内存中高效转换，支持批处理）。
///
/// 转换流程：读取字节 → 编码检测/解码 → 解析 → 文本适配（样式标签映射）
/// → 序列化 → 编码写出。全程不依赖 FFmpeg，速度快、体积小。
class SubtitleConverter {
  SubtitleConverter._();

  /// 单个文件转换（Isolate 内执行，避免大文件卡 UI）。
  static Future<SubtitleConversionResult> convertFile({
    required String inputPath,
    required String outputPath,
    required SubtitleConvertOptions options,
  }) {
    // Isolate.run 的闭包在子 isolate 中同步执行，避免大文件阻塞 UI。
    return Isolate.run(() => _convertSync(
          inputPath: inputPath,
          outputPath: outputPath,
          options: options,
        ));
  }

  static SubtitleConversionResult _convertSync({
    required String inputPath,
    required String outputPath,
    required SubtitleConvertOptions options,
  }) {
    final bytes = File(inputPath).readAsBytesSync();
    final doc = SubtitleParser.parseBytes(bytes, ext: _extOf(inputPath));
    final outBytes = convertToBytes(doc, options: options);
    final outFile = File(outputPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsBytesSync(outBytes, flush: true);
    return SubtitleConversionResult(
      outputPath: outputPath,
      cueCount: doc.count,
      sourceEncoding: doc.sourceEncoding ?? 'utf-8',
    );
  }

  /// 内存中转换：解析好的文档 → 目标格式字节。
  static Uint8List convertToBytes(
    SubtitleDocument doc, {
    required SubtitleConvertOptions options,
  }) {
    final adapted = _adapt(doc, options.targetFormat);
    final text = SubtitleWriter.write(
      adapted,
      options.targetFormat,
      microDvdFps: options.microDvdFps,
    );
    return _encode(text, _resolveEncoding(options, doc), options.includeBom);
  }

  /// 文本适配：
  /// - 源为 ASS/SSA 时，rawText 保留 `{\...}` 覆盖标签（目标也为 ASS 时原样输出）；
  /// - 目标为 SRT/VTT/SUB 时，去除 ASS 标签（\N→换行）；
  /// - 目标为 ASS 时，把 SRT 的 <i>/<b>/<u> 映射为覆盖标签。
  static SubtitleDocument _adapt(SubtitleDocument doc, SubtitleFormat target) {
    if (doc.format == target) return doc;

    if (target.isAssFamily) {
      final fromSrt = doc.format == SubtitleFormat.srt;
      final cues = doc.cues.map((c) {
        var raw = c.rawText;
        // 先转义源文本原有的花括号（会破坏覆盖标签语法），
        // 再做 HTML → ASS 映射，否则刚生成的 {\i1} 也会被转成全角
        if (!doc.format.isAssFamily) {
          raw = raw.replaceAll('{', '｛').replaceAll('}', '｝');
        }
        if (fromSrt) {
          raw = _srtHtmlToAss(raw);
        }
        return SubtitleCue(
          index: c.index,
          start: c.start,
          end: c.end,
          rawText: raw,
        );
      }).toList();
      return SubtitleDocument(
        format: doc.format,
        cues: cues,
        title: doc.title,
        style: doc.style,
      );
    }

    // 目标为纯文本格式：去除 ASS 标签
    if (doc.format.isAssFamily) {
      final cues = doc.cues.map((c) {
        var raw = c.rawText
            .replaceAll(RegExp(r'\{[^}]*\}'), '')
            .replaceAll(r'\N', '\n')
            .replaceAll(r'\n', '\n')
            .replaceAll(r'\h', ' ')
            .trim();
        return SubtitleCue(
          index: c.index,
          start: c.start,
          end: c.end,
          rawText: raw,
        );
      }).toList();
      return SubtitleDocument(
        format: doc.format,
        cues: cues,
        title: doc.title,
      );
    }

    return doc;
  }

  /// SRT 的 HTML 标签 → ASS 覆盖标签（只处理 i/b/u，其他标签剥离）。
  static String _srtHtmlToAss(String text) {
    var s = text;
    s = s.replaceAll(RegExp(r'<i>', caseSensitive: false), r'{\i1}');
    s = s.replaceAll(RegExp(r'</i>', caseSensitive: false), r'{\i0}');
    s = s.replaceAll(RegExp(r'<b>', caseSensitive: false), r'{\b1}');
    s = s.replaceAll(RegExp(r'</b>', caseSensitive: false), r'{\b0}');
    s = s.replaceAll(RegExp(r'<u>', caseSensitive: false), r'{\u1}');
    s = s.replaceAll(RegExp(r'</u>', caseSensitive: false), r'{\u0}');
    // 剥离其余标签（如 <font color=...>）
    s = s.replaceAll(RegExp(r'<[^>]+>'), '');
    return s;
  }

  static String _resolveEncoding(SubtitleConvertOptions options, SubtitleDocument doc) {
    final enc = options.encoding.toLowerCase();
    if (enc == 'auto') {
      final src = doc.sourceEncoding?.toLowerCase() ?? '';
      if (src.startsWith('gb')) return 'gbk';
      if (src == 'big5') return 'big5';
      return 'utf-8';
    }
    return enc;
  }

  static Uint8List _encode(String text, String encoding, bool includeBom) {
    List<int> bytes;
    switch (encoding.toLowerCase()) {
      case 'gbk':
        try {
          bytes = gbk.encode(text);
        } on ArgumentError catch (e) {
          throw SubtitleException('GBK 编码失败：文本含 GBK 无法表示的字符（$e）');
        }
      case 'big5':
        try {
          bytes = Big5.encode(text);
        } on ArgumentError catch (e) {
          throw SubtitleException('BIG5 编码失败：文本含 BIG5 无法表示的字符（$e）');
        }
      default:
        bytes = utf8.encode(text);
        if (includeBom) {
          bytes = [0xEF, 0xBB, 0xBF, ...bytes];
        }
    }
    return Uint8List.fromList(bytes);
  }

  static String _extOf(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? '' : path.substring(i + 1);
  }
}
