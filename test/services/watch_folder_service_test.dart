import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_params.dart';
import 'package:subtitle_studio_pro/services/watch_folder_service.dart';

/// 监视文件夹（v2.0 自动化流水线）：
/// 规则 = 监视目录顶层出现「新视频 + 同名字幕」→ 文件稳定（拷贝完成）后
/// 自动创建烧录任务输出到输出目录。
///
/// 纯逻辑（findPairs / pairKey / outputPathFor / useAssFor）与
/// 服务流水线（事件触发扫描、存量不处理、防重复、稳定性等待）分层验证；
/// 服务测试注入回调记录器 + 缩短 settle/poll 参数，不依赖真实 FFmpeg。
class _Recorder {
  final List<Map<String, String>> paramList = [];
  final List<String> titles = [];
  int startCalls = 0;

  void enqueue(TaskType type, String title, Map<String, String> params) {
    titles.add(title);
    paramList.add(params);
  }
}

Future<bool> _until(
  bool Function() cond, [
  Duration timeout = const Duration(seconds: 8),
]) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) return false;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('findPairs 配对规则（纯逻辑）', () {
    test('视频 + 同名字幕（去扩展名一致）配对成功', () {
      final pairs = WatchFolderService.findPairs([
        r'D:\watch\EP01.mkv',
        r'D:\watch\EP01.ass',
      ]);
      expect(pairs, hasLength(1));
      expect(pairs.first.video, r'D:\watch\EP01.mkv');
      expect(pairs.first.subtitle, r'D:\watch\EP01.ass');
    });

    test('扩展名大小写不敏感；多个字幕按 srt > ass > ssa > vtt > sub 优先', () {
      final pairs = WatchFolderService.findPairs([
        r'D:\watch\EP02.MKV',
        r'D:\watch\EP02.ASS',
        r'D:\watch\EP02.srt',
      ]);
      expect(pairs, hasLength(1));
      expect(pairs.first.subtitle, r'D:\watch\EP02.srt');
    });

    test('无字幕的视频不配对；字幕文件不与自身配对；孤立字幕忽略', () {
      expect(WatchFolderService.findPairs([r'D:\watch\EP03.mp4']), isEmpty);
      expect(WatchFolderService.findPairs([r'D:\watch\EP04.srt']), isEmpty);
    });

    test('多个视频各自配对同名字幕', () {
      final pairs = WatchFolderService.findPairs([
        r'D:\watch\a.mkv',
        r'D:\watch\a.ass',
        r'D:\watch\b.mp4',
        r'D:\watch\b.srt',
      ]);
      expect(pairs, hasLength(2));
    });

    // v2.1.1：同名不同扩展名视频（movie.mp4 + movie.mkv）语义不明，
    // 自动烧录不应静默猜一个 —— 跳过该基名不配对。
    test('同名多视频（基名冲突）跳过配对，不静默选择', () {
      final pairs = WatchFolderService.findPairs([
        r'D:\watch\movie.mp4',
        r'D:\watch\movie.mkv',
        r'D:\watch\movie.srt',
      ]);
      expect(pairs, isEmpty,
          reason: '基名冲突时应跳过，避免烧错视频或依赖枚举顺序');
    });
  });

  group('路径与滤镜决策（纯逻辑）', () {
    test('pairKey 规范化（大小写/分隔符不敏感）', () {
      final a = WatchFolderService.pairKey(const WatchPair(
          video: r'D:\W\Ep01.MKV', subtitle: r'D:\W\EP01.ass'));
      final b = WatchFolderService.pairKey(const WatchPair(
          video: r'd:\w\ep01.mkv', subtitle: r'd:\w\ep01.ASS'));
      expect(a, b);
    });

    test('输出路径 = 输出目录 + 视频原文件名（保持容器扩展名）', () {
      expect(
        WatchFolderService.outputPathFor(r'D:\watch\EP01.mkv', r'D:\out'),
        equals(r'D:\out\EP01.mkv'),
      );
    });

    test('useAssFor：ass/ssa 走 ass 滤镜，其余走 subtitles 滤镜', () {
      expect(WatchFolderService.useAssFor('a.ass'), isTrue);
      expect(WatchFolderService.useAssFor('a.ssa'), isTrue);
      expect(WatchFolderService.useAssFor('a.ASS'), isTrue);
      expect(WatchFolderService.useAssFor('a.srt'), isFalse);
      expect(WatchFolderService.useAssFor('a.vtt'), isFalse);
    });
  });

  group('服务流水线（Recorder + 临时目录）', () {
    late Directory tmp;
    late Directory watchDir;
    late Directory outDir;
    late _Recorder rec;
    late WatchFolderService svc;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('watch_folder_test');
      watchDir = Directory('${tmp.path}\\watch');
      outDir = Directory('${tmp.path}\\out');
      await watchDir.create();
      await outDir.create();
      rec = _Recorder();
      svc = WatchFolderService.forTesting(
        enqueue: rec.enqueue,
        startQueue: () => rec.startCalls++,
        settle: const Duration(milliseconds: 150),
        rescanPeriod: const Duration(milliseconds: 100),
      );
    });

    tearDown(() async {
      await svc.stop();
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('启动基线：存量文件只登记不烧录（无人值守只处理新到达）', () async {
      File('${watchDir.path}\\old.mkv').writeAsBytesSync(List.filled(8, 1));
      File('${watchDir.path}\\old.ass').writeAsBytesSync(List.filled(8, 1));
      await svc.start(watchDir: watchDir.path, outputDir: outDir.path);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(rec.paramList, isEmpty, reason: '存量 pair 不应自动烧录');
    });

    test('新视频 + 同名字幕到达 → 稳定后自动入队烧录任务并启动队列', () async {
      await svc.start(watchDir: watchDir.path, outputDir: outDir.path);

      File('${watchDir.path}\\EP01.ass').writeAsBytesSync(List.filled(4, 1));
      File('${watchDir.path}\\EP01.mkv').writeAsBytesSync(List.filled(16, 1));

      expect(
        await _until(() => rec.paramList.length == 1),
        isTrue,
        reason: '应在文件稳定后自动创建烧录任务',
      );
      expect(
          rec.paramList.first[TaskParams.videoPath],
          '${watchDir.path}\\EP01.mkv');
      expect(rec.paramList.first[TaskParams.subtitlePath],
          '${watchDir.path}\\EP01.ass');
      expect(
          rec.paramList.first[TaskParams.outputPath], '${outDir.path}\\EP01.mkv');
      expect(rec.paramList.first[TaskParams.useAssFilter], 'true');
      expect(rec.startCalls, greaterThan(0), reason: '流水线需自动启动队列');
      expect(rec.titles.first, contains('EP01'));
    });

    test('拷贝未完成（大小仍在增长）时不入队，写完后才入队', () async {
      await svc.start(watchDir: watchDir.path, outputDir: outDir.path);

      final video = File('${watchDir.path}\\EP02.mkv');
      final sub = File('${watchDir.path}\\EP02.srt');
      sub.writeAsBytesSync(List.filled(4, 1));
      // 模拟大文件缓慢写入：先写一小段，稍后追加
      final raf = video.openSync(mode: FileMode.write);
      raf.writeFromSync(List.filled(8, 1));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(rec.paramList, isEmpty, reason: '视频仍在写入时不得入队');

      raf.writeFromSync(List.filled(8, 1));
      await raf.flush();
      raf.closeSync();

      expect(
        await _until(() => rec.paramList.length == 1),
        isTrue,
        reason: '写入完成后应入队',
      );
      expect(rec.paramList.first[TaskParams.useAssFilter], 'false');
    });

    test('同一 pair 只烧录一次（事件重复触发不重复入队）', () async {
      await svc.start(watchDir: watchDir.path, outputDir: outDir.path);
      File('${watchDir.path}\\EP03.mp4').writeAsBytesSync(List.filled(8, 1));
      File('${watchDir.path}\\EP03.ass').writeAsBytesSync(List.filled(4, 1));
      expect(await _until(() => rec.paramList.length == 1), isTrue);

      // 触发更多事件（再写一次字幕内容）
      File('${watchDir.path}\\EP03.ass').writeAsBytesSync(List.filled(6, 1));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(rec.paramList, hasLength(1), reason: 'pair 已处理过，不得重复烧录');
    });

    test('输出目录已存在同名文件时跳过（跨重启防重复语义）', () async {
      File('${outDir.path}\\EP04.mkv').writeAsBytesSync(List.filled(4, 1));
      await svc.start(watchDir: watchDir.path, outputDir: outDir.path);
      // 基线登记后模拟「输出已存在」的新 pair
      File('${watchDir.path}\\EP04.mkv').writeAsBytesSync(List.filled(8, 1));
      File('${watchDir.path}\\EP04.srt').writeAsBytesSync(List.filled(4, 1));
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(rec.paramList, isEmpty, reason: '输出已存在同名产物应跳过');
    });

    test('stop 后不再响应新文件', () async {
      await svc.start(watchDir: watchDir.path, outputDir: outDir.path);
      await svc.stop();
      File('${watchDir.path}\\EP05.mkv').writeAsBytesSync(List.filled(8, 1));
      File('${watchDir.path}\\EP05.ass').writeAsBytesSync(List.filled(4, 1));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(rec.paramList, isEmpty);
      expect(svc.isWatching, isFalse);
    });
  });
}
