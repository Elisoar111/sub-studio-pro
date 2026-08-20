import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';
import '../ffmpeg/ffmpeg_runner.dart';
import '../storage_service.dart';
import 'whisper_models.dart';

/// ── Whisper 集成（openai-whisper CLI 子进程，参考 WhisperElectron）──
///
/// 与 gMKVExtractGUI/MKVToolNix 同一模式：应用不内置推理引擎，
/// 只做 GUI 编排，外部命令完成实际工作：
/// - 检测：`whisper --help`（退出码 0 = 已安装且依赖完整）
/// - 转写：`whisper <媒体> --model <名> --output_format <格式> --output_dir <目录>`
/// - 进度：解析 verbose 时间戳行 `[MM:SS.mmm --> MM:SS.mmm] 文本`
///   （openai-whisper 默认逐段打印到 stdout，取片段结束时间推进进度）
/// - 模型管理：缓存目录 `<name>.pt` 列表 / 删除 / 下载
///   （下载用 0.5 秒静音 WAV 触发 whisper 自动下载机制，比裸 `--model`
///   可靠：CLI 的 audio 参数必填，不带输入会直接参数报错退出）
///
/// 定位顺序：自定义路径（whisper.exe / python.exe / 目录）→ 常见
/// conda/Python Scripts 目录 → 系统 PATH → `python -m whisper`。

/// verbose 时间戳行解析（`[MM:SS.mmm --> MM:SS.mmm]`，超 1 小时带 `HH:`）。
class WhisperProgressParser {
  static final _seg = RegExp(
      r'\[(\d{1,3}:)?(\d{1,2}):(\d{2})[.,](\d{3})\s*-->\s*(?:(\d{1,3}):)?(\d{1,2}):(\d{2})[.,](\d{3})\]');

  Duration? _current;

  /// 当前已转写到的位置（最近片段的结束时间）。
  Duration? get current => _current;

  void feed(String line) {
    final m = _seg.firstMatch(line);
    if (m == null) return;
    final h = int.tryParse(m.group(5)?.replaceAll(':', '') ?? '') ?? 0;
    final min = int.tryParse(m.group(6) ?? '') ?? 0;
    final sec = int.tryParse(m.group(7) ?? '') ?? 0;
    final ms = int.tryParse(m.group(8) ?? '') ?? 0;
    final end = Duration(hours: h, minutes: min, seconds: sec, milliseconds: ms);
    // 时间戳乱序/重复时保留最大值，避免进度回跳
    if (_current == null || end > _current!) _current = end;
  }

  void reset() => _current = null;
}

/// 一个模型在缓存目录中的状态。
class WhisperModelStatus {
  final String name;
  final bool downloaded;
  final int sizeBytes;
  final String path;

  const WhisperModelStatus({
    required this.name,
    required this.downloaded,
    required this.sizeBytes,
    required this.path,
  });
}

/// 实时转写输出状态（值对象）：转写期间逐行累积 stdout，
/// 结束后保留内容，转写页可随时打开反复查看。
class WhisperLiveOutput {
  final String inputName;
  final String model;
  final bool running;
  final DateTime startedAt;
  final List<String> lines;

  /// 行缓冲上限（超长转写防内存膨胀，丢最旧）。
  static const maxLines = 10000;

  const WhisperLiveOutput._({
    required this.inputName,
    required this.model,
    required this.running,
    required this.startedAt,
    required this.lines,
  });

  factory WhisperLiveOutput.start({
    required String inputName,
    required String model,
  }) =>
      WhisperLiveOutput._(
        inputName: inputName,
        model: model,
        running: true,
        startedAt: DateTime.now(),
        lines: const [],
      );

  WhisperLiveOutput appended(String line) {
    final next = [...lines, line];
    final trimmed = next.length > maxLines
        ? next.sublist(next.length - maxLines)
        : next;
    return WhisperLiveOutput._(
      inputName: inputName,
      model: model,
      running: running,
      startedAt: startedAt,
      lines: List.unmodifiable(trimmed),
    );
  }

  WhisperLiveOutput finish() => WhisperLiveOutput._(
        inputName: inputName,
        model: model,
        running: false,
        startedAt: startedAt,
        lines: lines,
      );
}

class WhisperService {
  WhisperService._();

  static final WhisperService instance = WhisperService._();

  static const _transcribeTimeout = Duration(hours: 2);
  static const _downloadTimeout = Duration(minutes: 30);

  String? _whisperCmd;
  List<String> _baseArgs = const [];
  String? _sourceLabel;
  bool _available = false;
  String? _error;
  bool _checked = false;

  /// 实际探测命中的后端（openai / faster）；未检测前为 null。
  WhisperBackend? _activeBackend;

  /// 可用性变化通知（设置页配置后已构建页面实时刷新）。
  final ValueNotifier<bool> availability = ValueNotifier<bool>(false);

