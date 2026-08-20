import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../providers/app_providers.dart';
import 'queue_service.dart';

/// 监视文件夹流水线的一对「视频 + 同名字幕」。
class WatchPair {
  final String video;
  final String subtitle;

  const WatchPair({required this.video, required this.subtitle});
}

/// 字幕扩展名优先级：同名多字幕时 srt > ass > ssa > vtt > sub。
const Map<String, int> _kSubPriority = {
  'srt': 0,
  'ass': 1,
  'ssa': 2,
  'vtt': 3,
  'sub': 4,
};

/// 监视文件夹（v2.0 无人值守流水线）：
/// - 规则：监视目录**顶层**出现「新视频 + 同名字幕」（basename 去扩展名一致）
///   → 双方文件稳定（拷贝完成，大小在一个静默期内不变）→ 自动创建烧录任务
///   输出到输出目录（文件名保持视频原名与容器扩展名）；
/// - 存量不处理：启动时刻目录里已配对的文件只登记基线，不烧录；
/// - 防重复：pair 级去重（会话内）；跨重启靠「输出目录已存在同名产物」跳过；
/// - ass/ssa 字幕走 ass 滤镜保留原样式，其余走 subtitles 滤镜。
class WatchFolderService {
  /// 生产构造：默认接入全局队列。
  WatchFolderService._()
      : _enqueueFn = null,
        _startQueueFn = null,
        settle = const Duration(seconds: 2),
        rescanPeriod = const Duration(seconds: 10);

  static final WatchFolderService instance = WatchFolderService._();

  /// 测试注入口：替换入队 / 启动队列回调，并缩短时间参数。
  WatchFolderService.forTesting({
    void Function(TaskType type, String title, Map<String, String> params)?
        enqueue,
    void Function()? startQueue,
    this.settle = const Duration(milliseconds: 150),
    this.rescanPeriod = const Duration(milliseconds: 100),
  })  : _enqueueFn = enqueue,
        _startQueueFn = startQueue;

  final void Function(TaskType type, String title, Map<String, String> params)?
      _enqueueFn;
  final void Function()? _startQueueFn;

  /// 静默期：事件 debounce 与文件稳定性采样间隔（等待拷贝完成）。
  final Duration settle;

  /// 兜底重扫周期（补事件丢失/慢拷贝重试）。
  final Duration rescanPeriod;

  StreamSubscription<FileSystemEvent>? _sub;
  Timer? _debounce;
  Timer? _rescanTimer;
  final Set<String> _processed = <String>{};
  String? _watchDir;
  String? _outputDir;
  bool _scanning = false;

  bool get isWatching => _sub != null;
  String? get watchDir => _watchDir;
  String? get outputDir => _outputDir;

  // ─────────────────── 纯逻辑（可测） ───────────────────

  /// 从一组文件路径中找出「视频 + 同名字幕」配对。
  /// 同名多字幕按 srt > ass > ssa > vtt > sub 取优先级最高者。
  static List<WatchPair> findPairs(List<String> files) {
    final videos = <String, String>{};
    final subs = <String, List<MapEntry<String, int>>>{};
    for (final f in files) {
      final base = p.basenameWithoutExtension(f).toLowerCase();
      final ext = p.extension(f).toLowerCase().replaceFirst('.', '');
      if (AppConstants.videoExtensions.contains(ext)) {
        videos[base] = f;
      } else if (_kSubPriority.containsKey(ext)) {
        subs.putIfAbsent(base, () => []).add(MapEntry(f, _kSubPriority[ext]!));
      }
    }
    final result = <WatchPair>[];
    final bases = videos.keys.toList()..sort();
    for (final b in bases) {
      final cand = subs[b];
      if (cand == null || cand.isEmpty) continue;
      cand.sort((a, c) => a.value.compareTo(c.value));
      result.add(WatchPair(video: videos[b]!, subtitle: cand.first.key));
    }
    return result;
  }

  /// pair 去重键：路径大小写与分隔符规范化。
  static String pairKey(WatchPair pair) =>
      '${_norm(pair.video)}|${_norm(pair.subtitle)}';

  static String _norm(String path) =>
      path.replaceAll('/', '\\').toLowerCase();

  /// 输出路径 = 输出目录 + 视频原文件名（保持容器扩展名）。
  static String outputPathFor(String video, String outputDir) =>
      p.join(outputDir, p.basename(video));

