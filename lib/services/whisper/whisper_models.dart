/// ── Whisper 模型 / 语言 / 格式 / 预设常量 ──
///
/// 对齐参考项目 WhisperElectron（src/types/config.ts），并按 openai-whisper
/// CLI 实际能力修正：
/// - 剔除 distil-* 模型与 csv 输出格式（openai-whisper 不支持，选了会直接报错）
/// - 补充 large-v1 / large-v2（官方 _MODELS 均为有效模型名）
library;

/// 单个模型说明。
class WhisperModelInfo {
  /// 模型名（openai-whisper `--model` 参数值）
  final String name;

  /// 磁盘体积（.pt 文件）
  final String size;

  /// 用途说明
  final String desc;

  /// 显存占用估计
  final String vram;

  const WhisperModelInfo({
    required this.name,
    required this.size,
    required this.desc,
    required this.vram,
  });
}

/// 模型分组（下拉/列表按组展示）。
class WhisperModelCategory {
  final String name;
  final String description;
  final List<String> models;

  const WhisperModelCategory({
    required this.name,
    required this.description,
    required this.models,
  });
}

/// 转写语言（`--language` 参数值；空串 = 自动检测，即不传参数）。
class WhisperLanguage {
  /// 显示名
  final String name;

  /// ISO 639-1 代码；空 = 自动检测
  final String code;

  const WhisperLanguage(this.name, this.code);
}

/// 输出格式（`--output_format` 参数值）。
class WhisperFormat {
  final String name;
  final String desc;

  const WhisperFormat(this.name, this.desc);
}

/// 参数预设（与 WhisperElectron PRESETS 一致）。
class WhisperPreset {
  /// 显示名
  final String name;

  /// 附加 CLI 参数（空 = 自定义）
  final String args;

  const WhisperPreset(this.name, this.args);
}

/// Whisper CLI 后端（v1.2）。
///
/// - [openai]：原 openai-whisper CLI（`whisper` 命令）
/// - [faster]：faster-whisper（`whisper-ctranslate2` 命令，CLI 兼容、
///   CPU 下快约 4 倍，安装：`pip install -U faster-whisper-ctranslate2`）
/// - [auto]：按 openai → faster 顺序自动探测
/// - [whisperCpp]（v1.3 实验性）：whisper.cpp（`whisper-cli.exe` /
///   旧版 `main.exe`），不参与 auto 自动链，仅在检测到可执行文件时
///   出现在设置页下拉中，需用户显式选择
enum WhisperBackend {
  auto('auto', '自动（优先 openai-whisper）'),
  openai('openai', 'openai-whisper'),
  faster('faster', 'faster-whisper（ctranslate2）'),
  whisperCpp('cpp', 'whisper.cpp（实验性）');

  const WhisperBackend(this.code, this.label);

  /// 持久化码（settings 存储 / TaskParams 传递）
  final String code;
  final String label;

  /// 实验性后端：默认不在 UI 枚举中显示，检测到可执行文件才出现。
  bool get experimental => this == whisperCpp;

  static WhisperBackend fromCode(String? code) => values
      .firstWhere((b) => b.code == code, orElse: () => WhisperBackend.auto);
}

/// 设置页后端下拉可选项：实验性项仅在检测到可执行文件
/// （[cppAvailable]）或其已是当前持久化选择时出现
/// （后者避免下拉 value 不在 items 中的断言错误）。
List<WhisperBackend> selectableWhisperBackends({
  required bool cppAvailable,
  WhisperBackend? selected,
}) =>
    [
      for (final b in WhisperBackend.values)
        if (!b.experimental || cppAvailable || b == selected) b,
    ];

/// 模型分组（3 组，全部为 openai-whisper 有效模型名）。
const List<WhisperModelCategory> whisperModelCategories = [
  WhisperModelCategory(
    name: '标准多语言',
    description: '支持 99 种语言的通用模型，从极速到高精度全覆盖',
    models: [
      'tiny', 'base', 'small', 'medium',
      'large', 'large-v1', 'large-v2', 'large-v3', 'turbo', 'large-v3-turbo',
    ],
  ),
  WhisperModelCategory(
    name: '英文专用',
    description: '仅识别英文，比同尺寸多语言模型更小更快更准',
    models: ['tiny.en', 'base.en', 'small.en', 'medium.en'],
  ),
];

