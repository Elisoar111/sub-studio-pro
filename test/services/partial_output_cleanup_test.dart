import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_params.dart';
import 'package:subtitle_studio_pro/models/task_run_result.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';
import 'package:subtitle_studio_pro/services/task_runner.dart';

/// 半成品输出清理（v2.1.1）：
/// 任务以 cancelled / failed 终态结束且输出文件是「本任务运行期间写入」的
/// （启动前不存在，或 mtime 晚于启动前快照）→ 删除半成品；
/// 任务前就存在且未被本任务触碰的旧文件 → 保留；
/// 成功任务的产物 → 保留。
///
/// 用受控 fake runner 决定「是否写输出 / 返回什么结果」。
class _PartialRunner extends TaskRunner {
  /// 模拟子进程写了（部分）输出文件。
  bool writePartial = false;
  bool returnCancelled = false;
  bool returnSuccess = false;

  @override
  Future<TaskRunResult?> run({
    required QueueTask task,
    required FfmpegService ffmpeg,
    required CancelToken token,
    required void Function() notify,
  }) async {
    if (writePartial) {
      final out = task.params[TaskParams.outputPath]!;
      File(out).writeAsStringSync('partial output');
    }
    if (returnCancelled) {
      return const TaskRunResult(success: false, cancelled: true);
    }
    if (returnSuccess) {
      final out = task.params[TaskParams.outputPath]!;
      return TaskRunResult(
        success: true,
        outputs: [TaskOutputFile(name: p.basename(out), path: out)],
      );
    }
    return const TaskRunResult(success: false, error: 'boom');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late QueueService queue;
  late _PartialRunner runner;
  late FfmpegService ffmpeg;

  setUpAll(() async {
    ffmpeg = await FfmpegService.create();
  });

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('partial_cleanup');
    runner = _PartialRunner();
    queue = QueueService.forTesting(runner: runner);
    queue.init(ffmpeg: ffmpeg, onTaskFinished: (_) {});
  });

  tearDown(() async {
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  String outPath(String name) => p.join(tempRoot.path, name);

  Future<QueueTask> runOne({required Map<String, String> params}) async {
    final task = queue.addTask(
      type: TaskType.burn,
      title: 'T',
      params: params,
    );
    await queue.start();
    return task;
  }

  test('失败任务写入的半成品输出被删除', () async {
    final out = outPath('a.mp4');
    runner.writePartial = true;

    final task = await runOne(params: {TaskParams.outputPath: out});

    expect(task.status, TaskStatus.failed);
    expect(File(out).existsSync(), isFalse,
        reason: '失败任务的半成品输出应被清理');
  });

  test('取消任务写入的半成品输出被删除', () async {
    final out = outPath('b.mp4');
    runner.writePartial = true;
    runner.returnCancelled = true;

    final task = await runOne(params: {TaskParams.outputPath: out});

    expect(task.status, TaskStatus.cancelled);
    expect(File(out).existsSync(), isFalse,
        reason: '取消任务的半成品输出应被清理');
  });

  test('任务前就存在的旧文件（未被本任务触碰）保留', () async {
    final out = outPath('c.mp4');
    final f = File(out)..writeAsStringSync('old content');
    // mtime 拨回过去，确保与任务启动后写入可区分
    f.setLastModifiedSync(DateTime(2020, 1, 1));

    final task = await runOne(params: {TaskParams.outputPath: out});

    expect(task.status, TaskStatus.failed);
    expect(File(out).existsSync(), isTrue,
        reason: '任务未触碰的既有文件不应被误删');
    expect(f.readAsStringSync(), 'old content');
  });

  test('旧文件被本任务重写后失败 → 半成品删除', () async {
    final out = outPath('d.mp4');
    final f = File(out)..writeAsStringSync('old content');
    f.setLastModifiedSync(DateTime(2020, 1, 1));
    runner.writePartial = true;

    final task = await runOne(params: {TaskParams.outputPath: out});

    expect(task.status, TaskStatus.failed);
    expect(File(out).existsSync(), isFalse,
        reason: '被本任务截断/重写的半成品应删除（旧内容已不可恢复）');
  });

  test('成功任务的产物保留（防过度清理）', () async {
    final out = outPath('e.mp4');
    runner.writePartial = true;
    runner.returnSuccess = true;

    final task = await runOne(params: {TaskParams.outputPath: out});

    expect(task.status, TaskStatus.completed);
    expect(File(out).existsSync(), isTrue, reason: '成功产物不应被清理');
  });

  test('whisper 任务：输出目录本身不被删除', () async {
    final dir = Directory(p.join(tempRoot.path, 'wavs'))..createSync();
    // whisper 的 outputPath 语义是目录
    final task = queue.addTask(
      type: TaskType.whisper,
      title: 'W',
      params: {
        TaskParams.videoPath: p.join(tempRoot.path, 'in.mp4'),
        TaskParams.outputPath: dir.path,
        TaskParams.whisperModel: 'small',
        TaskParams.whisperFormat: 'srt',
      },
    );
    await queue.start();

    expect(task.status, TaskStatus.failed);
    expect(dir.existsSync(), isTrue, reason: '输出目录不应被当作半成品文件删除');
  });
}
