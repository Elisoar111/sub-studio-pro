import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_run_result.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';
import 'package:subtitle_studio_pro/services/task_runner.dart';

/// 队列清除与移除（v2.0.2 修复）：
/// - clearAll / removeTask 移除运行中任务时必须取消其 CancelToken，
///   否则子进程（ffmpeg/mkvmerge）继续跑完并写盘，且用户无法再取消；
/// - 被用户主动清除的任务完成后不写历史。
class _GateRunner extends TaskRunner {
  final Map<String, Completer<void>> gates = {};
  final List<String> cancelledIds = [];

  Completer<void> gate(String id) => gates.putIfAbsent(id, Completer<void>.new);

  @override
  Future<TaskRunResult?> run({
    required QueueTask task,
    required FfmpegService ffmpeg,
    required CancelToken token,
    required void Function() notify,
  }) async {
    token.addListener(() {
      if (token.isCancelled) cancelledIds.add(task.id);
    });
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
  late List<String> finishedIds;

  setUpAll(() async {
    ffmpeg = await FfmpegService.create();
  });

  setUp(() {
    runner = _GateRunner();
    queue = QueueService.forTesting(runner: runner);
    finishedIds = [];
    queue.init(
      ffmpeg: ffmpeg,
      onTaskFinished: (t) => finishedIds.add(t.id),
    );
  });

  test('clearAll 取消运行中任务的子进程且不写历史', () async {
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);

    queue.clearAll();

    expect(await _until(() => runner.cancelledIds.contains(a.id)), isTrue,
        reason: 'clearAll 应取消运行中任务的 CancelToken（终止子进程）');
    runner.gate(a.id).complete();
    await done;
    expect(finishedIds, isNot(contains(a.id)),
        reason: '被用户清除的任务不应写入历史');
  });

  test('removeTask 取消运行中任务的子进程且不写历史', () async {
    final a = queue.addTask(type: TaskType.transcode, title: 'A');
    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);

    queue.removeTask(a.id);

    expect(await _until(() => runner.cancelledIds.contains(a.id)), isTrue,
        reason: 'removeTask 移除运行中任务应同时取消其子进程');
    runner.gate(a.id).complete();
    await done;
    expect(finishedIds, isNot(contains(a.id)),
        reason: '被用户移除的任务不应写入历史');
  });

  test('正常运行完成的任务仍写历史（防过度修复）', () async {
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);
    runner.gate(a.id).complete();
    await done;
    expect(finishedIds, contains(a.id));
  });
}
