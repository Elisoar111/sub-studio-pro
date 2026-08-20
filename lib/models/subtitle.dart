library;

import 'dart:ui' show Color;

/// ── 字幕数据模型 ──
/// 解析器统一输出 [SubtitleDocument]（时间轴 + 文本），
/// 播放器预览、格式转换、烧录参数都建立在这个模型之上。

/// 字幕格式枚举
enum SubtitleFormat {
  srt,
  ass,
  ssa,
  vtt,
  sub, // MicroDVD（帧时间码）
  unknown;

  static SubtitleFormat fromExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'srt':
        return SubtitleFormat.srt;
      case 'ass':
        return SubtitleFormat.ass;
      case 'ssa':
        return SubtitleFormat.ssa;
      case 'vtt':
        return SubtitleFormat.vtt;
      case 'sub':
        return SubtitleFormat.sub;
      default:
        return SubtitleFormat.unknown;
    }
  }

  /// 根据内容特征猜测格式（扩展名不可靠时兜底）
  static SubtitleFormat detectFromText(String text) {
    final t = text.trimLeft();
    if (t.startsWith('WEBVTT')) return SubtitleFormat.vtt;
    if (t.startsWith('[Script Info]')) return SubtitleFormat.ass;
    if (t.startsWith('{')) return SubtitleFormat.sub; // MicroDVD
    if (RegExp(r'^\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->', multiLine: true)
        .hasMatch(t)) {
      return SubtitleFormat.srt;
    }
    return SubtitleFormat.unknown;
  }
}

extension SubtitleFormatX on SubtitleFormat {
  String get extension {
    switch (this) {
      case SubtitleFormat.srt:
        return 'srt';
      case SubtitleFormat.ass:
        return 'ass';
      case SubtitleFormat.ssa:
        return 'ssa';
      case SubtitleFormat.vtt:
        return 'vtt';
      case SubtitleFormat.sub:
        return 'sub';
      case SubtitleFormat.unknown:
        return 'txt';
    }
  }

  String get displayName => extension.toUpperCase();

  bool get isAssFamily => this == SubtitleFormat.ass || this == SubtitleFormat.ssa;

  /// FFmpeg `-c:s` 使用的编解码名
  String get ffmpegCodec {
    switch (this) {
      case SubtitleFormat.vtt:
        return 'webvtt';
      case SubtitleFormat.ass:
      case SubtitleFormat.ssa:
        return 'ass';
      default:
        return 'srt';
    }
  }
}

/// 单条字幕（一条时间轴 + 文本）
class SubtitleCue {
  final int index;
  final Duration start;
  final Duration end;

  /// 原始文本（保留源格式标签，如 ASS 的 {\i1}、SRT 的 <i>）
  final String rawText;

  const SubtitleCue({
    required this.index,
    required this.start,
    required this.end,
    required this.rawText,
  });

  /// 去标签后的纯文本（播放器叠加显示用）
  String get plainText => _stripTags(rawText);

  /// 去除 ASS 覆盖标签与 SRT 的 HTML 标签、空白折叠
  static String _stripTags(String raw) {
    var s = raw
        .replaceAll(RegExp(r'\{[^}]*\}'), '') // ASS {\...}
        .replaceAll(r'\N', '\n')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\h', ' ')
        .replaceAll(RegExp(r'</?(i|b|u|font|color)[^>]*>', caseSensitive: false),
            ''); // SRT HTML 标签
    // 折叠空白
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    return s;
  }

  bool contains(Duration t) => t >= start && t < end;

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': start.inMilliseconds,
        'end': end.inMilliseconds,
        'raw': rawText,
      };

  factory SubtitleCue.fromJson(Map<String, dynamic> json) => SubtitleCue(
        index: json['index'] as int? ?? 0,
        start: Duration(milliseconds: json['start'] as int? ?? 0),
        end: Duration(milliseconds: json['end'] as int? ?? 0),
        rawText: json['raw'] as String? ?? '',
      );
}

