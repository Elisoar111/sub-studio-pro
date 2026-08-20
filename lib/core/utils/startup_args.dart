import 'dart:io';

import '../constants.dart';

/// 从启动参数筛出字幕文件（v1.5 安装包文件关联：双击 .srt 等打开应用）。
///
/// 规则：路径真实存在 + 扩展名属于字幕格式（大小写不敏感），
/// 结果去重并保持参数顺序。视频等其它格式一律忽略。
List<String> subtitleFilesFromArgs(List<String> args) {
  final subtitleExts =
      AppConstants.subtitleExtensions.map((e) => e.toLowerCase()).toSet();
  final result = <String>[];
  for (final arg in args) {
    if (arg.isEmpty || result.contains(arg)) continue;
    if (!File(arg).existsSync()) continue;
    final dot = arg.lastIndexOf('.');
    if (dot == -1 || dot == arg.length - 1) continue;
    if (!subtitleExts.contains(arg.substring(dot + 1).toLowerCase())) continue;
    result.add(arg);
  }
  return result;
}
