import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_run_result.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';
import 'package:subtitle_studio_pro/services/task_runner.dart';

/// 队列暂停 / 恢复（v2.0 系统托盘配套）：
/// - pause：当前 running 任务继续跑完（不打断），下一任务保持 pending；
/// - resume：接续执行剩余 pending；
/// - 队列静止时 resume 自动拉起调度。
class _GateRunner extends TaskRunner {
  final Map<String, Completer<void>> gates = {};

  Completer<void> gate(String id) => gates.putIfAbsent(id, Completer<void>.new);

  @override
  Future<TaskRunResult?> run({
    required QueueTask task,
    required FfmpegService ffmpeg,
    required CancelToken token,
    required void Function() notify,
  }) async {
    await gate(task.id).future;
    return const TaskRunResult(success: true);
  }
}

Future<bool> _until(
  bool Function() cond, [
  Duration timeout = const Duration(seconds: 5),
]) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) return false;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late QueueService queue;
  late _GateRunner runner;
  late FfmpegService ffmpeg;

  setUpAll(() async {
    ffmpeg = await FfmpegService.create();
  });

  setUp(() {
    runner = _GateRunner();
    queue = QueueService.forTesting(runner: runner);
    queue.init(ffmpeg: ffmpeg);
  });

  test('初始未暂停；pause/resume 状态流转并通知监听者', () async {
    expect(queue.isPaused, isFalse);
    var notified = 0;
    void listener() => notified++;
    queue.addListener(listener);
    queue.pause();
    expect(queue.isPaused, isTrue);
    expect(notified, greaterThan(0));
    queue.resume();
    expect(queue.isPaused, isFalse);
    queue.removeListener(listener);
  });

  test('pause 后当前任务跑完，下一任务保持 pending 不启动', () async {
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    final b = queue.addTask(type: TaskType.burn, title: 'B');

    var queueDone = false;
    final done = queue.start().then((_) => queueDone = true);
    expect(await _until(() => a.status == TaskStatus.running), isTrue);

    queue.pause();
    runner.gate(a.id).complete();

    expect(await _until(() => a.status == TaskStatus.completed), isTrue,
        reason: '暂停不打断运行中任务');
    // 给调度循环时间确认 B 不被拉起
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(b.status, TaskStatus.pending, reason: '暂停期间后续任务不得启动');
    expect(queueDone, isFalse, reason: '队列调度整体挂起而非结束');

    queue.resume();
    expect(await _until(() => b.status == TaskStatus.running), isTrue,
        reason: '恢复后接续执行');
    runner.gate(b.id).complete();
    await done;
    expect(b.status, TaskStatus.completed);
  });

  test('暂停期间新入队的任务在 resume 后才执行', () async {
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);
    queue.pause();
    runner.gate(a.id).complete();
    expect(await _until(() => a.status == TaskStatus.completed), isTrue);

    final b = queue.addTask(type: TaskType.transcode, title: 'B');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(b.status, TaskStatus.pending);

    queue.resume();
    expect(await _until(() => b.status == TaskStatus.running), isTrue);
    runner.gate(b.id).complete();
    await done;
  });

  test('队列静止时 resume 自动拉起 pending 任务', () async {
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    queue.pause();
    final done = queue.start();
    // 车道因暂停挂起，A 不启动
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(a.status, TaskStatus.pending);

    queue.resume();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);
    runner.gate(a.id).complete();
    await done;
    expect(a.status, TaskStatus.completed);
  });

  test('resume 在队列未运行时不抛异常（无 pending 时为空操作）', () async {
    queue.resume();
    expect(queue.isPaused, isFalse);
    expect(queue.isRunning, isFalse);
  });
}
