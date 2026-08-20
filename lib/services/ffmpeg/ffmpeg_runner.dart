import 'dart:typed_data';

import '../../models/task_run_result.dart';

/// ── FFmpeg 执行抽象层 ──
/// 定义执行接口：FfmpegRunner。
/// 当前实现（Windows 桌面）：ffmpeg_runner_process.dart 中的
/// FfmpegProcessRunner（调用系统 FFmpeg 可执行文件，子进程）。
///
/// 通用类型 [TaskRunResult] / [TaskOutputFile] / [CancelToken]
/// 已移至 `lib/models/task_run_result.dart`，供所有任务 runner 复用。
export '../../models/task_run_result.dart';

/// 执行进度（来自 ffmpeg 统计/日志解析）。
class FfmpegProgress {
  final Duration time;
  final int frame;
  final double fps;

  /// 实时速度倍率（1.0 = 实时，>1 快于实时）
  final double speed;
  final int sizeBytes;

  const FfmpegProgress({
    required this.time,
    this.frame = 0,
    this.fps = 0,
    this.speed = 0,
    this.sizeBytes = 0,
  });

  /// 相对 [total] 的完成度（0..1），total 未知时为 null。
  double? fractionOf(Duration? total) {
    if (total == null || total.inMilliseconds <= 0) return null;
    final f = time.inMilliseconds / total.inMilliseconds;
    return f.clamp(0.0, 1.0);
  }
}

/// 一次 FFmpeg 执行请求。
class FfmpegRunRequest {
  /// 完整命令行参数（不含 `-progress` 等运行期附加项）
  final List<String> arguments;

  /// 总时长（用于计算百分比；来自 ffprobe 预探测）
  final Duration? totalDuration;

  /// 是否追加 `-progress pipe:1 -nostats`（原生平台可用）
  final bool progressOutput;

  /// Web 专用：输入路径 → 内存字节（runner 会把路径改写为文件名）
  final Map<String, Uint8List> inputFiles;

  /// Web 专用：期望的输出路径列表（runner 据此从内存读回结果）
  final List<String> expectedOutputs;

  const FfmpegRunRequest({
    required this.arguments,
    this.totalDuration,
    this.progressOutput = true,
    this.inputFiles = const {},
    this.expectedOutputs = const [],
  });
}

/// 平台无关的 FFmpeg 执行器接口。
abstract class FfmpegRunner {
  /// 实现名称（用于展示）
  String get platformName;

  /// 是否为 Web 实现
  bool get isWeb;

  /// 是否支持 `-progress pipe:1`（wasm 不支持）
  bool get supportsProgressOutput;

  /// 初始化（加载库/注册回调）。幂等。
  Future<void> init();

  /// FFmpeg 版本号。
  Future<String> getVersion();

  /// 探测媒体信息，返回通用 Map；失败返回 null。
  /// 键：format, durationMs, bitrate, size, streams[List<Map>]
  /// 流键：type, index, codec, width, height, fps, bitrate,
  ///       sampleRate, channelLayout, language, title
  Future<Map<String, dynamic>?> probe(String path);

  /// 执行命令。[onProgress]/[onLog] 实时回调；
  /// [cancelToken] 非空时支持取消。
  Future<TaskRunResult> run(
    FfmpegRunRequest request, {
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  });

  Future<void> dispose();

  /// FFmpeg 是否可用（检测通过）。桌面 Process 实现会真实检测；
  /// 其他实现默认 true。
  bool get isAvailable => true;

  /// 初始化失败时的错误说明（不可用时非空）。
  String? get initError => null;

  /// FFmpeg 来源说明（捆绑版 / 自定义路径 / 系统 PATH）。
  String? get sourceLabel => null;

  /// FFmpeg 支持的编码器名集合（如 h264_nvenc），探测并缓存。
  Future<Set<String>> availableEncoders() async => const {};
}

/// 把 FFmpeg 常见错误日志翻译成友好提示（两个 Runner 共用）。
String friendlyFfmpegError(String log) {
  final lower = log.toLowerCase();
  if (lower.contains('requires libass') ||
      lower.contains('filter subtitles') ||
      lower.contains('filter ass')) {
    return '当前 FFmpeg 构建缺少 libass，无法烧录字幕。\n'
        '请安装含 libass 的完整 FFmpeg（如 gyan.dev 的 full 版），'
        '并在「设置」中指定其路径。';
  }
  if (lower.contains('no such file') || lower.contains('cannot open')) {
    return '找不到输入文件（路径不存在或不可读）。';
  }
  if (lower.contains('invalid data') || lower.contains('moov atom not found')) {
    return '输入文件损坏或不是有效的视频文件。';
  }
  if (lower.contains('no space left')) {
    return '存储空间不足，请清理后重试。';
  }
  if (lower.contains('permission denied')) {
    return '没有写入权限，请检查输出目录。';
  }
  if (lower.contains('unknown encoder')) {
    return '当前 FFmpeg 构建不支持所选编码器。';
  }
  final lines = log.split('\n').where((l) => l.trim().isNotEmpty).toList();
  final tail = lines.length <= 6 ? lines : lines.sublist(lines.length - 6);
  return 'FFmpeg 执行失败，最后日志：\n${tail.join('\n')}';
}
