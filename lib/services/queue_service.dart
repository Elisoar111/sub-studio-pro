import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/utils/logger.dart';
import '../models/history_entry.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../models/task_run_result.dart';
import 'ffmpeg/ffmpeg_runner.dart';
import 'ffmpeg/ffmpeg_service.dart';
import 'notification_service.dart';
import 'task_runner.dart';

/// 任务队列服务：双车道调度烧录 / 提取 / 转码 / mux / 翻译 / Whisper 任务，
/// 统一驱动进度、取消、历史记录。
///
/// 设计说明：
/// - **双车道调度**：网络型任务（AI 翻译，`TaskType.isNetwork`）与本地
///   子进程任务（烧录/转码/…）并行执行；每条车道内部串行——本地串行
///   避免 CPU/IO 争抢，网络串行避免 API 限流；
/// - 每个任务独立 [CancelToken]，支持取消单个任务；
/// - 任务怎么执行在 [TaskRunner]（已拆分）；本类只管调度与状态流转：
///   pending → running → completed/failed/cancelled、进度刷新通知、
///   历史落盘、批量完成系统通知。
class QueueService extends ChangeNotifier {
  QueueService._({TaskRunner? runner}) : _runner = runner ?? const TaskRunner();

  static final QueueService instance = QueueService._();

  /// 测试注入口：注入 Fake runner 验证调度行为，不碰单例状态。
  @visibleForTesting
  factory QueueService.forTesting({TaskRunner? runner}) =>
      QueueService._(runner: runner);

  static const _uuid = Uuid();

  FfmpegService? _ffmpeg;
  void Function(QueueTask task)? _historySaver;
  final TaskRunner _runner;

  final List<QueueTask> _tasks = [];
  final Map<String, CancelToken> _tokens = {};
  bool _running = false;

  List<QueueTask> get tasks => List.unmodifiable(_tasks);
  bool get isRunning => _running;
  bool get hasPending =>
      _tasks.any((t) => t.status == TaskStatus.pending);

  /// main() 中初始化。[_historySaver] 用于任务结束时写入历史。
  void init({
    required FfmpegService ffmpeg,
    void Function(QueueTask task)? onTaskFinished,
  }) {
    _ffmpeg = ffmpeg;
    _historySaver = onTaskFinished;
  }

  // ─────────────────────── 入队 ───────────────────────

  QueueTask addTask({
    required TaskType type,
    required String title,
    Map<String, String> params = const {},
  }) {
    final task = QueueTask(
      id: _uuid.v4(),
      type: type,
      title: title,
      params: Map.of(params),
    );
    _tasks.add(task);
    notifyListeners();
    return task;
  }

  void addAll(List<QueueTask> tasks) {
    _tasks.addAll(tasks);
    notifyListeners();
  }

  // ─────────────────────── 执行 ───────────────────────

  /// 执行所有 pending 任务（幂等：已有队列在跑时直接返回）。
  ///
  /// 双车道：网络车道（AI 翻译）与本地车道并行推进，车道内串行。
  /// 车道跑空后若又出现新 pending（运行中入队 / 失败重试），外层
  /// while 会重新拉起对应车道接续执行。
  Future<void> start() async {
    if (_running) return;
    _running = true;
    notifyListeners();
    var success = 0;
    var failed = 0;
    var cancelled = 0;
    void count(QueueTask t) {
      switch (t.status) {
        case TaskStatus.completed:
          success++;
        case TaskStatus.failed:
          failed++;
        case TaskStatus.cancelled:
          cancelled++;
        default:
          break;
      }
    }

    try {
      while (_tasks.any((t) => t.status == TaskStatus.pending)) {
        final lanes = <Future<void>>[
          if (_tasks.any((t) => t.status == TaskStatus.pending && t.type.isNetwork))
            _runLane(network: true, count: count),
          if (_tasks.any((t) => t.status == TaskStatus.pending && !t.type.isNetwork))
            _runLane(network: false, count: count),
        ];
        await Future.wait(lanes);
      }
    } finally {
      _running = false;
      notifyListeners();
    }
    // 批量完成系统通知（后台跑任务不用盯屏）
    if (success + failed + cancelled > 0) {
      NotificationService.instance.notifyBatchComplete(
        success: success,
        failed: failed,
        cancelled: cancelled,
      );
    }
  }

