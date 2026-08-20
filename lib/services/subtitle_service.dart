import 'dart:typed_data';

import '../models/subtitle.dart';
import 'subtitle/encoding_detector.dart';
import 'subtitle/subtitle_converter.dart';
import 'subtitle/subtitle_parser.dart';

/// 字幕服务：解析、编码检测、格式转换的统一门面。
///
/// 底层实现分散在 `services/subtitle/`：
/// - [SubtitleParser]：SRT / ASS / SSA / VTT / MicroDVD 解析（Isolate 中执行）
/// - [SubtitleConverter]：纯 Dart 格式转换（内存高效，支持批量、编码）
/// - [SubtitleWriter]：序列化
/// - [EncodingDetector]：编码检测（UTF-8 / GBK / BIG5 / UTF-16）
/// 本类提供高层入口，供 UI / 队列调用。
class SubtitleService {
  SubtitleService._();

  static final SubtitleService instance = SubtitleService._();

  /// 解析字幕文件（自动检测编码，Isolate 中执行，不阻塞 UI）。
  Future<SubtitleDocument> parseFile(String path, {String? forcedEncoding}) =>
      SubtitleParser.parseFile(path, forcedEncoding: forcedEncoding);

  /// 从内存字节解析（含编码检测）。
  SubtitleDocument parseBytes(Uint8List bytes, {String? ext}) =>
      SubtitleParser.parseBytes(bytes, ext: ext);

  /// 检测字节编码，返回解码文本与编码名。
  DecodedText detectEncoding(Uint8List bytes, {String? forcedEncoding}) =>
      EncodingDetector.decode(bytes, forcedEncoding: forcedEncoding);

  /// 单个文件转换（Isolate 中执行）。
  Future<SubtitleConversionResult> convertFile({
    required String inputPath,
    required String outputPath,
    required SubtitleConvertOptions options,
  }) =>
      SubtitleConverter.convertFile(
        inputPath: inputPath,
        outputPath: outputPath,
        options: options,
      );

  /// 内存中转换：解析好的文档 → 目标格式字节。
  Uint8List convertToBytes(
    SubtitleDocument doc, {
    required SubtitleConvertOptions options,
  }) =>
      SubtitleConverter.convertToBytes(doc, options: options);
}
