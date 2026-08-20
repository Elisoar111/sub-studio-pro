library;

import 'package:path/path.dart' as p;

/// 输出文件名模板渲染。
///
/// 支持的变量（中英别名等价）：
/// - `{原文件名}` / `{basename}`：源文件去扩展名
/// - `{时间戳}` / `{timestamp}`：当前毫秒时间戳
/// - `{日期}` / `{date}`：yyyy_MM_dd-HHmmss
/// - `{序号}` / `{index}`：批量任务序号 / 字幕轨序号
/// - `{容器}` / `{container}`：输出容器（转码用，如 mp4）
/// - `{轨道类型}` / `{trackType}`：video / audio / subtitle / attachment
/// - `{轨道ID}` / `{trackId}`：源文件流索引（gMKVExtractGUI 式 Track ID）
///
/// 示例：`{原文件名}_burned_{时间戳}` → `EP01_burned_1770000000000`
class FilenameTemplate {
  FilenameTemplate._();

  /// 各功能内置默认模板
  static const String convertDefault = '{原文件名}';
  static const String burnDefault = '{原文件名}_burned';
  static const String extractDefault = '{原文件名}_{轨道类型}{轨道ID}';
  static const String transcodeDefault = '{原文件名}_{容器}';
  static const String muxDefault = '{原文件名}_muxed';

  /// 所有可用变量的说明（供 UI 展示）
  static const Map<String, String> variables = {
    '{原文件名}': '源文件名（无扩展名）',
    '{时间戳}': '当前毫秒时间戳',
    '{日期}': '当前日期时间 yyyy_MM_dd-HHmmss',
    '{序号}': '批量 / 字幕轨序号',
    '{容器}': '输出容器（转码）',
    '{轨道类型}': '轨道类型（subtitle/audio/video/attachment）',
    '{轨道ID}': '源流索引（Track ID）',
  };

  /// 渲染模板为文件名。
  ///
  /// [sourceName] 源文件完整名；[extension] 输出扩展名（自动补点，可空）；
  /// [index] 序号变量值；[container] 容器变量值；
  /// [trackType] / [trackId] 轨道提取用。
  static String render(
    String template, {
    required String sourceName,
    String? extension,
    int? index,
    String? container,
    String? trackType,
    int? trackId,
  }) {
    final base = p.basenameWithoutExtension(sourceName);
    final now = DateTime.now();
    final date =
        '${now.year}_${_two(now.month)}_${_two(now.day)}-'
        '${_two(now.hour)}${_two(now.minute)}${_two(now.second)}';
    var name = _emptyIfBlank(template)
        .replaceAll('{原文件名}', base)
        .replaceAll('{basename}', base)
        .replaceAll('{时间戳}', '${now.millisecondsSinceEpoch}')
        .replaceAll('{timestamp}', '${now.millisecondsSinceEpoch}')
        .replaceAll('{日期}', date)
        .replaceAll('{date}', date)
        .replaceAll('{序号}', index?.toString() ?? '')
        .replaceAll('{index}', index?.toString() ?? '')
        .replaceAll('{容器}', container ?? '')
        .replaceAll('{container}', container ?? '')
        .replaceAll('{轨道类型}', trackType ?? '')
        .replaceAll('{trackType}', trackType ?? '')
        .replaceAll('{轨道ID}', trackId?.toString() ?? '')
        .replaceAll('{trackId}', trackId?.toString() ?? '');
    name = _sanitize(name);
    if (name.isEmpty) name = base.isEmpty ? 'output' : base;
    return extension == null || extension.isEmpty
        ? name
        : '$name.$extension';
  }

  static String _emptyIfBlank(String s) => s.trim();

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// 去除 Windows 文件名非法字符（\ / : * ? " < > |）与控制符。
  static String _sanitize(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
