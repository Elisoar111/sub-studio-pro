import '../../models/subtitle.dart';

/// 字幕写入器：把 [SubtitleDocument] 序列化为各格式文本。
class SubtitleWriter {
  SubtitleWriter._();

  /// 按目标格式序列化为文本。
  ///
  /// [microDvdFps]：目标为 MicroDVD（sub）时使用的帧率，由转换选项传入；
  /// 缺省 25（该值直接影响帧号与时间轴的对齐）。
  static String write(
    SubtitleDocument doc,
    SubtitleFormat target, {
    double microDvdFps = 25,
  }) {
    switch (target) {
      case SubtitleFormat.srt:
        return toSrt(doc.cues);
      case SubtitleFormat.ass:
      case SubtitleFormat.ssa:
        return toAss(doc, isSsa: target == SubtitleFormat.ssa);
      case SubtitleFormat.vtt:
        return toVtt(doc.cues);
      case SubtitleFormat.sub:
        return toMicroDvd(doc.cues, fps: microDvdFps);
      case SubtitleFormat.unknown:
        return toSrt(doc.cues);
    }
  }

  // ───────────────────────── SRT ─────────────────────────

  static String toSrt(List<SubtitleCue> cues) {
    final buf = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      final c = cues[i];
      buf.writeln(i + 1);
      buf.writeln('${_srtTime(c.start)} --> ${_srtTime(c.end)}');
      buf.writeln(_normalizeNewlines(c.rawText));
      buf.writeln();
    }
    return buf.toString();
  }

  static String _srtTime(Duration d) {
    final ms = d.inMilliseconds;
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')},${millis.toString().padLeft(3, '0')}';
  }

  // ─────────────────────── ASS / SSA ───────────────────────

  static String toAss(SubtitleDocument doc, {bool isSsa = false}) {
    final buf = StringBuffer();
    buf.writeln('[Script Info]');
    buf.writeln(isSsa ? 'ScriptType: v4.00' : 'ScriptType: v4.00+');
    buf.writeln('PlayResX: 1920');
    buf.writeln('PlayResY: 1080');
    if (doc.title != null && doc.title!.isNotEmpty) {
      buf.writeln('Title: ${doc.title}');
    }
    buf.writeln('ScaledBorderAndShadow: yes');
    buf.writeln();
    buf.writeln(isSsa ? '[V4 Styles]' : '[V4+ Styles]');
    buf.writeln(
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
        'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
        'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
        'Alignment, MarginL, MarginR, MarginV, Encoding');
    final st = doc.style ?? const SubtitleStyle();
    buf.writeln(
        'Style: Default,${_safeStyle(st.fontName)},${st.fontSize.toStringAsFixed(0)},'
        '&H00FFFFFF,&H000000FF,&H00101010,&H80000000,'
        '${st.bold ? -1 : 0},${st.italic ? -1 : 0},0,0,100,100,0,0,1,2,1,2,20,20,30,1');
    buf.writeln();
    buf.writeln('[Events]');
    buf.writeln('Format: Layer, Start, End, Style, Name, MarginL, MarginR, '
        'MarginV, Effect, Text');
    for (final c in doc.cues) {
      final text = c.rawText
          .replaceAll('\r', '')
          .replaceAll('\n', r'\N');
      buf.writeln('Dialogue: 0,${_assTime(c.start)},${_assTime(c.end)},'
          'Default,,0,0,0,,$text');
    }
    return buf.toString();
  }

  static String _assTime(Duration d) {
    final ms = d.inMilliseconds;
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final cs = (ms % 1000) ~/ 10; // 厘秒
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
        '.${cs.toString().padLeft(2, '0')}';
  }

  /// 样式字体名不允许含逗号/引号（会破坏 Style 行字段）。
  static String _safeStyle(String name) =>
      name.replaceAll(',', '').replaceAll('"', '');

  // ───────────────────────── VTT ─────────────────────────

  static String toVtt(List<SubtitleCue> cues) {
    final buf = StringBuffer();
    buf.writeln('WEBVTT');
    buf.writeln();
    for (var i = 0; i < cues.length; i++) {
      final c = cues[i];
      buf.writeln('${_vttTime(c.start)} --> ${_vttTime(c.end)}');
      buf.writeln(_normalizeNewlines(c.rawText));
      buf.writeln();
    }
    return buf.toString();
  }

  static String _vttTime(Duration d) {
    final ms = d.inMilliseconds;
    final h = ms ~/ 3600000;
    final m = (ms % 3600000) ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    final millis = ms % 1000;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:'
        '${s.toString().padLeft(2, '0')}.${millis.toString().padLeft(3, '0')}';
  }

  // ─────────────────────── MicroDVD ───────────────────────

  static String toMicroDvd(List<SubtitleCue> cues, {double fps = 25}) {
    final buf = StringBuffer();
    buf.writeln('{1}{1}${fps.toStringAsFixed(3)}');
    for (final c in cues) {
      final startF = (c.start.inMilliseconds / 1000 * fps).round();
      final endF = (c.end.inMilliseconds / 1000 * fps).round();
      final text = c.rawText.replaceAll('\r', '').replaceAll('\n', '|');
      buf.writeln('{$startF}{$endF}$text');
    }
    return buf.toString();
  }

  static String _normalizeNewlines(String s) =>
      s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
}
