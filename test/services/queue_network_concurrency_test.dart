import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_run_result.dart';
import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';
import 'package:subtitle_studio_pro/services/task_runner.dart';

/// v2.2.1 网络车道并发可调：
/// - 并发 1（默认）：网络任务串行（既有行为不变）
/// - 并发 2：两个 AI 翻译任务同时 running
/// - 本地车道不受并发设置影响，保持串行
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

  tearDown(() async {
    await SettingsProvider.instance.setAiNetworkParams(concurrency: 1);
  });

  test('并发 1（默认）：网络任务串行', () async {
    final a = queue.addTask(type: TaskType.subtitleTranslate, title: 'A');
    final b = queue.addTask(type: TaskType.subtitleTranslate, title: 'B');

    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);
    expect(b.status, TaskStatus.pending, reason: '并发 1 时网络车道仍串行');

    runner.gate(a.id).complete();
    expect(await _until(() => b.status == TaskStatus.running), isTrue);
    runner.gate(b.id).complete();
    await done;
    expect(b.status, TaskStatus.completed);
  });

  test('并发 2：两个网络任务同时 running', () async {
    await SettingsProvider.instance.setAiNetworkParams(concurrency: 2);
    final a = queue.addTask(type: TaskType.subtitleTranslate, title: 'A');
    final b = queue.addTask(type: TaskType.subtitleTranslate, title: 'B');

    final done = queue.start();
    expect(
      await _until(() =>
          a.status == TaskStatus.running && b.status == TaskStatus.running),
      isTrue,
      reason: '并发 2 时网络车道两个 worker 同时执行',
    );

    runner.gate(a.id).complete();
    runner.gate(b.id).complete();
    await done;
    expect(a.status, TaskStatus.completed);
    expect(b.status, TaskStatus.completed);
  });

  test('并发 2：本地任务仍串行，不随网络并发变化', () async {
    await SettingsProvider.instance.setAiNetworkParams(concurrency: 2);
    final a = queue.addTask(type: TaskType.burn, title: 'A');
    final b = queue.addTask(type: TaskType.transcode, title: 'B');

    final done = queue.start();
    expect(await _until(() => a.status == TaskStatus.running), isTrue);
    expect(b.status, TaskStatus.pending, reason: '本地车道并发恒为 1');

    runner.gate(a.id).complete();
    expect(await _until(() => b.status == TaskStatus.running), isTrue);
    runner.gate(b.id).complete();
    await done;
  });
}
