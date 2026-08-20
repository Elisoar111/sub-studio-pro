import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../models/subtitle.dart';
import 'encoding_detector.dart';

/// 字幕解析异常（编码错误 / 格式不识别等）。
class SubtitleException implements Exception {
  final String message;
  const SubtitleException(this.message);

  @override
  String toString() => message;
}

/// 字幕解析器：SRT / ASS / SSA / VTT / MicroDVD(SUB)。
///
/// 性能：大文件（数百 KB ~ 数 MB）解析放到 Isolate 中执行，
/// 避免阻塞 UI；解析过程只在内存中逐行处理，不整体重复拷贝。
class SubtitleParser {
  SubtitleParser._();

  /// 解析字幕文件（自动检测编码，Isolate 内执行）。
  static Future<SubtitleDocument> parseFile(
    String path, {
    String? forcedEncoding,
  }) {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    return Isolate.run(() {
      final bytes = File(path).readAsBytesSync();
      return parseBytes(bytes, ext: ext, forcedEncoding: forcedEncoding);
    });
  }

  /// 从内存字节解析（供 Web / 预览使用）。
  static SubtitleDocument parseBytes(
    Uint8List bytes, {
    String? ext,
    String? forcedEncoding,
  }) {
    final decoded = EncodingDetector.decode(bytes, forcedEncoding: forcedEncoding);
    var format = SubtitleFormat.fromExtension(ext ?? '');
    if (format == SubtitleFormat.unknown) {
      format = SubtitleFormat.detectFromText(decoded.text);
    }
    if (format == SubtitleFormat.unknown) {
      throw const SubtitleException('无法识别的字幕格式');
    }
    return parseText(decoded.text, format: format)
        .copyWith(sourceEncoding: decoded.encodingName);
  }

  /// 从纯文本解析（已解码内容）。
  static SubtitleDocument parseText(String text, {required SubtitleFormat format}) {
    final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    switch (format) {
      case SubtitleFormat.srt:
        return SubtitleDocument(format: format, cues: _parseSrt(normalized));
      case SubtitleFormat.ass:
        final r = _parseAss(normalized, isSsa: false);
        return SubtitleDocument(
          format: format,
          cues: r.cues,
          title: r.title,
          style: r.style,
        );
      case SubtitleFormat.ssa:
        final r = _parseAss(normalized, isSsa: true);
        return SubtitleDocument(
          format: format,
          cues: r.cues,
          title: r.title,
          style: r.style,
        );
      case SubtitleFormat.vtt:
        return SubtitleDocument(format: format, cues: _parseVtt(normalized));
      case SubtitleFormat.sub:
        return SubtitleDocument(format: format, cues: _parseMicroDvd(normalized));
      case SubtitleFormat.unknown:
        throw const SubtitleException('未知字幕格式');
    }
  }

  // ───────────────────────── SRT ─────────────────────────

  static final RegExp _srtTime = RegExp(
    r'^\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*'
    r'(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})',
  );