  /// 单条车道：串行取 pending 任务执行，直到该车道无 pending。
  Future<void> _runLane({
    required bool network,
    required void Function(QueueTask task) count,
  }) async {
    while (true) {
      QueueTask? next;
      for (final t in _tasks) {
        if (t.status == TaskStatus.pending && t.type.isNetwork == network) {
          next = t;
          break;
        }
      }
      if (next == null) return;
      await _runOne(next);
      count(next);
    }
  }

  Future<void> _runOne(QueueTask task) async {
    final ffmpeg = _ffmpeg;
    if (ffmpeg == null) {
      task.status = TaskStatus.failed;
      task.error = 'FFmpeg 服务未初始化';
      task.finishedAt = DateTime.now();
      _historySaver?.call(task);
      notifyListeners();
      return;
    }

    final token = CancelToken();
    _tokens[task.id] = token;
    task.status = TaskStatus.running;
    task.startedAt = DateTime.now();
    task.progress = 0;
    task.speed = 0;
    task.error = null;
    notifyListeners();

    TaskRunResult? result;
    try {
      result = await _runner.run(
        task: task,
        ffmpeg: ffmpeg,
        token: token,
        notify: notifyListeners,
      );
    } catch (e, st) {
      Logger.instance.error('任务执行异常 ${task.id}', e, st);
      result = TaskRunResult(success: false, error: '$e');
    }

    final cancelled = token.isCancelled || (result?.cancelled ?? false);
    if (cancelled) {
      task.status = TaskStatus.cancelled;
      task.error = '已取消';
    } else if (result?.success ?? false) {
      task.status = TaskStatus.completed;
      task.progress = 1;
      final out = result!.outputs;
      task.outputPath =
          out.isNotEmpty ? (out.first.path ?? out.first.name) : null;
    } else {
      task.status = TaskStatus.failed;
      task.error = result?.error ?? '未知错误';
    }
    task.finishedAt = DateTime.now();
    _tokens.remove(task.id);
    notifyListeners();
    _historySaver?.call(task);
  }

  // ─────────────────────── 取消 / 管理 ───────────────────────

  void cancelTask(String id) {
    _tokens[id]?.cancel();
  }

  /// 失败重试：任务回到 pending 并重新启动队列。
  void retryTask(String id) {
    for (final t in _tasks) {
      if (t.id == id) {
        t.status = TaskStatus.pending;
        t.error = null;
        t.progress = 0;
        break;
      }
    }
    notifyListeners();
    start();
  }

  void cancelAll() {
    for (final t in _tokens.values) {
      t.cancel();
    }
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    _tokens.remove(id);
    notifyListeners();
  }

  void clearFinished() {
    _tasks.removeWhere((t) => t.status.isFinished);
    notifyListeners();
  }

  void clearAll() {
    _tokens.clear();
    _tasks.clear();
    notifyListeners();
  }
}

/// 从任务生成历史条目的工具。
HistoryEntry historyEntryFromTask(QueueTask task) => HistoryEntry(
      id: task.id,
      type: task.type,
      title: task.title,
      inputs: [
        if (task.params[TaskParams.videoPath]?.isNotEmpty ?? false)
          task.params[TaskParams.videoPath]!,
        if (task.params[TaskParams.subtitlePath]?.isNotEmpty ?? false)
          task.params[TaskParams.subtitlePath]!,
      ],
      output: task.outputPath,
      success: task.status == TaskStatus.completed,
      params: task.params,
      timestamp: task.finishedAt ?? DateTime.now(),
    );
