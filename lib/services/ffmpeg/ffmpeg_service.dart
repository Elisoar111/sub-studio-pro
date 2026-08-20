import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/constants.dart';
import '../../core/utils/ffmpeg_path_escape.dart';
import '../../models/encode_options.dart';
import '../../models/video_info.dart';
import 'ffmpeg_runner.dart';
import 'ffmpeg_runner_process.dart';

/// FFmpeg 高级服务：视频信息探测 / 字幕烧录 / 内嵌轨预提取 / 转码压缩 / 缩略图。
/// 所有操作异步执行并通过 [FfmpegProgress] 回报进度，支持取消。
/// 用户侧的轨道提取与封装已全部改由 MKVToolNix（mkvextract / mkvmerge）完成。
class FfmpegService {
  FfmpegService._(this.runner);

  final FfmpegRunner runner;

  static FfmpegService? _instance;

  /// 创建单例（main 中调用一次）。
  ///
  /// [ffmpegPath] / [ffprobePath]：用户自定义的可执行文件路径；
  /// 为空时回退到系统 PATH 查找。
  static Future<FfmpegService> create({
    String? ffmpegPath,
    String? ffprobePath,
  }) async {
    final r = FfmpegProcessRunner();
    r.configure(ffmpegPath: ffmpegPath, ffprobePath: ffprobePath);
    await r.init();
    _instance = FfmpegService._(r);
    return _instance!;
  }

  /// 重新配置 FFmpeg 路径（设置页保存后调用），并立即重新检测。
  Future<void> reconfigureFfmpeg({
    String? ffmpegPath,
    String? ffprobePath,
  }) async {
    final r = runner;
    if (r is FfmpegProcessRunner) {
      r.configure(ffmpegPath: ffmpegPath, ffprobePath: ffprobePath);
      await r.init();
    }
  }