  /// 当前生效后端变化通知（VAD 开关仅 faster 可用，转写页监听刷新）。
  final ValueNotifier<WhisperBackend?> activeBackend =
      ValueNotifier<WhisperBackend?>(null);

  /// 检测进行中通知（启动后台检测 / 手动重检时界面显示「检测中」）。
  final ValueNotifier<bool> detecting = ValueNotifier<bool>(false);

  /// 当前/最近一次转写的实时输出（stdout 逐行；结束后保留）。
  final ValueNotifier<WhisperLiveOutput?> liveOutput =
      ValueNotifier<WhisperLiveOutput?>(null);

  /// whisper.cpp 实验性后端可执行检测（v1.3）：命中时设置页下拉
  /// 才显示实验项；纯文件扫描，不启动子进程。
  final ValueNotifier<bool> cppAvailable = ValueNotifier<bool>(false);

  bool get isAvailable => _available;
  String? get sourceLabel => _sourceLabel;
  String? get error => _error;

  /// 当前生效后端（null = 尚未检测 / 不可用）。
  WhisperBackend? get backend => _activeBackend;

  // ───────────────────────── 定位 / 检测 ─────────────────────────

  /// `--help` 探测注入缝（widget/单测避免真实 torch 导入子进程）。
  static Future<ProcessResult> Function(String cmd, List<String> args)?
      probeOverride;

  /// 检测 Whisper（幂等）；设置页修改后调 [configure] 重检。
  ///
  /// 快路径：上次检测结果缓存命中（设置未变 + 可执行文件指纹一致）时
  /// 直接恢复状态、零子进程（`--help` 触发 torch 导入需 10~30s），
  /// 随后后台静默复检一次；复检失败清缓存并转不可用。
  Future<void> init() async {
    if (_checked) return;
    _checked = true;
    _scanCppAvailability();
    if (await _restoreFromCache()) {
      _revalidateInBackground();
      return;
    }
    detecting.value = true;
    try {
      await _detect();
    } finally {
      detecting.value = false;
    }
  }

  /// whisper.cpp 可执行扫描（自定义路径 > PATH 目录；whisper-cli.exe
  /// 全目录优先于 main.exe）。仅置位 [cppAvailable]，不验证可运行。
  void _scanCppAvailability() {
    final configured = StorageService.instance.getSetting(
      StorageService.kWhisperPath,
    );
    final found = findCppExecutable(
      (Platform.environment['PATH'] ?? '')
          .split(Platform.isWindows ? ';' : ':'),
      configured: configured,
    );
    cppAvailable.value = found != null;
  }

  /// 缓存条目 → 字段；未命中/过期返回 false。
  Future<bool> _restoreFromCache() async {
    if (!Platform.isWindows) return false;
    final raw = StorageService.instance
        .getSetting(StorageService.kWhisperDetection);
    if (raw.isEmpty) return false;
    Map<String, dynamic> c;
    try {
      c = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return false;
    }
    // 设置快照比对：路径 / 后端偏好任一变更即过期
    final pathCfg = StorageService.instance
        .getSetting(StorageService.kWhisperPath);
    final prefCfg = StorageService.instance
        .getSetting(StorageService.kWhisperBackend);
    if ((c['pathCfg'] as String? ?? '') != pathCfg) return false;
    if ((c['prefCfg'] as String? ?? '') != prefCfg) return false;
    final backend = WhisperBackend.fromCode(c['backend'] as String?);
    if (backend == WhisperBackend.auto) return false; // 只缓存真实后端
    final cmd = c['cmd'] as String? ?? '';
    if (cmd.isEmpty || !p.isAbsolute(cmd)) return false;
    // 指纹（mtimeMs:size）：文件被替换/更新即过期
    final fp = _fingerprint(cmd);
    if (fp == null || fp != (c['fp'] as String? ?? '')) return false;

    _whisperCmd = cmd;
    _baseArgs = ((c['baseArgs'] as List?) ?? const []).cast<String>();
    _sourceLabel = c['label'] as String?;
    _activeBackend = backend;
    activeBackend.value = backend;
    _available = true;
    _error = null;
    availability.value = true;
    return true;
  }

  /// 可执行文件指纹（mtimeMs:size）；非绝对路径 / 无法 stat 返回 null。
  String? _fingerprint(String cmd) {
    try {
      final st = File(cmd).statSync();
      if (st.type == FileSystemEntityType.notFound) return null;
      return '${st.modified.millisecondsSinceEpoch}:${st.size}';
    } catch (_) {
      return null;
    }
  }

