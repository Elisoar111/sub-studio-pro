import 'package:path/path.dart' as p;

/// gMKVExtractGUI v2.15.0（By Gpower2）同款输出文件名规则（硬编码默认
/// pattern，不提供模板）。规则来源：
/// - gSettings.cs：各类型默认 pattern
/// - gMKVExtractExtensions.cs：占位符替换、非法字符处理、CodecID→扩展名
///
/// pattern：
/// - video / subtitle：`{名}_track{轨道号}_[{语言}]`
/// - audio：`{名}_track{轨道号}_[{语言}]_DELAY {相对延迟}ms`
/// - chapters：`{名}_chapters.xml`；tags：`{名}_tags.xml`
/// - attachment：容器内原始文件名
///
/// [trackNumber] 为 mkvmerge -J 的 `properties.track_number`（1-based 全局
/// 序号，非 mkvextract 用的 0-based id）；[effectiveDelayMs] 为音轨相对
/// 视频轨的最小时间戳差（ms），与 gMKV 的 FindAndSetDelays 同源。
class GmkvExtractNamer {
  GmkvExtractNamer._();

  /// Windows 非法文件名字符 + 控制字符（对应 Path.GetInvalidFileNameChars）。
  static final RegExp _invalidChars = RegExp(r'[\x00-\x1f<>:"/\\|?*]');

  static String _noExt(String sourcePath) =>
      p.basenameWithoutExtension(sourcePath);

  /// 清理非法字符并去首尾空白（gMKV ReplaceFilenamePlaceholders 收尾逻辑）。
  static String sanitize(String name) =>
      name.replaceAllMapped(_invalidChars, (_) => '_').trim();

  /// 视频 / 音频 / 字幕轨输出名。[kind] ∈ video / audio / subtitle。
  static String trackFilename({
    required String sourcePath,
    required int trackNumber,
    required String language,
    required String codecId,
    required String kind,
    int effectiveDelayMs = 0,
  }) {
    final ext = switch (kind) {
      'video' => videoExtension(codecId),
      'audio' => audioExtension(codecId),
      _ => subtitleExtension(codecId),
    };
    var name = '${_noExt(sourcePath)}_track${trackNumber}_[$language]';
    if (kind == 'audio') name += '_DELAY ${effectiveDelayMs}ms';
    return sanitize('$name.$ext');
  }

  static String chaptersFilename(String sourcePath) =>
      sanitize('${_noExt(sourcePath)}_chapters.xml');

  static String tagsFilename(String sourcePath) =>
      sanitize('${_noExt(sourcePath)}_tags.xml');

  /// 附件输出名 = 容器内原始文件名（gMKV AttachmentFilenamePattern 默认）。
  /// [containerName] 为空时退化为 attachment_{id}（防御，mkvmerge -J 必有值）。
  static String attachmentFilename(String containerName, {int id = 0}) {
    if (containerName.isEmpty) return 'attachment_$id';
    return sanitize(p.basename(containerName));
  }

  /// 音轨相对视频轨的延迟（ms）：两者 minimum_timestamp（纳秒）之差。
  /// 任一为 null（无视频轨 / 无时间戳数据）→ 0（gMKV 同语义）。
  static int effectiveDelayMs({int? trackMinTsNs, int? videoMinTsNs}) {
    if (trackMinTsNs == null || videoMinTsNs == null) return 0;
    return (trackMinTsNs - videoMinTsNs) ~/ 1000000;
  }

  /// 视频轨扩展名（gMKV GetVideoFileExtensionFromCodecID 全表）。
  static String videoExtension(String codecId) {
    final c = codecId.toUpperCase();
    if (c.contains('V_MS/VFW/FOURCC')) return 'avi';
    if (c.contains('V_UNCOMPRESSED')) return 'raw';
    if (c.contains('V_MPEG4/ISO/')) return 'avc';
    if (c.contains('V_MPEGH/ISO/HEVC')) return 'hevc';
    if (c.contains('V_AV1')) return 'av1';
    if (c.contains('V_MPEG4/MS/V3')) return 'mp4';
    if (c.contains('V_MPEG1')) return 'mpg';
    if (c.contains('V_MPEG2')) return 'mpg';
    if (c.contains('V_REAL/')) return 'rm';
    if (c.contains('V_QUICKTIME')) return 'mov';
    if (c.contains('V_THEORA')) return 'ogv';
    if (c.contains('V_PRORES')) return 'mov';
    if (c.contains('V_VP')) return 'ivf';
    if (c.contains('V_DIRAC')) return 'drc';
    return 'mkv';
  }

  /// 音频轨扩展名（gMKV GetAudioFileExtensionFromCodecID 全表）。
  static String audioExtension(String codecId) {
    final c = codecId.toUpperCase();
    if (c.contains('A_MPEG/L3')) return 'mp3';
    if (c.contains('A_MPEG/L2')) return 'mp2';
    if (c.contains('A_MPEG/L1')) return 'mpa';
    if (c.contains('A_PCM')) return 'wav';
    if (c.contains('A_MPC')) return 'mpc';
    if (c.contains('A_AC3')) return 'ac3';
    if (c.contains('A_EAC3')) return 'eac3';
    if (c.contains('A_ALAC')) return 'caf';
    if (c.contains('A_DTS')) return 'dts';
    if (c.contains('A_VORBIS')) return 'ogg';
    if (c.contains('A_FLAC')) return 'flac';
    if (c.contains('A_REAL')) return 'ra';
    if (c.contains('A_MS/ACM')) return 'wav';
    if (c.contains('A_AAC')) return 'aac';
    if (c.contains('A_QUICKTIME')) return 'mov';
    if (c.contains('A_TRUEHD')) return 'thd';
    if (c.contains('A_TTA1')) return 'tta';
    if (c.contains('A_WAVPACK4')) return 'wv';
    if (c.contains('A_OPUS')) return 'opus';
    if (c.contains('A_MLP')) return 'mlp';
    return 'mka';
  }

  /// 字幕轨扩展名（gMKV GetSubtitleFileExtensionFromCodecID 全表）。
  static String subtitleExtension(String codecId) {
    final c = codecId.toUpperCase();
    if (c.contains('S_TEXT/UTF8')) return 'srt';
    if (c.contains('S_TEXT/ASCII')) return 'srt';
    if (c.contains('S_TEXT/SSA')) return 'ass';
    if (c.contains('S_TEXT/ASS')) return 'ass';
    if (c.contains('S_TEXT/USF')) return 'usf';
    if (c.contains('S_TEXT/WEBVTT')) return 'webvtt';
    if (c.contains('S_IMAGE/BMP')) return 'sub';
    if (c.contains('S_VOBSUB')) return 'sub';
    if (c.contains('S_DVBSUB')) return 'dvbsub';
    if (c.contains('S_HDMV/PGS')) return 'sup';
    if (c.contains('S_HDMV/TEXTST')) return 'textst';
    if (c.contains('S_KATE')) return 'ogg';
    return 'sub';
  }
}
