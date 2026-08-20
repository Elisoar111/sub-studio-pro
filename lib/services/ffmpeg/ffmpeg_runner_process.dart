import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';
import 'ffmpeg_runner.dart';
import 'progress_parser.dart';

/// Windows 桌面执行器：调用 FFmpeg / FFprobe 可执行文件（子进程）。
///
/// 查找顺序（P0 免安装）：
/// 1. 用户自定义路径（设置中手动指定）；
/// 2. 捆绑版（发布目录 `resources/ffmpeg/`，随 exe 分发）；
/// 3. 系统 PATH。
///
/// 进度：`-progress pipe:1` 输出到子进程 stdout（key=value 行），
/// 由 [ProgressLineParser] 解析；日志与错误走 stderr。
/// 取消：直接向子进程发送终止信号（Windows 上为 TerminateProcess）。
class FfmpegProcessRunner implements FfmpegRunner {
  FfmpegProcessRunner();

  String? _customFfmpeg;
  String? _customFfprobe;
  bool _available = false;
  String? _version;
  String? _initError;
  String? _sourceLabel;
  String? _resolvedPath;

  /// 捆绑 FFmpeg 目录（发布时随 exe 分发：<exe目录>/resources/ffmpeg/）。
  Directory? _bundledDir;

  /// 当前使用的 ffmpeg 可执行文件路径：自定义 → 捆绑 → 系统 PATH。
  String get _ffmpegBin =>
      _customFfmpeg ?? _bundledFfmpeg ?? (Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg');

  String get _ffprobeBin =>
      _customFfprobe ?? _bundledFfprobe ?? (Platform.isWindows ? 'ffprobe.exe' : 'ffprobe');

  String? get _bundledFfmpeg {
    final d = _resolveBundledDir();
    return d == null ? null : p.join(d.path, 'ffmpeg.exe');
  }

  String? get _bundledFfprobe {
    final d = _resolveBundledDir();
    return d == null ? null : p.join(d.path, 'ffprobe.exe');
  }

  Directory? _resolveBundledDir() {
    if (_bundledDir != null) return _bundledDir;
    try {
      // Platform.resolvedExecutable = 发布目录下的 exe（如 .../Release/subtitle_studio_pro.exe）
      final exeDir = File(Platform.resolvedExecutable).parent;
      final dir = Directory(p.join(exeDir.path, 'resources', 'ffmpeg'));
      if (dir.existsSync() &&
          File(p.join(dir.path, 'ffmpeg.exe')).existsSync() &&
          File(p.join(dir.path, 'ffprobe.exe')).existsSync()) {
        _bundledDir = dir;
      }
    } catch (_) {}
    return _bundledDir;
  }

  @override
  String get platformName => 'system-ffmpeg';

  @override
  bool get isWeb => false;

  @override
  bool get supportsProgressOutput => true;

  /// FFmpeg 是否检测通过。
  @override
  bool get isAvailable => _available;

  /// 初始化失败时的错误说明（含安装指引）。
  @override
  String? get initError => _initError;

  /// FFmpeg 来源（捆绑版 / 自定义路径 / 系统 PATH）。
  @override
  String? get sourceLabel => _sourceLabel;

  /// 当前生效的 ffmpeg 完整路径（PATH 命中时经 where 解析；不可用为 null）。
  @override
  String? get resolvedBinPath => _available ? _resolvedPath : null;

  /// 配置自定义可执行文件路径（设置页保存后调用）。
  /// 传 null / 空串表示回退到「捆绑版 → 系统 PATH」。配置后需再次调用 [init] 重新检测。
  void configure({String? ffmpegPath, String? ffprobePath}) {
    _customFfmpeg = (ffmpegPath == null || ffmpegPath.isEmpty) ? null : ffmpegPath;
    _customFfprobe =
        (ffprobePath == null || ffprobePath.isEmpty) ? null : ffprobePath;
    _available = false;
    _initError = null;
    _version = null;
    _sourceLabel = null;
    _resolvedPath = null;
    // 换可执行文件后编码器列表可能不同（如指向带 NVENC 的构建），
    // 旧缓存（可能是在不可用状态下缓存的空集合）必须失效
    _encodersCache = null;
  }

  /// 检测 FFmpeg 是否可用。**不抛异常**：未安装时记录错误信息，
  /// 由 [run] / [probe] 返回友好提示，避免应用启动即崩溃。
  @override
  Future<void> init() async {
    if (_available || _initError != null) return;
    try {
      _version = await _detectVersion();
      _available = true;
      _sourceLabel = _customFfmpeg != null
          ? '自定义路径'
          : _bundledFfmpeg != null
              ? '捆绑版'
              : '系统 PATH';
      _resolvedPath = _customFfmpeg ?? _bundledFfmpeg ?? await _resolveFromPath();
      Logger.instance.log(
          '检测到 FFmpeg $_version（来源：$_sourceLabel）', tag: 'FFMPEG');
    } catch (e) {
      _initError = '未检测到可用的 FFmpeg。请安装 FFmpeg 并加入 PATH，'
          '或在「设置」中手动指定 ffmpeg.exe / ffprobe.exe 的路径。\n'
          '下载（选 full 版，含 libass 可烧录字幕）：'
          'https://www.gyan.dev/ffmpeg/builds/ \n原始错误：$e';
      Logger.instance.error(_initError!);
    }
  }

  @override
  Future<String> getVersion() async {
    if (_version != null) return _version!;
    try {
      _version = await _detectVersion();
      _available = true;
    } catch (_) {
      return '未检测到 FFmpeg';
    }
    return _version!;
  }

  Future<String> _detectVersion() async {
    final r = await Process.run(_ffmpegBin, ['-version'], stdoutEncoding: utf8);
    if (r.exitCode != 0) {
      throw StateError('ffmpeg -version 退出码 ${r.exitCode}');
    }
    final first = (r.stdout as String).split('\n').first.trim();
    final m = RegExp(r'ffmpeg version (\S+)').firstMatch(first);
    return m?.group(1) ?? first;
  }

  /// PATH 命中时解析完整路径（where.exe）；解析失败回退可执行名。
  Future<String> _resolveFromPath() async {
    final bin = Platform.isWindows ? 'ffmpeg.exe' : 'ffmpeg';
    try {
      final r = await Process.run(
        'where.exe',
        [bin],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (r.exitCode == 0) {
        final first = (r.stdout as String).split('\n').first.trim();
        if (first.isNotEmpty) return first;
      }
    } catch (_) {}
    return bin;
  }

  // ───────────────────────── 探测 ─────────────────────────

  @override
  Future<Map<String, dynamic>?> probe(String path) async {
    if (!_available) return null;
    Process? proc;
    // 探测超时（大文件/损坏文件可能卡住 ffprobe）
    final timer = Timer(const Duration(seconds: 15), () {
      try {
        proc?.kill();
      } catch (_) {}
    });
    try {
      proc = await Process.start(
        _ffprobeBin,
        ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', path],
      );
      final outFuture = proc.stdout.transform(utf8.decoder).join();
      final errFuture = proc.stderr.drain<void>();
      final out = await outFuture;
      await errFuture;
      final code = await proc.exitCode;
      timer.cancel();
      if (code != 0) return null;
      final json = jsonDecode(out) as Map<String, dynamic>;
      final fmt = (json['format'] as Map<String, dynamic>?) ??
          const <String, dynamic>{};
      final streams = (json['streams'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_streamToMap)
          .toList();
      return {
        'format': fmt['format_name'],
        'durationMs': _parseDurationMs(fmt['duration']),
        'bitrate': _parseInt(fmt['bit_rate']),
        'size': _parseInt(fmt['size']),
        'streams': streams,
      };
    } catch (e) {
      timer.cancel();
      Logger.instance.error('ffprobe 失败: $path', e);
      return null;
    }
  }

  // ───────────────────────── 编码器探测 ─────────────────────────

  Set<String>? _encodersCache;

  /// 探测 FFmpeg 支持的编码器（`ffmpeg -hide_banner -encoders`），结果缓存。
  @override
  Future<Set<String>> availableEncoders() async {
    if (_encodersCache != null) return _encodersCache!;
    final set = <String>{};
    if (_available) {
      try {
        final r = await Process.run(_ffmpegBin, ['-hide_banner', '-encoders'],
            stdoutEncoding: utf8);
        if (r.exitCode == 0) {
          for (final line in (r.stdout as String).split('\n')) {
            // 行格式：` V....D h264_nvenc    NVIDIA NVENC H.264 encoder`
            final m = RegExp(r'^\s*[VASF]\.+\s+(\S+)').firstMatch(line);
            if (m != null) set.add(m.group(1)!);
          }
        }
      } catch (e) {
        Logger.instance.error('编码器探测失败', e);
      }
    }
    _encodersCache = set;
    return set;
  }

  /// 把 ffprobe 的 stream JSON 映射为统一结构（与 ffmpeg_service 约定一致）。
  Map<String, dynamic> _streamToMap(Map<String, dynamic> s) {
    final tags = (s['tags'] as Map<String, dynamic>?) ?? const {};
    return {
      'type': s['codec_type'],
      'index': s['index'],
      'codec': s['codec_name'],
      'width': s['width'],
      'height': s['height'],
      'fps': _parseFps(s['r_frame_rate'] as String?),
      'bitrate': _parseInt(s['bit_rate']),
      'pixelFormat': s['pix_fmt'],
      'sampleRate': _parseInt(s['sample_rate']),
      'channelLayout': s['channel_layout'],
      'channels': _parseInt(s['channels']),
      'language': tags['language'],
      'title': tags['title'],
      // 附件/字体流的原始文件名（MKV 内嵌字体的 tags.filename）
      'filename': tags['filename'],
    };
  }

  // ───────────────────────── 执行 ─────────────────────────

  @override
  Future<TaskRunResult> run(
    FfmpegRunRequest request, {
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (!_available) {
      return TaskRunResult(success: false, error: _initError ?? 'FFmpeg 不可用');
    }
    if (cancelToken?.isCancelled ?? false) {
      return TaskRunResult.cancelledResult;
    }

    final args = <String>[...request.arguments];
    if (request.progressOutput) {
      args.addAll(['-progress', 'pipe:1', '-nostats']);
    }
    args.addAll(['-y']);

    Process? process;
    final progressParser = ProgressLineParser();    Duration? lastReported;
    final logBuffer = StringBuffer();

    void report(FfmpegProgress prog) {
      if (lastReported != null && prog.time < lastReported!) return;
      lastReported = prog.time;
      onProgress?.call(prog);
    }

    void onCancel() {
      try {
        process?.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }

    cancelToken?.addListener(onCancel);

    try {
      // 注意：Process.start 不经 shell，参数（含空格/中文路径）直接传递，安全。
      // Process.start 无 encoding 参数，stdout/stderr 为字节流，需自行解码。
      process = await Process.start(_ffmpegBin, args);

      // stdout：-progress 输出（ASCII，utf8 解码）；
      // stderr：日志/错误（可能含中文路径，Windows 为 GBK，用系统编码）
      final stdoutDone = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        progressParser.feed(line);
        final parsed = progressParser.progress;
        if (parsed != null) report(parsed);
      });
      final stderrDone = process.stderr
          .transform(systemEncoding.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        logBuffer.writeln(line);
        onLog?.call(line);
      });

      final exitCode = await process.exitCode;
      await stdoutDone;
      await stderrDone;

      final cancelled = cancelToken?.isCancelled ?? false;
      final log = logBuffer.toString();

      if (cancelled) {
        return TaskRunResult(
            success: false, cancelled: true, error: '任务已取消', log: log);
      }

      final outputs = <TaskOutputFile>[];
      for (final out in request.expectedOutputs) {
        try {
          final f = File(out);
          if (f.existsSync()) {
            outputs.add(TaskOutputFile(name: p.basename(out), path: out));
          }
        } catch (_) {}
      }

      if (exitCode == 0) {
        return TaskRunResult(success: true, outputs: outputs, log: log);
      }
      return TaskRunResult(
          success: false, error: friendlyFfmpegError(log), log: log);
    } catch (e) {
      // 异常路径必须终止子进程：否则 ffmpeg 持有输出文件句柄，
      // 或写满管道缓冲后阻塞成僵尸进程
      try {
        process?.kill();
      } catch (_) {}
      Logger.instance.error('FFmpeg 进程执行异常', e);
      return TaskRunResult(success: false, error: 'FFmpeg 进程执行异常: $e');
    } finally {
      cancelToken?.removeListener(onCancel);
    }
  }

  @override
  Future<void> dispose() async {}

  // ───────────────────────── 工具 ─────────────────────────

  static int? _parseInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static int? _parseDurationMs(dynamic v) {
    final d = double.tryParse(v?.toString() ?? '');
    return d == null ? null : (d * 1000).round();
  }

  static double? _parseFps(String? r) {
    if (r == null || r.isEmpty) return null;
    final parts = r.split('/');
    if (parts.length != 2) return double.tryParse(r);
    final n = double.tryParse(parts[0]);
    final d = double.tryParse(parts[1]);
    if (n == null || d == null || d == 0) return null;
    return n / d;
  }
}