  /// 后台静默复检缓存命中项；失败则清缓存并转不可用。
  void _revalidateInBackground() {
    final cmd = _whisperCmd;
    final backend = _activeBackend;
    if (cmd == null || backend == null) return;
    unawaited(() async {
      final ok = await _tryCommand(cmd, _baseArgs, _sourceLabel ?? '缓存', backend);
      if (ok) return;
      await StorageService.instance
          .setSetting(StorageService.kWhisperDetection, '');
      _available = false;
      _error = '缓存的 Whisper 已失效（复检失败），请在设置页重新检测';
      _whisperCmd = null;
      _activeBackend = null;
      activeBackend.value = null;
      availability.value = false;
      Logger.instance.log('Whisper 缓存复检失败，已清除缓存', tag: 'WHISPER');
    }());
  }

  Future<void> _detect() async {
    if (!Platform.isWindows) {
      _error = 'Whisper 集成仅支持 Windows';
      return;
    }
    final pref = WhisperBackend.fromCode(StorageService.instance.getSetting(
      StorageService.kWhisperBackend,
    ));
    final configured = StorageService.instance.getSetting(
      StorageService.kWhisperPath,
    );

    // auto：openai → faster 顺序；显式选择只探测该后端
    final order = pref == WhisperBackend.auto
        ? [WhisperBackend.openai, WhisperBackend.faster]
        : [pref];
    for (final b in order) {
      if (await _detectBackend(b, configured)) {
        _available = true;
        availability.value = true;
        Logger.instance.log(
          '检测到 Whisper（来源：$_sourceLabel，后端：${b.label}）',
          tag: 'WHISPER',
        );
        await _saveDetectionCache(configured, pref.code);
        return;
      }
    }
    availability.value = false;
    if (pref == WhisperBackend.whisperCpp) {
      _error = '未检测到 whisper.cpp（实验性）：需要 whisper-cli.exe 或 '
          '旧版 main.exe，可在官方 release 下载后在本页指定其路径。';
    } else {
      _error = '未检测到 Whisper（${pref.label}）。'
          '请安装 openai-whisper（pip install -U openai-whisper）或 '
          'faster-whisper（pip install -U faster-whisper-ctranslate2），'
          '或在本页指定可执行文件路径。';
    }
  }

  /// 探测成功后缓存结果（仅绝对路径可指纹；PATH 相对命令不缓存）。
  Future<void> _saveDetectionCache(String pathCfg, String prefCfg) async {
    final cmd = _whisperCmd;
    if (cmd == null || !p.isAbsolute(cmd)) return;
    final fp = _fingerprint(cmd);
    if (fp == null) return;
    await StorageService.instance.setSetting(
      StorageService.kWhisperDetection,
      jsonEncode({
        'cmd': cmd,
        'baseArgs': _baseArgs,
        'backend': _activeBackend?.code,
        'label': _sourceLabel,
        'fp': fp,
        'pathCfg': pathCfg,
        'prefCfg': prefCfg,
      }),
    );
  }

