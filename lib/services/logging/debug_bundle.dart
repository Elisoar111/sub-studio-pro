import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

/// 调试包导出（v1.5 崩溃与日志）：
/// 日志目录全部 `.log` 文件 + 设置快照（API Key 脱敏）打成一个 zip，
/// 供用户报障时回传。
class DebugBundle {
  DebugBundle._();

  /// 导出调试包到 [outputPath]，返回 zip 文件。
  static File export({
    required Directory logsDir,
    required Map<String, String> settings,
    required String outputPath,
  }) {
    final archive = Archive();
    if (logsDir.existsSync()) {
      for (final entity in logsDir.listSync()) {
        if (entity is File && entity.path.endsWith('.log')) {
          archive.addFile(ArchiveFile.bytes(
              'logs/${p.basename(entity.path)}', entity.readAsBytesSync()));
        }
      }
    }
    archive.addFile(
        ArchiveFile.string('settings.json', jsonEncode(sanitize(settings))));

    final out = File(outputPath);
    out.writeAsBytesSync(ZipEncoder().encode(archive));
    return out;
  }

  /// 设置脱敏：键名含 `api_key`/`apikey`（不区分大小写）的值打码，
  /// 其余原样保留。
  static Map<String, String> sanitize(Map<String, String> settings) {
    return settings.map((key, value) {
      final lower = key.toLowerCase();
      if (!lower.contains('api_key') && !lower.contains('apikey')) {
        return MapEntry(key, value);
      }
      if (value.isEmpty) return MapEntry(key, value);
      if (value.length <= 8) return MapEntry(key, '****');
      return MapEntry(key, '${value.substring(0, 4)}****');
    });
  }
}