/// 基础样式信息（播放器叠加预览近似渲染用；完整 ASS 样式依赖 libass）
class SubtitleStyle {
  final double fontSize;
  final Color color;
  final bool bold;
  final bool italic;
  final String fontName;

  const SubtitleStyle({
    this.fontSize = 22,
    this.color = const Color(0xFFFFFFFF),
    this.bold = false,
    this.italic = false,
    this.fontName = 'sans-serif',
  });

  /// 从 ASS [V4+ Styles] 的 Style 行解析（只取常用项）
  static SubtitleStyle fromAssStyleLine(String? line) {
    if (line == null || !line.startsWith('Style:')) {
      return const SubtitleStyle();
    }
    final parts = line.split(',');
    if (parts.length < 8) return const SubtitleStyle();
    // Format: Name, Fontname, Fontsize, PrimaryColour, ... , Bold, Italic, ...
    Color color = const Color(0xFFFFFFFF);
    final primary = parts[3].trim();
    // ASS 颜色格式 &HAABBGGRR
    final m = RegExp(r'&H([0-9a-fA-F]{6,8})').firstMatch(primary);
    if (m != null) {
      final hex = m.group(1)!;
      final bbggrr = hex.length >= 6 ? hex.substring(hex.length - 6) : hex;
      final rrggbb = bbggrr.substring(4, 6) +
          bbggrr.substring(2, 4) +
          bbggrr.substring(0, 2);
      final alpha = hex.length == 8 ? int.parse(hex.substring(0, 2), radix: 16) : 0;
      color = Color(0xFF000000 |
          (int.parse(rrggbb, radix: 16) & 0xFFFFFF) |
          (((255 - alpha) & 0xFF) << 24));
    }
    final fontSize = double.tryParse(parts[2].trim()) ?? 22;
    // v4/v4+ Format：..., BackColour(6), Bold(7), Italic(8), ...
    final bold = parts.length > 7 && (parts[7].trim() == '-1' || parts[7].trim() == '1');
    final italic = parts.length > 8 && (parts[8].trim() == '-1' || parts[8].trim() == '1');
    return SubtitleStyle(
      fontSize: fontSize.clamp(8, 96),
      color: color,
      bold: bold,
      italic: italic,
      fontName: parts[1].trim(),
    );
  }
}

/// 一份完整字幕文档
class SubtitleDocument {
  final SubtitleFormat format;

  /// 源文件编码名（检测/转换后的目标编码不写这里）
  final String? sourceEncoding;

  final String? title;
  final SubtitleStyle? style;
  final List<SubtitleCue> _cues;
  bool _sorted = false;

  SubtitleDocument({
    required this.format,
    List<SubtitleCue>? cues,
    this.sourceEncoding,
    this.title,
    this.style,
  }) : _cues = cues ?? [];

  List<SubtitleCue> get cues {
    _ensureSorted();
    return _cues;
  }

  bool get isEmpty => _cues.isEmpty;

  int get count => _cues.length;

  void _ensureSorted() {
    if (_sorted) return;
    _cues.sort((a, b) => a.start.compareTo(b.start));
    _sorted = true;
  }

  /// 查找包含时刻 [t] 的字幕（二分查找，大文件高效）
  SubtitleCue? cueAt(Duration t) {
    if (_cues.isEmpty) return null;
    _ensureSorted();
    var lo = 0, hi = _cues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final cue = _cues[mid];
      if (t < cue.start) {
        hi = mid - 1;
      } else if (t >= cue.end) {
        lo = mid + 1;
      } else {
        return cue;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'format': format.name,
        'encoding': sourceEncoding,
        'title': title,
        'cues': _cues.map((c) => c.toJson()).toList(),
      };

  factory SubtitleDocument.fromJson(Map<String, dynamic> json) =>
      SubtitleDocument(
        format: SubtitleFormat.values.asNameMap()[json['format']] ??
            SubtitleFormat.unknown,
        sourceEncoding: json['encoding'] as String?,
        title: json['title'] as String?,
        cues: (json['cues'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map(SubtitleCue.fromJson)
            .toList(),
      );
}
