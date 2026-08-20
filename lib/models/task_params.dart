/// 队列任务参数键（字符串序列化，供历史/队列重建请求）。
///
/// 这是 UI、队列、历史之间唯一的参数契约层：
/// 上游（各功能页）写入，下游（QueueService → FfmpegService）读取。
class TaskParams {
  TaskParams._();

  static const videoPath = 'video';
  static const subtitlePath = 'subtitle';
  static const outputPath = 'output';
  static const trackIndex = 'trackIndex';
  static const container = 'container';
  static const resolution = 'resolution';
  static const customW = 'customW';
  static const customH = 'customH';
  static const crf = 'crf';
  static const x264Preset = 'x264Preset';
  static const videoBitrate = 'videoBitrate';
  static const fps = 'fps';
  static const audioCodec = 'audioCodec';
  static const audioBitrate = 'audioBitrate';
  static const copyAudio = 'copyAudio';
  static const fastStart = 'fastStart';
  static const useAssFilter = 'useAss';
  static const forceStyle = 'forceStyle';
  static const fontsDir = 'fontsDir';
  static const totalDurationMs = 'durationMs';
  static const targetFormat = 'targetFormat';
  static const encoding = 'encoding';
  static const includeBom = 'includeBom';
  static const microDvdFps = 'microDvdFps';
  static const title = 'title';
  static const encoder = 'encoder';

  // ── 封装（Mux，唯一后端 mkvmerge，输出固定 MKV）──
  /// JSON 数组（MuxTrack）：全部待封装轨道（字幕/音频/附件）
  static const tracksJson = 'tracksJson';

  /// 是否保留源视频原有内嵌字幕轨
  static const keepSubs = 'keepSubs';

  /// 音轨映射：all = 全部音轨，first = 仅第一条，none = 丢弃源音轨
  static const audioMode = 'audioMode';

  /// 源轨道选择 JSON：{"audio":[ID…],"subs":[ID…],"chapters":bool}
  /// audio/subs 为 mkvmerge -J 轨道 ID；键缺省或 null = 该类全保留，
  /// 空数组 = 全部排除；缺省本键 = 未探测（走 audioMode/keepSubs 旧参数）
  static const sourceSel = 'sourceSel';

  // ── 轨道提取（唯一后端 mkvextract）──
  /// subtitle / audio / video / attachment / chapters / tags
  static const trackType = 'trackType';

  /// mkvmerge -J 轨道/附件 ID（章节=-1、标签=-2，不使用 ID）
  static const streamIndex = 'streamIndex';

  /// 该轨在同类型中的序号（非 MKV 输入转封临时 MKV 后按此重定位 ID）；
  /// 同时是「新版 mkvextract 任务」的判定标记（旧 FFmpeg 任务无此键）
  static const typeOrdinal = 'typeOrdinal';

  // ── AI 字幕翻译 ──
  static const targetLang = 'targetLang';

  /// 双语合并文件（_mixed）输出路径；缺省 = 不输出合并文件
  static const mixedPath = 'mixedPath';

  /// '1' = 翻译后追加润色二阶段（标点/断句优化，不改语义）
  static const polishMode = 'polish';

  // ── Whisper 字幕 ──
  /// 模型名（tiny / base / … / large-v3-turbo）
  static const whisperModel = 'wModel';

  /// ISO 639-1 语言码（空 = 自动检测）
  static const whisperLanguage = 'wLang';

  /// 输出格式（srt/vtt/txt/json/tsv/all）
  static const whisperFormat = 'wFormat';

  /// 是否用 GPU（cuda）
  static const whisperGpu = 'wGpu';

  /// 参数预设号 1..6（6 = 自定义）
  static const whisperPreset = 'wPreset';

  /// 初始提示词（可选）
  static const whisperPrompt = 'wPrompt';

  /// '1' = 启用 VAD 静音过滤（仅 faster-whisper 后端生效）
  static const vadFilter = 'wVad';

  /// 预设 6 的自定义 CLI 参数
  static const whisperCustomParams = 'wCustom';

  /// 输出已存在时跳过转写
  static const skipExisting = 'skipExisting';
}
