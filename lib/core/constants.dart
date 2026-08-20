/// 全局常量：支持的格式、目录名、Hive Box 名等。
library;

/// 字幕烧录样式预设：null = 保留 ASS 原样式（走 `ass` 滤镜，样式/特效全保留）；
/// 否则走 `subtitles` 滤镜 + force_style 强制统一样式（适合 SRT / 多字幕统一观感）。
const Map<String, String?> kBurnStylePresets = {
  '保留 ASS 原样式': null,
  '默认白字黑边':
      'FontName=Noto Sans CJK SC,FontSize=20,Outline=1,Shadow=0,'
      'PrimaryColour=&H00FFFFFF&,OutlineColour=&H00000000&',
  '经典黄字':
      'FontName=Noto Sans CJK SC,FontSize=20,Outline=1,Shadow=0,'
      'PrimaryColour=&H0000FFFF&,OutlineColour=&H00000000&',
  '大字描边':
      'FontName=Noto Sans CJK SC,FontSize=28,Outline=3,Shadow=1,'
      'PrimaryColour=&H00FFFFFF&,OutlineColour=&H00000000&',
};

class AppConstants {
  AppConstants._();

  static const String appName = 'Subtitle Studio Pro';
  static const String appVersion = '1.0.0';

  /// 支持的视频扩展名（小写）
  static const List<String> videoExtensions = [
    'mp4', 'mov', 'mkv', 'avi', 'flv', 'webm',
    'm4v', 'wmv', 'ts', 'm2ts', '3gp', 'mpg', 'mpeg', 'vob',
  ];

  /// 支持的字幕扩展名（小写）
  static const List<String> subtitleExtensions = [
    'srt', 'ass', 'ssa', 'vtt', 'sub',
  ];

  /// 支持转换输出的视频容器
  static const List<String> outputContainers = [
    'mp4', 'mkv', 'mov', 'webm', 'avi',
  ];

  /// 支持转换输出的字幕格式
  static const List<String> outputSubtitleFormats = [
    'srt', 'ass', 'ssa', 'vtt', 'sub',
  ];

  /// 支持的音频扩展名
  static const List<String> audioExtensions = [
    'mp3', 'aac', 'm4a', 'wav', 'flac', 'ogg', 'opus',
  ];

  /// 应用私有目录名
  static const String appDirName = 'subtitle_studio';

  /// 各类产物子目录
  static const String dirConvert = 'convert';
  static const String dirBurn = 'burn';
  static const String dirExtract = 'extract';
  static const String dirTranscode = 'transcode';
  static const String dirMux = 'mux';
  static const String dirTranslate = 'translate';
  static const String dirWhisper = 'whisper';
  static const String dirThumb = 'thumbs';
  static const String dirTemp = 'tmp';

  /// Hive Box 名称
  static const String boxHistory = 'history';
  static const String boxSettings = 'settings';

  /// 历史记录容量上限
  static const int maxHistoryEntries = 200;

  /// 日志缓冲上限（行）
  static const int maxLogLines = 2000;
}
