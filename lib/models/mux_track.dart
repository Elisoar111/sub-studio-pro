import 'dart:convert';

/// 封装轨道类型。
enum MuxTrackType {
  subtitle,
  audio,
  attachment;

  String get label => switch (this) {
        MuxTrackType.subtitle => '字幕',
        MuxTrackType.audio => '音频',
        MuxTrackType.attachment => '附件',
      };

  /// 支持的输入扩展名（选择器过滤 + 兼容性判断）。
  Set<String> get extensions => switch (this) {
        MuxTrackType.subtitle => const {'srt', 'ass', 'ssa', 'vtt'},
        MuxTrackType.audio => const {
            'aac', 'm4a', 'mp3', 'flac', 'wav', 'ac3', 'eac3', 'dts', 'ogg', 'opus', 'wma'
          },
        // MKV 附件：字体为主，也接受图片等
        MuxTrackType.attachment =>
          const {'ttf', 'otf', 'woff', 'woff2', 'jpg', 'jpeg', 'png'},
      };
}

/// 一条待封装进容器的轨道（对齐 MKVToolNix 的 track 属性）。
class MuxTrack {
  final MuxTrackType type;
  final String path;

  /// ISO 639-2 语言码（chi/eng/jpn…；附件不适用）
  String language;

  /// 轨道名称（tags.title）
  String title;

  /// MKVToolNix flag-default：播放器默认选中的轨
  bool isDefault;

  /// MKVToolNix flag-forced：强制显示（针对字幕）
  bool isForced;

  /// MKVToolNix flag-enabled：禁用轨保留在容器但播放器跳过
  bool enabled;

  /// MKVToolNix sync 延迟（毫秒）：正数延后 / 负数提前
  int delayMs;

  /// 音频转码（旧版参数，mkvmerge 不转码，仅保持历史 JSON 兼容）
  String audioCodec;

  /// 音频转码码率（kbps，同上仅兼容保留）
  int audioBitrateKbps;

  MuxTrack({
    required this.type,
    required this.path,
    this.language = 'chi',
    this.title = '',
    this.isDefault = false,
    this.isForced = false,
    this.enabled = true,
    this.delayMs = 0,
    this.audioCodec = 'copy',
    this.audioBitrateKbps = 192,
  });

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'path': path,
        'language': language,
        'title': title,
        'default': isDefault,
        'forced': isForced,
        'enabled': enabled,
        'delayMs': delayMs,
        'audioCodec': audioCodec,
        'audioBitrateKbps': audioBitrateKbps,
      };

  factory MuxTrack.fromJson(Map<String, dynamic> json) => MuxTrack(
        type: MuxTrackType.values.asNameMap()[json['type']] ??
            MuxTrackType.subtitle,
        path: json['path'] as String? ?? '',
        language: json['language'] as String? ?? 'chi',
        title: json['title'] as String? ?? '',
        isDefault: json['default'] as bool? ?? false,
        isForced: json['forced'] as bool? ?? false,
        enabled: json['enabled'] as bool? ?? true,
        delayMs: json['delayMs'] as int? ?? 0,
        audioCodec: json['audioCodec'] as String? ?? 'copy',
        audioBitrateKbps: json['audioBitrateKbps'] as int? ?? 192,
      );

  static String encodeList(List<MuxTrack> tracks) =>
      jsonEncode([for (final t in tracks) t.toJson()]);

  static List<MuxTrack> decodeList(String raw) {
    if (raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(MuxTrack.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}

/// 源视频轨道的属性覆盖（MKVToolNix 源轨 track options）：
/// 对应 mkvmerge 的 --language/--track-name/--default-track/
/// --forced-track/--track-enabled/--sync，字段 null = 跟随源不动。
class SourceTrackEdit {
  /// mkvmerge -J 轨道 ID（作用于源视频输入）
  final int id;
  String? language;
  String? name;
  bool? isDefault;
  bool? isForced;
  bool? enabled;

  /// 延迟毫秒（--sync）：null = 不调整
  int? delayMs;

  SourceTrackEdit({
    required this.id,
    this.language,
    this.name,
    this.isDefault,
    this.isForced,
    this.enabled,
    this.delayMs,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        if (language != null) 'language': language,
        if (name != null) 'name': name,
        if (isDefault != null) 'default': isDefault,
        if (isForced != null) 'forced': isForced,
        if (enabled != null) 'enabled': enabled,
        if (delayMs != null) 'delayMs': delayMs,
      };

  factory SourceTrackEdit.fromJson(Map<String, dynamic> json) =>
      SourceTrackEdit(
        id: json['id'] as int? ?? 0,
        language: json['language'] as String?,
        name: json['name'] as String?,
        isDefault: json['default'] as bool?,
        isForced: json['forced'] as bool?,
        enabled: json['enabled'] as bool?,
        delayMs: json['delayMs'] as int?,
      );

  /// 解析 sourceSel JSON 中的 edits 数组。
  static List<SourceTrackEdit> listFromJson(dynamic v) =>
      (v as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SourceTrackEdit.fromJson)
          .toList(growable: false);
}
