import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../constants.dart';
import '../../services/logging/log_file_store.dart';

/// 轻量日志器：内存环形缓冲 + 可导出文本。
/// 记录应用事件与 FFmpeg 会话日志，用于问题排查（可在设置页导出）。
/// 挂接 [attachFileStore] 后同步写结构化 JSON 记录（含崩溃捕获产物）。
class Logger {
  Logger._();

  static final Logger instance = Logger._();

  final Queue<String> _buffer = ListQueue<String>();

  LogFileStore? _fileStore;

  /// 挂接/更换/摘除落盘存储（null = 仅内存缓冲）。
  void attachFileStore(LogFileStore? store) => _fileStore = store;

  /// 记录一条日志（自动加时间戳）。
  void log(String message, {String? tag, String level = 'info'}) {
    final ts = DateTime.now().toIso8601String();
    final line = '[${ts.toString()}]${tag == null ? '' : '[$tag]'} $message';
    _buffer.add(line);
    if (_buffer.length > AppConstants.maxLogLines) {
      _buffer.removeFirst();
    }
    _fileStore?.write({
      'ts': ts,
      'level': level,
      'tag': tag ?? 'APP',
      'message': message,
    });
    debugPrint(line);
  }

  void error(String message, [Object? error, StackTrace? stack]) {
    log('$message${error == null ? '' : ' | $error'}'
        '${stack == null ? '' : '\n$stack'}', tag: 'ERROR', level: 'error');
  }

  void ffmpeg(String sessionId, String line) {
    log(line, tag: 'ffmpeg#$sessionId');
  }

  /// 导出全部日志文本。
  String dump() => _buffer.join('\n');

  /// 取包含指定 tag 的日志行（如某任务的 ffmpeg 会话 `ffmpeg#<id前6位>`）。
  List<String> linesForTag(String tag) =>
      _buffer.where((l) => l.contains('[$tag]')).toList();

  void clear() {
    _buffer.clear();
  }

  bool get isEmpty => _buffer.isEmpty;
}
