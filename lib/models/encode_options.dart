import 'task_params.dart';

/// 输出分辨率预设
enum ResolutionPreset { original, p2160, p1080, p720, p480, custom }

/// 视频编码器（P0 硬件加速：NVENC / AMF / QSV）
enum VideoEncoder {
  x264,
  h264Nvenc,
  hevcNvenc,
  h264Amf,
  h264Qsv;

  /// FFmpeg 编码器名称
  String get codecName {
    switch (this) {
      case VideoEncoder.x264:
        return 'libx264';
      case VideoEncoder.h264Nvenc:
        return 'h264_nvenc';
      case VideoEncoder.hevcNvenc:
        return 'hevc_nvenc';
      case VideoEncoder.h264Amf:
        return 'h264_amf';
      case VideoEncoder.h264Qsv:
        return 'h264_qsv';
    }
  }

  /// 是否为硬件编码器（输出限 8bit yuv420p）
  bool get isHardware => this != VideoEncoder.x264;
}

/// 视频编码输出设置（烧录 / 转码共用）
class VideoEncodeOptions {
  final ResolutionPreset resolution;
  final int? customWidth;
  final int? customHeight;

  /// libx264 CRF（0-51，越小质量越高；18-23 常见）
  final int crf;

  /// x264 速度预设
  final String x264Preset;

  /// 固定视频码率（kbps）；非空时优先于 crf
  final int? videoBitrateKbps;

  /// 目标帧率（null = 保持源）
  final double? fps;

  /// 输出容器：mp4 / mkv / mov / webm / avi
  final String container;

  /// 输出音频编解码器：aac / opus / mp3（'copy' 表示直拷，见 copyAudio）
  final String audioCodec;

  final int audioBitrateKbps;

  /// 音频直拷（不重编码，更快）
  final bool copyAudio;

  /// MP4 快速起播（moov 前置）
  final bool fastStart;

  /// 视频编码器（默认 x264 软编；硬件编码器需系统 FFmpeg 支持）
  final VideoEncoder encoder;

  const VideoEncodeOptions({
    this.resolution = ResolutionPreset.original,
    this.customWidth,
    this.customHeight,
    this.crf = 20,
    this.x264Preset = 'medium',
    this.videoBitrateKbps,
    this.fps,
    this.container = 'mp4',
    this.audioCodec = 'aac',
    this.audioBitrateKbps = 128,
    this.copyAudio = false,
    this.fastStart = true,
    this.encoder = VideoEncoder.x264,
  });

  /// 视频编码器（webm 强制 vp9 软编；其余按用户选择）
  String get videoCodec =>
      container == 'webm' ? 'libvpx-vp9' : encoder.codecName;

  /// 音频编码器（webm 容器强制 opus）
  String get effectiveAudioCodec =>
      container == 'webm' ? 'libopus' : audioCodec;

  /// 根据源尺寸计算缩放目标；不需要缩放时返回 null。
  ({int width, int height})? targetSize(int srcW, int srcH) {
    int? tw, th;
    switch (resolution) {
      case ResolutionPreset.original:
        return null;
      case ResolutionPreset.p2160:
        tw = 3840;
        th = 2160;
      case ResolutionPreset.p1080:
        tw = 1920;
        th = 1080;
      case ResolutionPreset.p720:
        tw = 1280;
        th = 720;
      case ResolutionPreset.p480:
        tw = 854;
        th = 480;
      case ResolutionPreset.custom:
        if (customWidth == null || customHeight == null) return null;
        tw = customWidth;
        th = customHeight;
    }
    if (tw == null || th == null || srcW <= 0 || srcH <= 0) return null;

    if (resolution == ResolutionPreset.custom) {
      return (width: tw - tw % 2, height: th - th % 2);
    }
    // 只缩小不放大
    final scale = (tw / srcW) < (th / srcH) ? tw / srcW : th / srcH;
    if (scale >= 1) return null;
    var w = (srcW * scale).round();
    var h = (srcH * scale).round();
    w -= w % 2;
    h -= h % 2;
    return (width: w, height: h);
  }

  Map<String, String> toParams() => {
        TaskParams.container: container,
        TaskParams.resolution: resolution.name,
        TaskParams.customW: customWidth?.toString() ?? '',
        TaskParams.customH: customHeight?.toString() ?? '',
        TaskParams.crf: crf.toString(),
        TaskParams.x264Preset: x264Preset,
        TaskParams.videoBitrate: videoBitrateKbps?.toString() ?? '',
        TaskParams.fps: fps?.toString() ?? '',
        TaskParams.audioCodec: audioCodec,
        TaskParams.audioBitrate: audioBitrateKbps.toString(),
        TaskParams.copyAudio: copyAudio.toString(),
        TaskParams.fastStart: fastStart.toString(),
        TaskParams.encoder: encoder.name,
      };

  static VideoEncodeOptions fromParams(Map<String, String> m) =>
      VideoEncodeOptions(
        container: m[TaskParams.container] ?? 'mp4',
        resolution: ResolutionPreset.values.asNameMap()[m[TaskParams.resolution]] ??
            ResolutionPreset.original,
        customWidth: int.tryParse(m[TaskParams.customW] ?? ''),
        customHeight: int.tryParse(m[TaskParams.customH] ?? ''),
        crf: int.tryParse(m[TaskParams.crf] ?? '') ?? 20,
        x264Preset: m[TaskParams.x264Preset] ?? 'medium',
        videoBitrateKbps: int.tryParse(m[TaskParams.videoBitrate] ?? ''),
        fps: double.tryParse(m[TaskParams.fps] ?? ''),
        audioCodec: m[TaskParams.audioCodec] ?? 'aac',
        audioBitrateKbps: int.tryParse(m[TaskParams.audioBitrate] ?? '') ?? 128,
        copyAudio: (m[TaskParams.copyAudio] ?? 'false') == 'true',
        fastStart: (m[TaskParams.fastStart] ?? 'true') == 'true',
        encoder: VideoEncoder.values.asNameMap()[m[TaskParams.encoder]] ??
            VideoEncoder.x264,
      );
}