  /// 探测单个后端：自定义路径优先，然后常见 conda/Python Scripts →
  /// PATH → python -m → py -m。
  Future<bool> _detectBackend(WhisperBackend backend, String configured) async {
    if (backend == WhisperBackend.whisperCpp) {
      final found = findCppExecutable(
        (Platform.environment['PATH'] ?? '')
            .split(Platform.isWindows ? ';' : ':'),
        configured: configured,
      );
      return found != null &&
          await _tryCommand(found, const [], 'whisper.cpp', backend);
    }

    if (configured.isNotEmpty) {
      final spec = _resolveCustom(configured, backend);
      return spec != null &&
          await _tryCommand(spec.$1, spec.$2, '自定义路径', backend);
    }

    final exe = backend == WhisperBackend.faster
        ? 'whisper-ctranslate2.exe'
        : 'whisper.exe';
    final module = backend == WhisperBackend.faster
        ? 'whisper_ctranslate2'
        : 'whisper';

    final home = Platform.environment['USERPROFILE'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final candidates = <({String path, String label})>[
      if (home.isNotEmpty) ...[
        (path: p.join(home, 'miniconda3', 'Scripts', exe), label: 'miniconda3'),
        (path: p.join(home, 'anaconda3', 'Scripts', exe), label: 'anaconda3'),
      ],
      if (localAppData.isNotEmpty)
        for (final v in ['Python313', 'Python312', 'Python311', 'Python310'])
          (path: p.join(localAppData, 'Programs', 'Python', v, 'Scripts', exe),
              label: v),
    ];
    for (final c in candidates) {
      if (!File(c.path).existsSync()) continue;
      if (await _tryCommand(c.path, const [], c.label, backend)) return true;
    }
    return await _tryCommand(exe, const [], '系统 PATH', backend) ||
        await _tryCommand('python', ['-m', module], 'python -m', backend) ||
        await _tryCommand('py', ['-m', module], 'py -m', backend);
  }

  /// 自定义路径解析：(可执行文件, 前缀参数)；与 [backend] 不匹配的
  /// 显式 exe 返回 null（如 faster 后端指向 whisper.exe）。
  (String, List<String>)? _resolveCustom(String path, WhisperBackend backend) {
    final clean = path.trim();
    final exe = backend == WhisperBackend.faster
        ? 'whisper-ctranslate2.exe'
        : 'whisper.exe';
    final module = backend == WhisperBackend.faster
        ? 'whisper_ctranslate2'
        : 'whisper';
    if (Directory(clean).existsSync()) {
      return (p.join(clean, exe), const []);
    }
    final base = p.basename(clean).toLowerCase();
    if (base.contains('python')) return (clean, ['-m', module]);
    final marker =
        backend == WhisperBackend.faster ? 'ctranslate2' : 'whisper';
    if (base.contains(marker)) return (clean, const []);
    return null;
  }

  Future<bool> _tryCommand(
    String cmd,
    List<String> base,
    String label,
    WhisperBackend backend,
  ) async {
    try {
      final r = await (probeOverride?.call(cmd, [...base, '--help']) ??
          Process.run(cmd, [...base, '--help'],
              stdoutEncoding: utf8,
              stderrEncoding: utf8,
              environment: _pythonEnv()));
      if (r.exitCode != 0) return false;
      _whisperCmd = cmd;
      _baseArgs = base;
      _sourceLabel = label;
      _activeBackend = backend;
      activeBackend.value = backend;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 保存配置并重新检测（空串清除）。
  Future<void> configure(String? path, String? cacheDir,
      {String? backendCode}) async {
    await StorageService.instance.setSetting(
      StorageService.kWhisperPath,
      (path == null || path.isEmpty) ? '' : path,
    );
    await StorageService.instance.setSetting(
      StorageService.kWhisperCacheDir,
      (cacheDir == null || cacheDir.isEmpty) ? '' : cacheDir,
    );
    await StorageService.instance.setSetting(
      StorageService.kWhisperBackend,
      (backendCode == null || backendCode.isEmpty)
          ? WhisperBackend.auto.code
          : backendCode,
    );
    _checked = false;
    _available = false;
    availability.value = false;
    _sourceLabel = null;
    _error = null;
    _whisperCmd = null;
    _baseArgs = const [];
    _activeBackend = null;
    activeBackend.value = null;
    await init();
  }

  static Map<String, String> _pythonEnv() => {
        ...Platform.environment,
        'PYTHONIOENCODING': 'utf-8',
        'PYTHONUNBUFFERED': '1',
      };

  /// 测试重置：清空检测状态与缓存命中字段（不触存储）。
  @visibleForTesting
  void resetForTesting() {
    _checked = false;
    _available = false;
    _error = null;
    _sourceLabel = null;
    _whisperCmd = null;
    _baseArgs = const [];
    _activeBackend = null;
    availability.value = false;
    activeBackend.value = null;
    detecting.value = false;
    cppAvailable.value = false;
  }

  // ───────────────────────── 模型缓存管理 ─────────────────────────

  /// 实际使用的模型缓存目录：设置的自定义目录 > WHISPER_CACHE_DIR 环境变量
  /// > XDG_CACHE_HOME/whisper > ~/.cache/whisper（openai-whisper 同款优先级）。
  Future<String> cacheDir() async {
    final custom = StorageService.instance.getSetting(
      StorageService.kWhisperCacheDir,
    );
    if (custom.isNotEmpty) return custom;
    return _defaultCacheDir();
  }

  static String _defaultCacheDir() {
    final env = Platform.environment;
    final forced = env['WHISPER_CACHE_DIR'];
    if (forced != null && forced.isNotEmpty) return forced;
    final home = env['USERPROFILE'] ?? env['HOME'] ?? '';
    final xdg = env['XDG_CACHE_HOME'];
    final base = (xdg != null && xdg.isNotEmpty)
        ? xdg
        : p.join(home, '.cache');
    return p.join(base, 'whisper');
  }

  /// 列出全部目录模型及缓存状态。
  Future<List<WhisperModelStatus>> listModels() async {
    final dir = await cacheDir();
    return [
      for (final name in whisperModelInfo.keys)
        _statusOf(dir, name),
    ];
  }

  WhisperModelStatus _statusOf(String dir, String name) {
    final pt = p.join(dir, '$name.pt');
    try {
      final f = File(pt);
      if (f.existsSync()) {
        return WhisperModelStatus(
          name: name,
          downloaded: true,
          sizeBytes: f.lengthSync(),
          path: pt,
        );
      }
    } catch (_) {}
    return WhisperModelStatus(
      name: name,
      downloaded: false,
      sizeBytes: 0,
      path: pt,
    );
  }

  /// 删除缓存模型（.pt 与同名的 .json 元数据）。
  Future<bool> deleteModel(String name) async {
    final dir = await cacheDir();
    var deleted = false;
    for (final f in [p.join(dir, '$name.pt'), p.join(dir, '$name.json')]) {
      try {
        final file = File(f);
        if (file.existsSync()) {
          file.deleteSync();
          deleted = true;
        }
      } catch (_) {}
    }
    return deleted;
  }

  /// 下载/验证模型：0.5 秒静音 WAV 触发 whisper 自带的模型下载与校验
  /// （`whisper <静音> --model X`：audio 必填，裸 `--model` 只会参数报错）。
  /// 成功退出码 0 且 `<缓存>/<模型>.pt` 存在。
  Future<TaskRunResult> downloadModel({
    required String model,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (!_available || _whisperCmd == null) {
      return TaskRunResult(success: false, error: _error ?? 'Whisper 不可用');
    }
    // whisper.cpp（实验性）：ggml 模型走官方脚本下载，不支持本机制
    if (_activeBackend == WhisperBackend.whisperCpp) {
      return const TaskRunResult(
        success: false,
        error: 'whisper.cpp（实验性）不支持自动下载模型：请用官方 '
            'models/download-ggml-model.sh 下载 ggml-*.bin 放入模型缓存目录',
      );
    }
    final cache = await cacheDir();
    final tmp = Directory.systemTemp;
    final wavPath = p.join(tmp.path, 'whisper_silent_${DateTime.now().millisecondsSinceEpoch}.wav');
    final txtPath = p.setExtension(wavPath, '.txt');
    List<String> args(List<String> extra) => [
          ..._baseArgs,
          wavPath,
          '--model', model,
          '--output_format', 'txt',
          '--output_dir', tmp.path,
          '--device', 'cpu',
          if (_activeBackend == WhisperBackend.faster) ...[
            '--compute_type', 'int8',
          ] else ...[
            '--fp16', 'False',
          ],
          ...extra,
        ];
    try {
      await File(wavPath).writeAsBytes(_silentWav(), flush: true);
      final result = await _run(
        args(cache.isEmpty ? const [] : ['--model_dir', cache]),
        onLog: onLog,
        cancelToken: cancelToken,
        timeout: _downloadTimeout,
      );
      if (result == null) {
        return const TaskRunResult(success: false, cancelled: true, error: '已取消');
      }
      if (result != 0) {
        return TaskRunResult(
          success: false,
          error: _friendlyError(result, '模型 $model 下载失败'),
        );
      }
      final pt = p.join(cache, '$model.pt');
      if (!File(pt).existsSync()) {
        return TaskRunResult(
          success: false,
          error: '模型进程正常退出但未找到 $pt',
        );
      }
      return const TaskRunResult(success: true);
    } catch (e) {
      return TaskRunResult(success: false, error: '模型下载异常: $e');
    } finally {
      _deleteQuiet(wavPath);
      _deleteQuiet(txtPath);
    }
  }

  /// 0.5 秒 16kHz 16bit 单声道静音 WAV（最小合法输入）。
  static List<int> _silentWav() {
    const sampleRate = 8000; // 0.5s × 16kHz = 8000 样本
    const bitsPerSample = 16;
    const channels = 1;
    const dataBytes = sampleRate * channels * bitsPerSample ~/ 8;
    final h = ByteData(44);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        h.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    h.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    h.setUint32(16, 16, Endian.little);
    h.setUint16(20, 1, Endian.little); // PCM
    h.setUint16(22, channels, Endian.little);
    h.setUint32(24, 16000, Endian.little);
    h.setUint32(28, 16000 * channels * bitsPerSample ~/ 8, Endian.little);
    h.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    h.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    h.setUint32(40, dataBytes, Endian.little);
    return [...h.buffer.asUint8List(), ...List.filled(dataBytes, 0)];
  }

  // ───────────────────────── 转写 ─────────────────────────

  /// 转写单个媒体文件。输出 `<outputDir>/<输入主名><格式扩展名>`。
  Future<TaskRunResult> transcribe({
    required String inputPath,
    required String outputDir,
    required String model,
    required String outputFormat,
    String? language,
    bool useGpu = false,
    int presetChoice = 1,
    String? initialPrompt,
    String? customParams,
    bool vadFilter = false,
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
    CancelToken? cancelToken,
  }) async {
    if (!_available || _whisperCmd == null) {
      return TaskRunResult(success: false, error: _error ?? 'Whisper 不可用');
    }
    if (!File(inputPath).existsSync()) {
      return TaskRunResult(success: false, error: '输入文件不存在: $inputPath');
    }
    try {
      await Directory(outputDir).create(recursive: true);
    } catch (_) {}

    final cache = await cacheDir();
    final args = [
      ..._baseArgs,
      ...buildArgs(
        inputPath: inputPath,
        outputDir: outputDir,
        model: model,
        outputFormat: outputFormat,
        language: language,
        useGpu: useGpu,
        presetChoice: presetChoice,
        initialPrompt: initialPrompt,
        customParams: customParams,
        cacheDir: cache.isEmpty ? null : cache,
        backend: _activeBackend ?? WhisperBackend.openai,
        vadFilter: vadFilter,
      ),
    ];
    onLog?.call('\$ "$_whisperCmd" ${args.join(' ')}');

    // 实时输出：转写期间 stdout 逐行广播，结束后保留供反复查看
    liveOutput.value = WhisperLiveOutput.start(
      inputName: p.basename(inputPath),
      model: model,
    );

    final parser = WhisperProgressParser();
    final sw = Stopwatch()..start();
    var lastEmitted = Duration.zero;
    final exitCode = await _run(
      args,
      onLog: onLog,
      cancelToken: cancelToken,
      timeout: _transcribeTimeout,
      onStdout: (line) {
        final cur0 = liveOutput.value;
        if (cur0 != null) liveOutput.value = cur0.appended(line);
        parser.feed(line);
        final cur = parser.current;
        // 时间戳推进才上报（节流由队列侧负责）
        if (cur != null && cur > lastEmitted) {
          lastEmitted = cur;
          final elapsed = sw.elapsedMilliseconds;
          onProgress?.call(FfmpegProgress(
            time: cur,
            speed: elapsed > 0 ? cur.inMilliseconds / elapsed : 0,
          ));
        }
      },
    );
    liveOutput.value = liveOutput.value?.finish();
    if (exitCode == null) {
      final cancelled = cancelToken?.isCancelled ?? false;
      return TaskRunResult(
        success: false,
        cancelled: cancelled,
        error: cancelled ? '已取消' : 'Whisper 进程被终止或启动失败',
      );
    }
    if (exitCode != 0) {
      return TaskRunResult(
        success: false,
        error: _friendlyError(exitCode, 'Whisper 转写失败'),
      );
    }
    // 重命名产物：whisper 固定写 `<主名><ext>`，应用侧改为
    // `<主名>_<模型><ext>`（重名追加 _1/_2…）；all 格式逐个处理
    final formats = outputFormat == 'all'
        ? whisperFormatExtension.keys.where((k) => k != 'all')
        : [outputFormat];
    final adopted = <TaskOutputFile>[];
    for (final fmt in formats) {
      final raw = rawOutputPath(
        inputPath: inputPath,
        outputDir: outputDir,
        outputFormat: fmt,
      );
      if (!File(raw).existsSync()) continue;
      final renamed = await adoptOutput(raw, model);
      adopted.add(TaskOutputFile(name: p.basename(renamed), path: renamed));
    }
    if (adopted.isEmpty) {
      return TaskRunResult(
        success: false,
        error: '进程成功退出但未找到输出文件：'
            '${rawOutputPath(inputPath: inputPath, outputDir: outputDir, outputFormat: outputFormat)}',
      );
    }
    return TaskRunResult(success: true, outputs: adopted);
  }

  // ───────────────────────── 参数构建（纯函数，供测试） ─────────────────────────

  /// whisper.cpp 可执行文件名（官方 release：whisper-cli.exe；
  /// 旧版 examples 构建产物：main.exe）。
  static const cppExeNames = ['whisper-cli.exe', 'main.exe'];

  /// 在 [pathDirs]（PATH 目录列表）与自定义路径 [configured] 中查找
  /// whisper.cpp 可执行文件；找不到返回 null。纯函数。
  ///
  /// 优先级：自定义路径 > PATH；同名竞争时 whisper-cli.exe（官方
  /// 现行名）在任何目录都优先于 main.exe。自定义路径为 openai 的
  /// whisper.exe 时拒绝（名字不属于 cpp 可执行）。
  static String? findCppExecutable(List<String> pathDirs,
      {String? configured}) {
    final cfg = configured?.trim() ?? '';
    if (cfg.isNotEmpty) {
      if (Directory(cfg).existsSync()) {
        for (final exe in cppExeNames) {
          final f = p.join(cfg, exe);
          if (File(f).existsSync()) return f;
        }
        return null;
      }
      return cppExeNames.contains(p.basename(cfg).toLowerCase())
          ? cfg
          : null;
    }
    for (final exe in cppExeNames) {
      for (final dir in pathDirs) {
        final clean = dir.trim();
        if (clean.isEmpty) continue;
        final f = p.join(clean, exe);
        if (File(f).existsSync()) return f;
      }
    }
    return null;
  }

  /// openai 模型名 → whisper.cpp ggml 模型文件名：
  /// `base` → `ggml-base.bin`；已带 `ggml-` 前缀原样；裸 `.bin` 去重后补前缀。
  static String cppModelName(String model) {
    final name = model.trim();
    if (name.startsWith('ggml-')) return name;
    final bare = name.endsWith('.bin')
        ? name.substring(0, name.length - '.bin'.length)
        : name;
    return 'ggml-$bare.bin';
  }

  /// 构建 whisper CLI 参数（对齐 WhisperElectron buildArgs）。
  ///
  /// [backend] 差异化分支（v1.2）：faster + CPU 用 `--compute_type int8`
  /// 替代 openai 的 `--fp16 False`（ctranslate2 的 int8 量化即 CPU 提速来源）；
  /// [vadFilter] 仅 faster 后端生效（`--vad_filter true` 静音过滤），
  /// openai-whisper CLI 无此参数，传入会被忽略。
  static List<String> buildArgs({
    required String inputPath,
    required String outputDir,
    required String model,
    required String outputFormat,
    String? language,
    bool useGpu = false,
    int presetChoice = 1,
    String? initialPrompt,
    String? customParams,
    String? cacheDir,
    WhisperBackend backend = WhisperBackend.openai,
    bool vadFilter = false,
  }) {
    // whisper.cpp（v1.3 实验性）：参数面完全不同（-m/-f/-osrt/-of/-ng），
    // 预设 / 初始提示词 / 自定义参数不适用；json/tsv/all 输出以 srt 兜底
    if (backend == WhisperBackend.whisperCpp) {
      final args = <String>[
        '-m',
        (cacheDir?.trim().isNotEmpty ?? false)
            ? p.join(cacheDir!.trim(), cppModelName(model))
            : cppModelName(model),
        '-f', inputPath,
      ];
      final lang = normalizeLanguage(language, model);
      if (lang != null) args.addAll(['-l', lang]);
      if (!useGpu) args.add('-ng');
      const fmtFlag = {'srt': '-osrt', 'vtt': '-ovtt', 'txt': '-otxt'};
      args.add(fmtFlag[outputFormat] ?? '-osrt');
      args.addAll(['-of', p.join(outputDir, p.basenameWithoutExtension(inputPath))]);
      return args;
    }

    final args = <String>[
      inputPath,
      '--model', model,
      '--output_format', outputFormat,
      '--device', useGpu ? 'cuda' : 'cpu',
      '--output_dir', outputDir,
    ];
    final lang = normalizeLanguage(language, model);
    if (lang != null) args.addAll(['--language', lang]);
    final prompt = initialPrompt?.trim() ?? '';
    if (prompt.isNotEmpty) args.addAll(['--initial_prompt', prompt]);
    if (!useGpu) {
      if (backend == WhisperBackend.faster) {
        args.addAll(['--compute_type', 'int8']);
      } else {
        args.addAll(['--fp16', 'False']);
      }
    }
    if (backend == WhisperBackend.faster && vadFilter) {
      args.addAll(['--vad_filter', 'true']);
    }
    final cache = cacheDir?.trim() ?? '';
    if (cache.isNotEmpty) args.addAll(['--model_dir', cache]);

    final preset = presetArgs(presetChoice) ?? '';
    if (preset.isNotEmpty) {
      args.addAll(preset.split(RegExp(r'\s+')).where((s) => s.isNotEmpty));
    }
    if (presetChoice == 6) {
      final custom = customParams?.trim() ?? '';
      if (custom.isNotEmpty) {
        args.addAll(custom.split(RegExp(r'\s+')).where((s) => s.isNotEmpty));
      }
    }
    return args;
  }

  /// `.en` 模型仅识别英文：指定了语言时强制 en（WhisperElectron 同规则）。
  static String? normalizeLanguage(String? language, String model) {
    final lang = (language ?? '').trim();
    if (lang.isEmpty) return null;
    if (model.endsWith('.en')) return 'en';
    return lang;
  }

  /// 检测 NVIDIA GPU（`nvidia-smi -L` 退出码 0）。
  /// 结果仅作 GPU 开关默认建议，用户可手动改。[runner] 为测试注入缝。
  /// [gpuDetectOverride] 为 widget 测试注入缝（避免真实子进程）。
  static Future<bool> Function()? gpuDetectOverride;

  static Future<bool> detectNvidiaGpu({
    Future<ProcessResult> Function(String cmd, List<String> args)? runner,
  }) async {
    if (gpuDetectOverride != null) return gpuDetectOverride!();
    try {
      final r = await (runner?.call('nvidia-smi', const ['-L']) ??
          Process.run('nvidia-smi', const ['-L']));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 从文件主名提取集数（常见放送命名模式，返回数字字符串）：
  /// - `Show - 12 [1080p]`（空格-空格 分隔）
  /// - `MyShow EP03` / `ep3`（不区分大小写）
  /// - `某番第05话` / `第12集`（中文话/集）
  /// 无匹配返回 null。
  static String? extractEpisode(String fileName) {
    final name = fileName.toLowerCase();
    for (final re in [
      RegExp(r'\s-\s(\d{1,4})\b'),
      RegExp(r'\bep\.?(\d{1,4})\b'),
      RegExp(r'第(\d{1,4})[话話集]'),
    ]) {
      final m = re.firstMatch(name);
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// 展开初始提示词模板：`{episode}` → 从输入文件名提取的集数；
  /// 无集数或无占位符时占位符移除 / 原样返回。
  static String expandInitialPrompt(String template, String inputPath) =>
      template.replaceAll(
          '{episode}', extractEpisode(p.basenameWithoutExtension(inputPath)) ?? '');


  /// 预设号 → 附加参数（1..6；未知返回 null）。
  static String? presetArgs(int choice) {
    if (choice < 1 || choice > whisperPresets.length) return null;
    return whisperPresets[choice - 1].args;
  }

  /// 格式 → 输出扩展名（all 以 .srt 为主产物）。
  static String outputExtensionFor(String format) =>
      whisperFormatExtension[format] ?? '.srt';

  /// whisper 原始写出路径：`<outputDir>/<输入主名><扩展名>`
  /// （ResultWriter：`output_dir + basename 去 + "." + extension`）。
  static String rawOutputPath({
    required String inputPath,
    required String outputDir,
    required String outputFormat,
  }) =>
      p.join(outputDir,
          '${p.basenameWithoutExtension(inputPath)}${outputExtensionFor(outputFormat)}');

  /// 目标产物基础名：`<输入主名>_<模型名>`。
  static String buildOutputBase({
    required String inputPath,
    required String model,
  }) =>
      '${p.basenameWithoutExtension(inputPath)}_$model';

  /// 重命名后的预期输出路径（跳过已存在检测用）：
  /// `<outputDir>/<主名>_<模型><扩展名>`。
  static String expectedOutputPath({
    required String inputPath,
    required String outputDir,
    required String outputFormat,
    required String model,
  }) =>
      p.join(outputDir,
          '${buildOutputBase(inputPath: inputPath, model: model)}'
          '${outputExtensionFor(outputFormat)}');

  /// 将 whisper 写出的 `<主名><ext>` 重命名为 `<主名>_<模型><ext>`，
  /// 目标已存在时依次尝试 `_1`、`_2`…。返回最终路径；
  /// 源文件不存在或重命名失败时原样返回。
  static Future<String> adoptOutput(String writtenPath, String model) async {
    final f = File(writtenPath);
    if (!f.existsSync()) return writtenPath;
    final dir = p.dirname(writtenPath);
    final stem = p.basenameWithoutExtension(writtenPath);
    final ext = p.extension(writtenPath);
    final base = '${stem}_$model';
    var candidate = p.join(dir, '$base$ext');
    var i = 1;
    while (candidate != writtenPath && File(candidate).existsSync()) {
      candidate = p.join(dir, '${base}_$i$ext');
      i++;
    }
    if (candidate == writtenPath) return writtenPath;
    try {
      await f.rename(candidate);
      return candidate;
    } catch (_) {
      return writtenPath;
    }
  }

  // ───────────────────────── 进程执行核心 ─────────────────────────

  /// 运行 whisper 子进程。返回退出码；null = 取消/超时/启动失败。
  Future<int?> _run(
    List<String> args, {
    void Function(String line)? onLog,
    void Function(String line)? onStdout,
    CancelToken? cancelToken,
    Duration? timeout,
  }) async {
    if (cancelToken?.isCancelled ?? false) return null;

    Process? process;
    Timer? timer;
    var killed = false;

    void kill() {
      killed = true;
      try {
        process?.kill();
      } catch (_) {}
    }

    void onCancel() => kill();
    cancelToken?.addListener(onCancel);

    Future<void> lines(Stream<List<int>> raw, void Function(String) onLine) =>
        raw
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) {
          for (final seg in line.split('\r')) {
            final s = seg.trim();
            if (s.isEmpty) continue;
            onLine(s);
          }
        });

    try {
      process = await Process.start(
        _whisperCmd!,
        args,
        environment: _pythonEnv(),
      );
      timer = timeout == null
          ? null
          : Timer(timeout, kill);
      final outDone = lines(process.stdout, (s) {
        onStdout?.call(s);
        onLog?.call(s);
      });
      final errDone = lines(process.stderr, (s) => onLog?.call('[stderr] $s'));
      final exitCode = await process.exitCode;
      await outDone;
      await errDone;
      if (killed) return null;
      return exitCode;
    } catch (e) {
      Logger.instance.error('Whisper 进程执行异常', e);
      return null;
    } finally {
      timer?.cancel();
      cancelToken?.removeListener(onCancel);
    }
  }

  static String _friendlyError(int exitCode, String fallback) {
    return '$fallback（退出码 $exitCode）。'
        '若提示模型下载失败请检查网络；若选择 GPU 请确认 CUDA 可用。';
  }

  static void _deleteQuiet(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}
