import 'dart:typed_data';

/// 任务输出文件（磁盘路径或内存字节）。
/// 非 FFmpeg 专属：翻译、Whisper、轨道封装等任务均复用此类型。
class TaskOutputFile {
  final String name;
  final String? path;
  final Uint8List? bytes;

  const TaskOutputFile({required this.name, this.path, this.bytes});

  int get size => bytes?.length ?? 0;
}

/// 任务执行结果（成功 / 取消 / 失败），附产物文件与日志。
/// 队列中所有 runner（FFmpeg / MKVToolNix / Whisper / AI 翻译）统一返回此类型。
class TaskRunResult {
  final bool success;
  final bool cancelled;
  final String? error;
  final List<TaskOutputFile> outputs;
  final String? log;

  const TaskRunResult({
    required this.success,
    this.cancelled = false,
    this.error,
    this.outputs = const [],
    this.log,
  });

  static const cancelledResult = TaskRunResult(
    success: false,
    cancelled: true,
    error: '已取消',
  );
}

/// 取消令牌：UI 调用 [cancel] 后，执行方可感知并中止。
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      try {
        l();
      } catch (_) {}
    }
    _listeners.clear();
  }
}