  /// ass/ssa 走 ass 滤镜保留原样式；其余（srt/vtt/sub）走 subtitles 滤镜。
  static bool useAssFor(String subtitlePath) {
    final ext = p.extension(subtitlePath).toLowerCase();
    return ext == '.ass' || ext == '.ssa';
  }

  // ─────────────────── 生命周期 ───────────────────

  /// 开始监视。目录已存在的配对只登记基线（存量不烧录），之后新到达的
  /// 配对稳定后自动入队。
  Future<void> start({
    required String watchDir,
    required String outputDir,
  }) async {
    await stop();
    final dir = Directory(watchDir);
    if (!dir.existsSync()) return;
    _watchDir = watchDir;
    _outputDir = outputDir;
    await Directory(_outputDir!).create(recursive: true);
    // 基线登记：存量 pair 视为「已见」，不参与自动烧录
    for (final pair in findPairs(_listTopFiles(dir))) {
      _processed.add(pairKey(pair));
    }
    _sub = dir.watch().listen(_onEvent, onError: (_) {});
    _rescanTimer = Timer.periodic(rescanPeriod, (_) => _scan());
    _scan();
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
    _rescanTimer?.cancel();
    _rescanTimer = null;
    _watchDir = null;
    _outputDir = null;
    _scanning = false;
  }

  /// 按 SettingsProvider 当前配置同步（main 启动与设置变更时调用，幂等）。
  void syncFromSettings() {
    final s = SettingsProvider.instance;
    final dir = s.watchDir.trim();
    if (!s.watchEnabled || dir.isEmpty) {
      if (isWatching) unawaited(stop());
      return;
    }
    final out = s.watchOutputDir.trim().isNotEmpty
        ? s.watchOutputDir.trim()
        : p.join(dir, 'burned');
    if (isWatching && _watchDir == dir && _outputDir == out) return;
    unawaited(start(watchDir: dir, outputDir: out));
  }

  // ─────────────────── 内部 ───────────────────

  static List<String> _listTopFiles(Directory dir) => [
        for (final e in dir.listSync(followLinks: false))
          if (e is File) e.path,
      ];

  void _onEvent(FileSystemEvent event) {
    if (_sub == null) return;
    _debounce?.cancel();
    _debounce = Timer(settle, _scan);
  }

  Future<void> _scan() async {
    if (_scanning || _sub == null) return;
    _scanning = true;
    try {
      final dir = _watchDir;
      final out = _outputDir;
      if (dir == null || out == null) return;
      final d = Directory(dir);
      if (!d.existsSync()) return;
      for (final pair in findPairs(_listTopFiles(d))) {
        final key = pairKey(pair);
        if (_processed.contains(key)) continue;
        final outPath = outputPathFor(pair.video, out);
        // 跨重启防重复：输出产物已存在 → 视为已烧录
        if (File(outPath).existsSync()) {
          _processed.add(key);
          continue;
        }
        // 拷贝未完成的文件等待下一轮（事件/兜底重扫驱动重试）
        if (!await _isStable(pair.video)) continue;
        if (!await _isStable(pair.subtitle)) continue;
        _processed.add(key);
        _enqueueBurn(pair, outPath);
      }
    } finally {
      _scanning = false;
    }
  }

  /// 文件稳定性：两次采样（间隔 [settle]）大小一致才算拷贝完成。
  Future<bool> _isStable(String path) async {
    final f = File(path);
    if (!f.existsSync()) return false;
    final first = f.lengthSync();
    await Future<void>.delayed(settle);
    if (!f.existsSync()) return false;
    return f.lengthSync() == first;
  }

  void _enqueueBurn(WatchPair pair, String outPath) {
    final title = '自动烧录 ${p.basename(pair.video)}';
    final params = <String, String>{
      TaskParams.videoPath: pair.video,
      TaskParams.subtitlePath: pair.subtitle,
      TaskParams.outputPath: outPath,
      TaskParams.useAssFilter: '${useAssFor(pair.subtitle)}',
    };
    final fn = _enqueueFn;
    if (fn != null) {
      fn(TaskType.burn, title, params);
      _startQueueFn?.call();
      return;
    }
    QueueService.instance.addTask(
      type: TaskType.burn,
      title: title,
      params: params,
    );
    QueueService.instance.start();
  }
}
