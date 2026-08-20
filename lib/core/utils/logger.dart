import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../constants.dart';

/// 轻量日志器：内存环形缓冲 + 可导出文本。
/// 记录应用事件与 FFmpeg 会话日志，用于问题排查（可在设置页导出）。
class Logger {
  Logger._();

  static final Logger instance = Logger._();

  final Queue<String> _buffer = ListQueue<String>();

  /// 记录一条日志（自动加时间戳）。
  void log(String message, {String? tag}) {
    final line = '[${DateTime.now().toIso8601String()}]'
        '${tag == null ? '' : '[$tag]'} $message';
    _buffer.add(line);
    if (_buffer.length > AppConstants.maxLogLines) {
      _buffer.removeFirst();
    }
    debugPrint(line);
  }

  void error(String message, [Object? error, StackTrace? stack]) {
    log('$message${error == null ? '' : ' | $error'}'
        '${stack == null ? '' : '\n$stack'}', tag: 'ERROR');
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
