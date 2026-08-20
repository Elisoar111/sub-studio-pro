import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_run_result.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';
import 'package:subtitle_studio_pro/services/task_runner.dart';

/// 队列智能调度（v1.1 P2）：网络型任务（AI 翻译）与本地子进程任务并行，
/// 本地 CPU 密集任务保持串行。
///
/// 用门闩式 FakeRunner 精确控制每个任务的完成时机：
/// - 断言「并行」：本地任务与网络任务可同时处于 running；
/// - 断言「串行」：两个本地任务，第二个在第一个终态前必须保持 pending。
class _GateRunner extends TaskRunner {
  final Map<String, Completer<void>> gates = {};
  final List<String> started = [];

  Completer<void> gate(String id) => gates.putIfAbsent(id, Completer<void>.new);

  @override
  Future<TaskRunResult?> run({
    required QueueTask task,
    required FfmpegService ffmpeg,
    required CancelToken token,
    required void Function() notify,
  }) async {
    started.add(task.type.name);
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
    // _runOne 要求 ffmpeg 非空；FakeRunner 不实际使用它。
    // create() 返回单例，重复调用无额外开销。
    ffmpeg = await FfmpegService.create();
  });

  setUp(() {
    runner = _GateRunner();
    queue = QueueService.forTesting(runner: runner);
    queue.init(ffmpeg: ffmpeg);
  });

  test('网络任务与本地任务并行执行', () async {
    final local = queue.addTask(type: TaskType.burn, title: '本地烧录');
    final net = queue.addTask(type: TaskType.subtitleTranslate, title: 'AI 翻译');

    final done = queue.start();
    // 旧串行实现：本地任务不放手，网络任务永远进不了 running
    expect(
      await _until(() =>
          local.status == TaskStatus.running &&
          net.status == TaskStatus.running),
      isTrue,
      reason: '两条车道的任务应同时处于 running（并行调度）',
    );

    runner.gate(local.id).complete();
    runner.gate(net.id).complete();
    await done;
    expect(local.status, TaskStatus.completed);
    expect(net.status, TaskStatus.completed);
  });

  test('本地任务之间保持串行', () async {
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    final b = queue.addTask(type: TaskType.transcode, title: 'B');

    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);
    expect(b.status, TaskStatus.pending, reason: '前一个本地任务未结束，B 不得启动');

    runner.gate(a.id).complete();
    expect(await _until(() => b.status == TaskStatus.running), isTrue);
    expect(a.status, TaskStatus.completed);

    runner.gate(b.id).complete();
    await done;
    expect(b.status, TaskStatus.completed);
  });

  test('网络任务之间保持串行', () async {
    final a = queue.addTask(type: TaskType.subtitleTranslate, title: 'A');
    final b = queue.addTask(type: TaskType.subtitleTranslate, title: 'B');

    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);
    expect(b.status, TaskStatus.pending, reason: '网络车道内串行，避免 API 限流');

    runner.gate(a.id).complete();
    expect(await _until(() => b.status == TaskStatus.running), isTrue);

    runner.gate(b.id).complete();
    await done;
    expect(b.status, TaskStatus.completed);
  });

  test('本地车道跑批期间新入队的任务会被接续执行', () async {
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);

    // 队列运行中追加新任务（模拟用户继续添加）
    final b = queue.addTask(type: TaskType.mux, title: 'B');
    runner.gate(a.id).complete();

    expect(await _until(() => b.status == TaskStatus.running), isTrue,
        reason: '车道空了但调度循环未退出，应接续新 pending 任务');
    runner.gate(b.id).complete();
    await done;
    expect(b.status, TaskStatus.completed);
  });
}