  static List<SubtitleCue> _parseSrt(String text) {
    final cues = <SubtitleCue>[];
    var index = 0;
    // 单遍扫描：一次按行切分，时间行起收集到空行止。
    // 不再先按空行切块再逐块切行（万行级时省去块字符串与 sublist 分配）。
    final lines = text.split('\n');
    final buf = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      // 时间行必含 '-->'：先用廉价子串扫描预筛，非时间行不进正则引擎
      if (!lines[i].contains('-->')) continue;
      final m = _srtTime.firstMatch(lines[i]);
      if (m == null) continue;
      buf.clear();
      var wrote = false;
      var j = i + 1;
      while (j < lines.length && !_isBlank(lines[j])) {
        if (wrote) buf.write('\n');
        buf.write(lines[j]);
        wrote = true;
        j++;
      }
      cues.add(SubtitleCue(
        index: index++,
        start: _msDuration(
          int.parse(m.group(1)!),
          int.parse(m.group(2)!),
          int.parse(m.group(3)!),
          _msOfFrac(m.group(4)!),
        ),
        end: _msDuration(
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
          int.parse(m.group(7)!),
          _msOfFrac(m.group(8)!),
        ),
        rawText: buf.toString().trim(),
      ));
      i = j;
    }
    return cues;
  }

  // ─────────────────────── ASS / SSA ───────────────────────

  static final RegExp _assTime = RegExp(
    r'^\s*(\d+):(\d{1,2}):(\d{1,2})(?:[.,](\d{1,3}))?\s*$',
  );

  static final RegExp _markedPrefix = RegExp(r'^\s*Marked\s*=\s*[^,]+,?');

  static ({List<SubtitleCue> cues, String? title, SubtitleStyle? style})
      _parseAss(String text, {required bool isSsa}) {
    final cues = <SubtitleCue>[];
    String? title;
    SubtitleStyle? style;
    List<String>? eventFormat;
    // start/end/text 列索引在 Format 解析与 marked 移除时计算，
    // 避免每条 Dialogue 重复 indexOf（万行级热路径）
    var startIdx = -1;
    var endIdx = -1;
    var textIdx = -1;
    var inEvents = false;
    var index = 0;

    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('[')) {
        inEvents = trimmed == '[Events]';
        continue;
      }
      if (trimmed.startsWith('Title:')) {
        title = trimmed.substring(6).trim();
        continue;
      }
      if (trimmed.startsWith('Style:') && style == null) {
        style = SubtitleStyle.fromAssStyleLine(trimmed);
        continue;
      }
      if (!inEvents) continue;

      if (trimmed.startsWith('Format:')) {
        eventFormat = trimmed
            .substring(7)
            .split(',')
            .map((e) => e.trim().toLowerCase())
            .toList();
        startIdx = eventFormat.indexOf('start');
        endIdx = eventFormat.indexOf('end');
        textIdx = eventFormat.indexOf('text');
        continue;
      }
      if (trimmed.startsWith('Dialogue:')) {
        if (eventFormat == null) continue;
        var body = line.substring('Dialogue:'.length);
        // SSA v4 的 Marked 字段（Dialogue: Marked=0,Start,...）：
        // 剥离前缀的同时必须同步从 Format 列表中移除 marked 列，
        // 否则字段整体左移一位、长度校验失败，整行 Dialogue 被丢弃
        final marked = _markedPrefix.firstMatch(body);
        if (marked != null) {
          body = body.substring(marked.end);
          if (eventFormat.remove('marked')) {
            // marked 列移除后各列索引整体左移，必须重算
            startIdx = eventFormat.indexOf('start');
            endIdx = eventFormat.indexOf('end');
            textIdx = eventFormat.indexOf('text');
          }
        }
        if (startIdx < 0 || endIdx < 0 || textIdx < 0) continue;
        final parts = body.split(',');
        if (parts.length < eventFormat.length) continue;
        final start = _parseAssTime(parts[startIdx]);
        final end = _parseAssTime(parts[endIdx]);
        if (start == null || end == null) continue;
        // Text 是 Format 最后一列，内容可能含逗号：从 text 列起拼接全部剩余段
        final rawText = parts.skip(textIdx).join(',').trim();
        cues.add(SubtitleCue(
          index: index++,
          start: start,
          end: end,
          rawText: rawText,
        ));
      }
    }
    return (cues: cues, title: title, style: style);
  }

  /// 解析 ASS 时间 `H:MM:SS.cc`（厘秒，也可能 1~3 位小数）。
  /// 正则容忍首尾空白，避免热路径上每字段一次 trim 分配。
  /// 返回 null = 非法时间（含超出 64 位整数范围的超大数字），
  /// 调用方据此跳过该行 Dialogue 而不是让整份文件解析失败。
  static Duration? _parseAssTime(String s) {
    final m = _assTime.firstMatch(s);
    if (m == null) return null;
    final hours = int.tryParse(m.group(1)!);
    if (hours == null) return null;
    final frac = m.group(4) ?? '';
    var ms = 0;
    if (frac.isNotEmpty) {
      // 1~2 位按厘秒（×10），3 位按毫秒
      ms = frac.length >= 3
          ? int.parse(frac.substring(0, 3))
          : int.parse(frac.padRight(2, '0')) * 10;
    }
    return Duration(
      hours: hours,
      minutes: int.parse(m.group(2)!),
      seconds: int.parse(m.group(3)!),
      milliseconds: ms,
    );
  }

  // ───────────────────────── VTT ─────────────────────────

  static final RegExp _vttTime = RegExp(
    r'^\s*((?:\d{1,2}:)?\d{2}:\d{2})\.(\d{3})\s*-->\s*'
    r'((?:\d{1,2}:)?\d{2}:\d{2})\.(\d{3})',
  );

  static List<SubtitleCue> _parseVtt(String text) {
    final cues = <SubtitleCue>[];
    var index = 0;
    final blocks = text.split(RegExp(r'\n[ \t]*\n'));
    for (final block in blocks) {
      final lines = block.split('\n');
      if (lines.isEmpty) continue;
      final first = lines.first.trim();
      if (first.startsWith('WEBVTT') ||
          first.startsWith('NOTE') ||
          first.startsWith('STYLE') ||
          first.startsWith('REGION')) {
        continue;
      }
      // 找到时间行（第一行可能是 cue 标识符）
      RegExpMatch? timeMatch;
      var timeIdx = -1;
      for (var i = 0; i < lines.length; i++) {
        final m = _vttTime.firstMatch(lines[i]);
        if (m != null) {
          timeMatch = m;
          timeIdx = i;
          break;
        }
      }
      if (timeMatch == null) continue;
      final m = timeMatch;
      cues.add(SubtitleCue(
        index: index++,
        start: _vttDuration(m.group(1)!, m.group(2)!),
        end: _vttDuration(m.group(3)!, m.group(4)!),
        // 只取时间行之后的内容（时间行之前的是 cue 标识符，不是字幕）
        rawText: lines
            .skip(timeIdx + 1)
            .where((l) => l.trim().isNotEmpty)
            .join('\n')
            .trim(),
      ));
    }
    return cues;
  }

  static Duration _vttDuration(String hms, String ms) {
    final parts = hms.split(':');
    final sec = parts.removeLast();
    final min = parts.isEmpty ? 0 : int.parse(parts.removeLast());
    final hour = parts.isEmpty ? 0 : int.parse(parts.removeLast());
    return Duration(
      hours: hour,
      minutes: min,
      seconds: int.parse(sec),
      milliseconds: int.parse(ms),
    );
  }

  // ─────────────────────── MicroDVD ───────────────────────

  static final RegExp _microFrame = RegExp(r'^\{(-?\d+)\}\{(-?\d+)\}(.*)$');

  static List<SubtitleCue> _parseMicroDvd(String text, {double fps = 25}) {
    final cues = <SubtitleCue>[];
    var index = 0;
    var detectedFps = fps;
    var first = true;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (first) {
        // 首行可能是帧率头 {1}{1}25.000 或 {0}{0}23.976
        final fpsHead = RegExp(r'^\{(-?\d+)\}\{(-?\d+)\}\s*(\d+(?:\.\d+)?)\s*$')
            .firstMatch(line);
        if (fpsHead != null) {
          detectedFps = double.tryParse(fpsHead.group(3)!) ?? fps;
          first = false;
          continue;
        }
        first = false;
      }
      final m = _microFrame.firstMatch(line);
      if (m == null) continue;
      final startF = int.tryParse(m.group(1)!) ?? 0;
      final endF = int.tryParse(m.group(2)!) ?? 0;
      if (startF < 0 || endF < startF) continue;
      Duration ms(num f) =>
          Duration(milliseconds: (f / detectedFps * 1000).round());
      cues.add(SubtitleCue(
        index: index++,
        start: ms(startF),
        end: ms(endF),
        rawText: m.group(3)!.replaceAll('|', '\n').trim(),
      ));
    }
    return cues;
  }

  // ───────────────────────── 工具 ─────────────────────────

  /// 空行检查（仅空格/制表符），避免 trim() 的临时字符串分配。
  static bool _isBlank(String line) {
    for (var i = 0; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (c != 0x20 && c != 0x09) return false;
    }
    return true;
  }

  static Duration _msDuration(int h, int m, int s, int ms) =>
      Duration(hours: h, minutes: m, seconds: s, milliseconds: ms);

  /// SRT 毫秒字段直接取数值（'050'→50，'5'→5）。
  static int _msOfFrac(String frac) => int.parse(frac.padLeft(3, '0'));
}

/// 用于给解析结果附加编码信息的扩展（copyWith）。
extension SubtitleDocumentEncodingX on SubtitleDocument {
  SubtitleDocument copyWith({String? sourceEncoding}) => SubtitleDocument(
        format: format,
        cues: cues,
        sourceEncoding: sourceEncoding ?? this.sourceEncoding,
        title: title,
        style: style,
      );
}