  static FfmpegService get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('FfmpegService 尚未初始化，请先调用 FfmpegService.create()');
    }
    return i;
  }

  bool get isWeb => runner.isWeb;

  /// FFmpeg 支持的编码器集合（探测并缓存）。
  Future<Set<String>> availableEncoders() => runner.availableEncoders();

  // ─────────────────────── 目录管理 ───────────────────────

  /// 临时目录（处理中文件；输出目录工具见 FileService.outputDirFor）
  Future<String> tempDir() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory(p.join(base.path, AppConstants.appDirName));
      await dir.create(recursive: true);
      return dir.path;
    } catch (_) {
      return 'tmp';
    }
  }

  /// 缩略图目录
  Future<String> thumbDir() async =>
      p.join(await tempDir(), AppConstants.dirThumb);

  // ─────────────────────── 视频信息 ───────────────────────

  /// 探测视频信息（分辨率/时长/编码/码率/音视频字幕轨）。
  Future<VideoInfo> probeVideo(String path) async {
    final map = await runner.probe(path);
    if (map == null) return VideoInfo.unknown(path);

    final streams = (map['streams'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    final videoStreams = <VideoStreamInfo>[];
    final audioStreams = <AudioStreamInfo>[];
    final subtitleStreams = <SubtitleStreamInfo>[];
    final attachmentStreams = <AttachmentStreamInfo>[];
    for (final s in streams) {
      final type = s['type'] as String? ?? '';
      final index = s['index'] as int? ?? 0;
      switch (type) {
        case 'video':
          videoStreams.add(VideoStreamInfo(
            index: index,
            codec: s['codec'] as String? ?? '?',
            width: s['width'] as int?,
            height: s['height'] as int?,
            fps: (s['fps'] as num?)?.toDouble(),
            bitrate: s['bitrate'] as int?,
            pixelFormat: s['pixelFormat'] as String?,
          ));
        case 'audio':
          audioStreams.add(AudioStreamInfo(
            index: index,
            codec: s['codec'] as String? ?? '?',
            // 优先使用 ffprobe 给出的精确声道数，缺失时再按 channelLayout 推断
            channels: (s['channels'] as int?) ??
                _channelsFromLayout(s['channelLayout'] as String?),
            sampleRate: s['sampleRate'] as int?,
            bitrate: s['bitrate'] as int?,
            language: s['language'] as String?,
          ));
        case 'subtitle':
          subtitleStreams.add(SubtitleStreamInfo(
            index: index,
            codec: s['codec'] as String? ?? '?',
            language: s['language'] as String?,
            title: s['title'] as String?,
          ));
        case 'attachment':
          attachmentStreams.add(AttachmentStreamInfo(
            index: index,
            codec: s['codec'] as String? ?? '?',
            filename: s['filename'] as String?,
            title: s['title'] as String?,
          ));
      }
    }

    return VideoInfo(
      path: path,
      formatName: map['format'] as String?,
      duration: Duration(milliseconds: map['durationMs'] as int? ?? 0),
      bitrate: map['bitrate'] as int?,
      sizeBytes: map['size'] as int?,
      videoStreams: videoStreams,
      audioStreams: audioStreams,
      subtitleStreams: subtitleStreams,
      attachmentStreams: attachmentStreams,
    );
  }

  static int? _channelsFromLayout(String? layout) {
    if (layout == null) return null;
    const known = {
      'mono': 1, 'stereo': 2, '2.1': 3, '3.0': 3, '4.0': 4,
      '5.0': 5, '5.1': 6, '7.1': 8,
    };
    return known[layout];
  }

  // ─────────────────────── 字幕烧录 ───────────────────────

  /// 烧录外部字幕文件。
  ///
  /// FFmpeg 命令（SRT 示例）：
  /// ```
  /// ffmpeg -i in.mp4 -vf "scale=...,subtitles='sub.srt':force_style='...'"
  ///        -c:v libx264 -preset medium -crf 20
  ///        -map 0:v:0 -map 0:a:0? -c:a aac -b:a 128k
  ///        -movflags +faststart -y out.mp4
  /// ```
  /// ASS/SSA 使用 `ass='file.ass'` 滤镜（libass 渲染，保留样式与特效）。
  Future<TaskRunResult> burnSubtitles({
    required String videoPath,
    required String subtitlePath,
    required String outputPath,
    VideoEncodeOptions encode = const VideoEncodeOptions(),
    bool useAssFilter = false,
    String? forceStyle,
    String? fontsDir,
    Duration? totalDuration,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    final video = await probeVideo(videoPath);
    final srcW = video.firstVideo?.width;
    final srcH = video.firstVideo?.height;
    totalDuration ??= video.duration.inMilliseconds > 0 ? video.duration : null;

    final args = <String>['-i', videoPath];
    final filters = <String>[];

    // 缩放（只缩小）→ 偶数尺寸 → 保持宽高比（letterbox）
    final size = (srcW != null && srcH != null)
        ? encode.targetSize(srcW, srcH)
        : null;
    if (size != null) {
      filters.add(
          'scale=${size.width}:${size.height}:force_original_aspect_ratio=decrease,'
          'pad=${size.width}:${size.height}:(ow-iw)/2:(oh-ih)/2:color=black,'
          'setsar=1');
    }

    // 字幕滤镜（路径转义！）
    final subFilter = useAssFilter
        ? 'ass=${escapeFilterPath(subtitlePath)}'
        : 'subtitles=${escapeFilterPath(subtitlePath)}';
    var stylePart = '';
    if (fontsDir != null && fontsDir.isNotEmpty) {
      // 自定义字体目录（libass 字体加载路径，路径同样需要转义）
      stylePart += ':fontsdir=${escapeFilterPath(fontsDir)}';
    }
    if (forceStyle != null && forceStyle.isNotEmpty && !useAssFilter) {
      stylePart += ":force_style='$forceStyle'";
    }
    filters.add('$subFilter$stylePart');
    // 硬件编码器（NVENC/AMF/QSV）仅支持 8bit yuv420p，统一转换
    if (encode.encoder.isHardware) {
      filters.add('format=yuv420p');
    }
    args.addAll(['-vf', filters.join(',')]);

    args.addAll(_videoArgs(encode, video.hasAudio, srcW, srcH));
    args.add(outputPath);

    return runner.run(
      FfmpegRunRequest(
        arguments: args,
        totalDuration: totalDuration,
        progressOutput: true,
        expectedOutputs: [outputPath],
      ),
      onProgress: onProgress,
      onLog: onLog,
      cancelToken: cancelToken,
    );
  }

  /// 烧录视频内嵌字幕轨：先提取到临时文件，再执行烧录。
  Future<TaskRunResult> burnEmbeddedTrack({
    required String videoPath,
    required int trackIndex,
    required String outputPath,
    VideoEncodeOptions encode = const VideoEncodeOptions(),
    bool useAssFilter = false,
    String? forceStyle,
    String? fontsDir,
    Duration? totalDuration,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    final temp = await tempDir();
    final tmpSub = p.join(temp, 'embedded_track_$trackIndex.srt');
    final extract = await extractTrack(
      videoPath: videoPath,
      selector: 's:$trackIndex',
      trackType: 'subtitle',
      outputPath: tmpSub,
      subtitleFormat: 'srt',
    );
    if (!extract.success) return extract;
    return burnSubtitles(
      videoPath: videoPath,
      subtitlePath: tmpSub,
      outputPath: outputPath,
      encode: encode,
      useAssFilter: useAssFilter,
      forceStyle: forceStyle,
      fontsDir: fontsDir,
      totalDuration: totalDuration,
      onProgress: onProgress,
      onLog: onLog,
      cancelToken: cancelToken,
    );
  }

  // ─────────────────────── 轨道提取（内嵌字幕轨烧录的预提取） ───────────────────────

  /// 按流选择子提取单条轨道（当前仅供 burnEmbeddedTrack 预提取内嵌字幕
  /// 轨为 SRT 临时文件使用；用户侧轨道提取已全部走 MKVToolNix/mkvextract）。
  ///
  /// [selector] 为流选择子：
  /// - 绝对索引 `'2'`
  /// - 类型相对序号 `'s:0'` / `'a:1'`
  ///
  /// - 字幕：`-map 0:N -c:s srt`（统一转 SRT 供烧录滤镜使用）
  /// - 附件：`-dump_attachment:N out.ttf`（见下）
  ///
  /// 附件/字体无可用输出封装器（.ttf/.otf 没有 muxer），`-map 0:N -c copy
  /// out.ttf` 会报 "Unable to find a suitable output format"。文档化做法是
  /// `-dump_attachment`：附件在解封装头阶段即以 extradata 形式落盘（输入侧
  /// 选项，必须写在 -i 之前）。因 CLI 要求至少一个输出，补一个流拷贝到
  /// null 设备的哑输出（不触发解码，速度 ≈ 解封装）。
  Future<TaskRunResult> extractTrack({
    required String videoPath,
    required String selector,
    required String trackType, // subtitle / audio / video / attachment
    required String outputPath,
    String audioCodec = 'copy',
    int audioBitrateKbps = 192,
    String? subtitleFormat, // null = copy；srt/ass/vtt = 转格式
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (trackType == 'attachment') {
      final dumpArgs = <String>[
        '-y',
        '-dump_attachment:$selector', outputPath,
        '-i', videoPath,
        // 哑输出：满足 CLI 输出要求；附件在解封装头阶段即原样落盘（不设
        // 任何格式转换，是什么提取什么）。仅映射 v/a——字幕轨（PGS 等）
        // null muxer 不支持，映射会报 "Could not find tag for codec"
        '-map', '0:v?', '-map', '0:a?',
        '-c', 'copy',
        '-f', 'null', 'NUL',
      ];
      return runner.run(
        FfmpegRunRequest(
          arguments: dumpArgs,
          progressOutput: false,
          expectedOutputs: [outputPath],
        ),
        onProgress: onProgress,
        onLog: onLog,
        cancelToken: cancelToken,
      );
    }

    final args = <String>['-i', videoPath, '-map', '0:$selector'];
    switch (trackType) {
      case 'subtitle':
        args.addAll(['-c:s', _extractCodec(subtitleFormat)]);
      case 'audio':
        if (audioCodec == 'copy') {
          args.addAll(['-c:a', 'copy']);
        } else {
          args.addAll(['-c:a', audioCodec, '-b:a', '${audioBitrateKbps}k']);
        }
      case 'video':
        args.addAll(['-c:v', 'copy']);
      default:
        return TaskRunResult(success: false, error: '未知轨道类型：$trackType');
    }
    args.add(outputPath);
    return runner.run(
      FfmpegRunRequest(
        arguments: args,
        progressOutput: true,
        expectedOutputs: [outputPath],
      ),
      onProgress: onProgress,
      onLog: onLog,
      cancelToken: cancelToken,
    );
  }

  /// 提取字幕的目标编码器：null = copy（保持源格式）。
  static String _extractCodec(String? format) {
    switch (format) {
      case null:
      case '':
        return 'copy';
      case 'vtt':
        return 'webvtt';
      case 'ass':
      case 'ssa':
        return 'ass';
      default:
        return 'srt';
    }
  }

  // ─────────────────────── 转码 / 压缩 ───────────────────────

  /// 视频转码 / 压缩。
  Future<TaskRunResult> transcode({
    required String inputPath,
    required String outputPath,
    VideoEncodeOptions encode = const VideoEncodeOptions(),
    Duration? totalDuration,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    final video = await probeVideo(inputPath);
    final srcW = video.firstVideo?.width;
    final srcH = video.firstVideo?.height;
    totalDuration ??= video.duration.inMilliseconds > 0 ? video.duration : null;

    final args = <String>['-i', inputPath];

    final size = (srcW != null && srcH != null)
        ? encode.targetSize(srcW, srcH)
        : null;
    final needYuv420p = encode.encoder.isHardware;
    if (size != null) {
      var vf =
          'scale=${size.width}:${size.height}:force_original_aspect_ratio=decrease,'
          'pad=${size.width}:${size.height}:(ow-iw)/2:(oh-ih)/2:color=black,'
          'setsar=1';
      // 硬件编码器仅支持 8bit yuv420p
      if (needYuv420p) vf = '$vf,format=yuv420p';
      args.addAll(['-vf', vf]);
    } else if (needYuv420p) {
      args.addAll(['-pix_fmt', 'yuv420p']);
    }

    args.addAll(_videoArgs(encode, video.hasAudio, srcW, srcH));
    args.add(outputPath);

    return runner.run(
      FfmpegRunRequest(
        arguments: args,
        totalDuration: totalDuration,
        progressOutput: true,
        expectedOutputs: [outputPath],
      ),
      onProgress: onProgress,
      onLog: onLog,
      cancelToken: cancelToken,
    );
  }

  /// 根据编码设置构建视频/音频编码参数。
  List<String> _videoArgs(
    VideoEncodeOptions encode,
    bool hasAudio,
    int? srcW,
    int? srcH,
  ) {
    final args = <String>[
      '-map', '0:v:0',
      '-map', '0:a:0?', // '?' = 音频可选
      '-c:v', encode.videoCodec,
    ];

    if (encode.encoder.isHardware) {
      // ── 硬件编码器（质量档数值与 x264 CRF 语义一致：越小越清晰）──
      final k = encode.videoBitrateKbps ?? 8000;
      switch (encode.encoder) {
        case VideoEncoder.h264Nvenc:
        case VideoEncoder.hevcNvenc:
          // NVENC VBR 质量模式：-cq 控制质量，-b:v 为码率上限
          args.addAll([
            '-preset', 'p5',
            '-rc', 'vbr',
            '-cq', encode.crf.toString(),
            '-b:v', '${k}k',
            '-maxrate', '${(k * 1.5).round()}k',
            '-bufsize', '${k * 2}k',
          ]);
        case VideoEncoder.h264Amf:
          args.addAll([
            '-quality', 'balanced',
            '-rc', 'vbr_quality',
            '-q:v', encode.crf.toString(),
            '-b:v', '${k}k',
          ]);
        case VideoEncoder.h264Qsv:
          args.addAll([
            '-global_quality', encode.crf.toString(),
            '-b:v', '${k}k',
          ]);
        case VideoEncoder.x264:
          break; // 不会走到
      }
    } else if (encode.container != 'webm') {
      // ── x264 软件编码 ──
      args.addAll(['-preset', encode.x264Preset]);
      if (encode.videoBitrateKbps != null && encode.videoBitrateKbps! > 0) {
        final k = encode.videoBitrateKbps!;
        args.addAll(['-b:v', '${k}k', '-maxrate', '${(k * 1.4).round()}k',
            '-bufsize', '${k * 2}k']);
      } else {
        args.addAll(['-crf', encode.crf.toString()]);
      }
    } else {
      // ── webm / libvpx-vp9（软编，无 -preset）──
      if (encode.videoBitrateKbps != null && encode.videoBitrateKbps! > 0) {
        args.addAll(['-b:v', '${encode.videoBitrateKbps}k']);
      } else {
        args.addAll(['-crf', encode.crf.toString()]);
      }
    }
    if (encode.fps != null && encode.fps! > 0) {
      args.addAll(['-r', encode.fps!.toStringAsFixed(3)]);
    }
    if (hasAudio) {
      if (encode.copyAudio) {
        args.addAll(['-c:a', 'copy']);
      } else {
        args.addAll([
          '-c:a', encode.effectiveAudioCodec,
          '-b:a', '${encode.audioBitrateKbps}k',
        ]);
      }
    }
    if (encode.fastStart && (encode.container == 'mp4' || encode.container == 'mov')) {
      args.add('-movflags');
      args.add('+faststart');
    }
    return args;
  }

  // ─────────────────────── 缩略图 ───────────────────────

  /// 生成视频缩略图（文件选择器预览）。
  Future<TaskRunResult> generateThumbnail({
    required String videoPath,
    required String outputPath,
    Duration at = const Duration(seconds: 1),
    int width = 320,
  }) async {
    final args = <String>[
      '-ss', at.inSeconds.toString(),
      '-i', videoPath,
      '-frames:v', '1',
      '-vf', 'scale=$width:-2',
      '-q:v', '3',
      outputPath,
    ];
    return runner.run(
      FfmpegRunRequest(
        arguments: args,
        progressOutput: false,
        expectedOutputs: [outputPath],
      ),
    );
  }
}
