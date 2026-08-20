/// 视频媒体信息模型（来自 ffprobe，跨平台通用结构）。
library;

class VideoStreamInfo {
  final int index;
  final String codec;
  final int? width;
  final int? height;
  final double? fps;
  final int? bitrate; // bps
  final String? pixelFormat;

  const VideoStreamInfo({
    required this.index,
    required this.codec,
    this.width,
    this.height,
    this.fps,
    this.bitrate,
    this.pixelFormat,
  });

  String get resolutionLabel =>
      (width != null && height != null) ? '${width}x$height' : '未知';
}

class AudioStreamInfo {
  final int index;
  final String codec;
  final int? channels;
  final int? sampleRate;
  final int? bitrate;
  final String? language;

  const AudioStreamInfo({
    required this.index,
    required this.codec,
    this.channels,
    this.sampleRate,
    this.bitrate,
    this.language,
  });
}

class SubtitleStreamInfo {
  final int index;
  final String codec;
  final String? language;
  final String? title;

  const SubtitleStreamInfo({
    required this.index,
    required this.codec,
    this.language,
    this.title,
  });

  String get label {
    final parts = <String>[codec];
    if (language != null && language!.isNotEmpty) parts.add(language!);
    if (title != null && title!.isNotEmpty) parts.add(title!);
    return '轨 #$index · ${parts.join(' / ')}';
  }

  /// 图形字幕（PGS/VobSub）：无法直接转文本，需 OCR。
  bool get isBitmap =>
      codec.contains('pgs') || codec.contains('dvd_subtitle') ||
      codec.contains('hdmv') || codec.contains('dvb');
}

/// 附件流（MKV 内嵌字体等）。
class AttachmentStreamInfo {
  final int index;

  /// ttf / otf / 附带图片类型
  final String codec;

  /// 字体在容器内的文件名（tags.filename），缺失时用 title 或自动命名
  final String? filename;
  final String? title;

  const AttachmentStreamInfo({
    required this.index,
    required this.codec,
    this.filename,
    this.title,
  });

  String get displayName => filename ?? title ?? 'attachment_$index';

  /// 提取输出用的扩展名（按编码猜）。
  String get outputExtension {
    switch (codec.toLowerCase()) {
      case 'ttf':
        return 'ttf';
      case 'otf':
        return 'otf';
      case 'woff':
        return 'woff';
      default:
        final n = filename ?? '';
        final dot = n.lastIndexOf('.');
        return dot > 0 ? n.substring(dot + 1).toLowerCase() : 'bin';
    }
  }
}

class VideoInfo {
  final String path;
  final String? formatName;
  final Duration duration;
  final int? bitrate; // bps
  final int? sizeBytes;
  final List<VideoStreamInfo> videoStreams;
  final List<AudioStreamInfo> audioStreams;
  final List<SubtitleStreamInfo> subtitleStreams;
  final List<AttachmentStreamInfo> attachmentStreams;

  const VideoInfo({
    required this.path,
    this.formatName,
    this.duration = Duration.zero,
    this.bitrate,
    this.sizeBytes,
    this.videoStreams = const [],
    this.audioStreams = const [],
    this.subtitleStreams = const [],
    this.attachmentStreams = const [],
  });

  /// probe 失败时的兜底
  factory VideoInfo.unknown(String path) =>
      VideoInfo(path: path, formatName: '未知格式');

  VideoStreamInfo? get firstVideo =>
      videoStreams.isNotEmpty ? videoStreams.first : null;

  AudioStreamInfo? get firstAudio =>
      audioStreams.isNotEmpty ? audioStreams.first : null;

  bool get hasAudio => audioStreams.isNotEmpty;
  bool get hasSubtitles => subtitleStreams.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'path': path,
        'format': formatName,
        'durationMs': duration.inMilliseconds,
        'bitrate': bitrate,
        'size': sizeBytes,
        'vstreams': videoStreams
            .map((s) => {
                  'index': s.index,
                  'codec': s.codec,
                  'width': s.width,
                  'height': s.height,
                  'fps': s.fps,
                  'bitrate': s.bitrate,
                  'pixfmt': s.pixelFormat,
                })
            .toList(),
        'astreams': audioStreams
            .map((s) => {
                  'index': s.index,
                  'codec': s.codec,
                  'channels': s.channels,
                  'rate': s.sampleRate,
                  'bitrate': s.bitrate,
                  'lang': s.language,
                })
            .toList(),
        'sstreams': subtitleStreams
            .map((s) => {
                  'index': s.index,
                  'codec': s.codec,
                  'lang': s.language,
                  'title': s.title,
                })
            .toList(),
        'tstreams': attachmentStreams
            .map((s) => {
                  'index': s.index,
                  'codec': s.codec,
                  'filename': s.filename,
                  'title': s.title,
                })
            .toList(),
      };

  factory VideoInfo.fromJson(Map<String, dynamic> json) => VideoInfo(
        path: json['path'] as String? ?? '',
        formatName: json['format'] as String?,
        duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
        bitrate: json['bitrate'] as int?,
        sizeBytes: json['size'] as int?,
        videoStreams: (json['vstreams'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((s) => VideoStreamInfo(
                  index: s['index'] as int? ?? 0,
                  codec: s['codec'] as String? ?? '?',
                  width: s['width'] as int?,
                  height: s['height'] as int?,
                  fps: (s['fps'] as num?)?.toDouble(),
                  bitrate: s['bitrate'] as int?,
                  pixelFormat: s['pixfmt'] as String?,
                ))
            .toList(),
        audioStreams: (json['astreams'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((s) => AudioStreamInfo(
                  index: s['index'] as int? ?? 0,
                  codec: s['codec'] as String? ?? '?',
                  channels: s['channels'] as int?,
                  sampleRate: s['rate'] as int?,
                  bitrate: s['bitrate'] as int?,
                  language: s['lang'] as String?,
                ))
            .toList(),
        subtitleStreams: (json['sstreams'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((s) => SubtitleStreamInfo(
                  index: s['index'] as int? ?? 0,
                  codec: s['codec'] as String? ?? '?',
                  language: s['lang'] as String?,
                  title: s['title'] as String?,
                ))
            .toList(),
        attachmentStreams: (json['tstreams'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .map((s) => AttachmentStreamInfo(
                  index: s['index'] as int? ?? 0,
                  codec: s['codec'] as String? ?? '?',
                  filename: s['filename'] as String?,
                  title: s['title'] as String?,
                ))
            .toList(),
      );
}