/// 各模型说明（大小为 .pt 文件磁盘占用）。
const Map<String, WhisperModelInfo> whisperModelInfo = {
  'tiny': WhisperModelInfo(
      name: 'tiny', size: '~75 MB', desc: '极速最小模型，适合实时/低配场景', vram: '~1 GB'),
  'base': WhisperModelInfo(
      name: 'base', size: '~140 MB', desc: '基础模型，速度快精度尚可', vram: '~1 GB'),
  'small': WhisperModelInfo(
      name: 'small', size: '~470 MB', desc: '小模型，速度与精度均衡', vram: '~2 GB'),
  'medium': WhisperModelInfo(
      name: 'medium', size: '~1.5 GB', desc: '中模型，推荐日常使用', vram: '~5 GB'),
  'large': WhisperModelInfo(
      name: 'large', size: '~3 GB', desc: '原始大模型，精度高资源消耗大', vram: '~10 GB'),
  'large-v1': WhisperModelInfo(
      name: 'large-v1', size: '~3 GB', desc: '大模型初版', vram: '~10 GB'),
  'large-v2': WhisperModelInfo(
      name: 'large-v2', size: '~3 GB', desc: '大模型改进版', vram: '~10 GB'),
  'large-v3': WhisperModelInfo(
      name: 'large-v3', size: '~3 GB', desc: 'v3 大模型，精度进一步提升', vram: '~10 GB'),
  'turbo': WhisperModelInfo(
      name: 'turbo',
      size: '~1.6 GB',
      desc: '推荐！速度与精度兼顾的加速版',
      vram: '~6 GB'),
  'large-v3-turbo': WhisperModelInfo(
      name: 'large-v3-turbo',
      size: '~1.6 GB',
      desc: 'v3 精度 + turbo 加速（turbo 的别名）',
      vram: '~6 GB'),
  'tiny.en': WhisperModelInfo(
      name: 'tiny.en', size: '~75 MB', desc: '英文极速模型', vram: '~1 GB'),
  'base.en': WhisperModelInfo(
      name: 'base.en', size: '~140 MB', desc: '英文基础模型', vram: '~1 GB'),
  'small.en': WhisperModelInfo(
      name: 'small.en', size: '~470 MB', desc: '英文小模型', vram: '~2 GB'),
  'medium.en': WhisperModelInfo(
      name: 'medium.en', size: '~1.5 GB', desc: '英文中模型', vram: '~5 GB'),
};

/// 语言清单（WhisperElectron LANGUAGE_NAMES 同款 9 项）。
const List<WhisperLanguage> whisperLanguages = [
  WhisperLanguage('中文', 'zh'),
  WhisperLanguage('英文', 'en'),
  WhisperLanguage('日文', 'ja'),
  WhisperLanguage('韩文', 'ko'),
  WhisperLanguage('法语', 'fr'),
  WhisperLanguage('德文', 'de'),
  WhisperLanguage('西班牙文', 'es'),
  WhisperLanguage('俄文', 'ru'),
  WhisperLanguage('自动检测', ''),
];

/// 输出格式（whisper CLI choices：txt/vtt/srt/tsv/json/all）。
const List<WhisperFormat> whisperFormats = [
  WhisperFormat('srt', '最通用的字幕格式，所有播放器支持'),
  WhisperFormat('vtt', 'Web 字幕格式，浏览器直接支持'),
  WhisperFormat('txt', '纯文本，只包含识别的文字内容'),
  WhisperFormat('json', '结构化数据，包含时间戳和置信度'),
  WhisperFormat('tsv', '表格格式，可用 Excel 打开'),
  WhisperFormat('all', '生成以上所有格式'),
];

/// 格式 → 扩展名（all 以 .srt 作为主产物）。
const Map<String, String> whisperFormatExtension = {
  'srt': '.srt',
  'vtt': '.vtt',
  'txt': '.txt',
  'json': '.json',
  'tsv': '.tsv',
  'all': '.srt',
};

/// 参数预设（预设 5 修正了 WhisperElectron 中把标点列表参数
/// `--prepend_punctuations/--append_punctuations` 误传 True 的问题，
/// 只保留有效的 `--word_timestamps True`）。
const List<WhisperPreset> whisperPresets = [
  WhisperPreset(
    '通用最佳默认（推荐）',
    '--beam_size 5 --temperature 0.0 --condition_on_previous_text True '
        '--compression_ratio_threshold 2.4 --logprob_threshold -1.0 '
        '--no_speech_threshold 0.6',
  ),
  WhisperPreset(
    '高质量转录（会议/采访）',
    '--beam_size 10 --temperature 0.0 --best_of 5 '
        '--condition_on_previous_text True --patience 2.0 '
        '--compression_ratio_threshold 2.4 --logprob_threshold -1.0 '
        '--no_speech_threshold 0.6',
  ),
  WhisperPreset(
    '快速批量处理（大量视频）',
    '--beam_size 2 --temperature 0.0 --condition_on_previous_text True '
        '--best_of 1 --patience 1.0 --compression_ratio_threshold 2.4 '
        '--logprob_threshold -1.0 --no_speech_threshold 0.6',
  ),
  WhisperPreset(
    '有噪音/口音重的音频',
    '--beam_size 8 --temperature 0.2 --condition_on_previous_text False '
        '--compression_ratio_threshold 2.0 --logprob_threshold -0.5 '
        '--no_speech_threshold 0.6',
  ),
  WhisperPreset(
    '卡拉OK/逐字高亮字幕',
    '--beam_size 5 --temperature 0.0 --word_timestamps True '
        '--compression_ratio_threshold 2.4 --logprob_threshold -1.0 '
        '--no_speech_threshold 0.6',
  ),
  WhisperPreset('自定义高级参数', ''),
];
