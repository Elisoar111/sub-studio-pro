/// 任务队列模型：任务类型 / 状态 / 队列项。
/// 所有耗时操作（烧录、提取、转码、批量转换）统一进入 [QueueTask]，
/// 由 QueueService 串行执行并驱动进度 UI。
library;

enum TaskType {
  subtitleConvert,
  burn,
  extract,
  transcode,
  mux,
  subtitleTranslate,
  whisper;

  String get label {
    switch (this) {
      case TaskType.subtitleConvert:
        return '字幕转换';
      case TaskType.burn:
        return '字幕烧录';
      case TaskType.extract:
        return '字幕提取';
      case TaskType.transcode:
        return '转码压缩';
      case TaskType.mux:
        return '封装软字幕';
      case TaskType.subtitleTranslate:
        return '字幕翻译';
      case TaskType.whisper:
        return 'Whisper字幕';
    }
  }

  /// 网络型任务（走 HTTP API，不占本地 CPU）：仅 AI 翻译。
  /// 调度时与本地子进程任务并行执行。
  bool get isNetwork => this == TaskType.subtitleTranslate;
}

enum TaskStatus {
  pending,
  running,
  completed,
  failed,
  cancelled;

  bool get isFinished =>
      this == completed || this == failed || this == cancelled;
}

class QueueTask {
  final String id;
  final TaskType type;
  final String title;

  /// 执行参数（序列化为字符串，供 QueueService 重建请求；也用于历史回显）
  final Map<String, String> params;

  TaskStatus status;
  double progress; // 0..1
  double speed; // 实时倍率（ffmpeg speed）
  Duration time; // 已处理时长
  String? outputPath;
  String? error;

  final DateTime createdAt;
  DateTime? startedAt;
  DateTime? finishedAt;

  QueueTask({
    required this.id,
    required this.type,
    required this.title,
    this.params = const {},
    this.status = TaskStatus.pending,
    this.progress = 0,
    this.speed = 0,
    this.time = Duration.zero,
    this.outputPath,
    this.error,
    DateTime? createdAt,
    this.startedAt,
    this.finishedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  String get statusLabel {
    switch (status) {
      case TaskStatus.pending:
        return '等待中';
      case TaskStatus.running:
        return '处理中';
      case TaskStatus.completed:
        return '完成';
      case TaskStatus.failed:
        return '失败';
      case TaskStatus.cancelled:
        return '已取消';
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'title': title,
        'params': params,
        'status': status.name,
        'progress': progress,
        'speed': speed,
        'timeMs': time.inMilliseconds,
        'output': outputPath,
        'error': error,
        'createdAt': createdAt.toIso8601String(),
        'startedAt': startedAt?.toIso8601String(),
        'finishedAt': finishedAt?.toIso8601String(),
      };

  factory QueueTask.fromJson(Map<String, dynamic> json) => QueueTask(
        id: json['id'] as String? ?? '',
        type: TaskType.values.asNameMap()[json['type']] ?? TaskType.transcode,
        title: json['title'] as String? ?? '',
        params: Map<String, String>.from(json['params'] as Map? ?? {}),
        status: TaskStatus.values.asNameMap()[json['status']] ??
            TaskStatus.pending,
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        speed: (json['speed'] as num?)?.toDouble() ?? 0,
        time: Duration(milliseconds: json['timeMs'] as int? ?? 0),
        outputPath: json['output'] as String?,
        error: json['error'] as String?,
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        startedAt:
            DateTime.tryParse(json['startedAt'] as String? ?? ''),
        finishedAt:
            DateTime.tryParse(json['finishedAt'] as String? ?? ''),
      );
}
