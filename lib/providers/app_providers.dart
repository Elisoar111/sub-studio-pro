import 'dart:convert';

import 'package:flutter/material.dart';
// riverpod 3：ChangeNotifierProvider 移入 legacy 库（本文件仅有此处使用）
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import '../core/theme.dart';
import '../models/ai_profile.dart';
import '../models/history_entry.dart';
import '../models/queue_task.dart';
import '../services/ai/translation_service.dart' show GlossaryTerm, kGlossaryMaxTerms;
import '../services/ffmpeg/ffmpeg_service.dart';
import '../services/queue_service.dart';
import '../services/storage_service.dart';
import '../services/update/update_service.dart';

/// ── Riverpod 状态管理 ──
/// 选型理由：
/// 1. 编译期安全（provider 通过全局常量访问，不依赖 BuildContext）；
/// 2. 异步支持好（FutureProvider / Notifier 等）；
/// 3. 自动管理生命周期，无需手动 dispose。
/// 实现上复用现有 ChangeNotifier 服务（SettingsProvider / HistoryProvider /
/// QueueService），用 ChangeNotifierProvider 暴露，改动最小。

// ───────────────────── 应用设置（主题 + FFmpeg 状态）─────────────────────

class SettingsProvider extends ChangeNotifier {
  SettingsProvider._();

  static final SettingsProvider instance = SettingsProvider._();

  static const _kThemeMode = 'theme_mode';
  static const _kSeedColor = 'theme_seed';
  static const _kDefaultOutputDir = 'default_output_dir';
  static const _kFilenameTemplate = 'filename_template';
  static const _kAiApiKey = 'ai_api_key';
  static const _kAiBaseUrl = 'ai_base_url';
  static const _kAiModel = 'ai_model';
  static const _kAiTimeout = 'ai_timeout_seconds';
  static const _kAiRetries = 'ai_retries';
  static const _kAiConcurrency = 'ai_concurrency';
  static const _kAiProfiles = 'ai_profiles';
  static const _kAiActiveProfile = 'ai_active_profile';
  static const _kGlossary = 'ai_glossary';
  static const _kPolishCustomRules = 'ai_polish_custom_rules';
  static const _kCloseToTray = 'close_to_tray';
  static const _kAutoUpdateCheck = 'auto_update_check';
  static const _kWatchEnabled = 'watch_enabled';
  static const _kWatchDir = 'watch_dir';
  static const _kWatchOutputDir = 'watch_output_dir';

  ThemeMode _themeMode = ThemeMode.system;
  Color _seedColor = AppTheme.defaultSeed;

  /// 全局默认输出目录（空 = 各功能使用应用文档目录下的子目录）
  String _defaultOutputDir = '';

  /// 全局默认文件名模板（空 = 各功能使用内置默认模板）
  String _filenameTemplate = '';

  /// AI 翻译：OpenAI 兼容 API 配置
  String _aiApiKey = '';
  String _aiBaseUrl = '';
  String _aiModel = '';

  /// AI 翻译：网络参数（v2.2.1 设置页可调）——单批请求超时秒数 /
  /// 额外重试次数 / 网络车道并发 worker 数。
  int _aiTimeoutSeconds = 120;
  int _aiRetries = 2;
  int _aiConcurrency = 1;

  /// AI 翻译：多配置档案（v2.2.1）+ 激活档案名（空 = 未启用档案，
  /// 沿用单配置字段）。激活档案始终同步写回单配置字段（TaskRunner 只读单配置）。
  List<AiProfile> _aiProfiles = [];
  String _aiActiveProfile = '';

  /// AI 翻译：术语表（人名/专名锁定）
  List<GlossaryTerm> _glossary = [];

  /// AI 翻译：润色模式自定义附加指令（v1.3，空 = 仅内置规则）
  String _polishCustomRules = '';

  /// 关闭窗口时最小化到系统托盘（v2.0，默认开启；关闭则直接退出）
  bool _closeToTray = true;

  /// 自动检查更新（v2.1.0，默认开启）：运行期间每 6 小时静默检查
  /// GitHub Releases，发现新版本首页横幅提示。
  bool _autoUpdateCheck = true;

  /// 监视文件夹（v2.0 无人值守流水线）：开关 / 监视目录 / 输出目录
  /// （输出目录空 = <监视目录>\burned）。
  bool _watchEnabled = false;
  String _watchDir = '';
  String _watchOutputDir = '';

  ThemeMode get themeMode => _themeMode;

  /// 当前主题种子色
  Color get seedColor => _seedColor;

  String get defaultOutputDir => _defaultOutputDir;

  String get filenameTemplate => _filenameTemplate;

  String get aiApiKey => _aiApiKey;

  String get aiBaseUrl => _aiBaseUrl;

  String get aiModel => _aiModel;

  int get aiTimeoutSeconds => _aiTimeoutSeconds;

  int get aiRetries => _aiRetries;

  int get aiConcurrency => _aiConcurrency;

  List<AiProfile> get aiProfiles => List.unmodifiable(_aiProfiles);

  String get aiActiveProfile => _aiActiveProfile;

  List<GlossaryTerm> get glossary => List.unmodifiable(_glossary);

  String get polishCustomRules => _polishCustomRules;

  bool get closeToTray => _closeToTray;

  bool get autoUpdateCheck => _autoUpdateCheck;

  bool get watchEnabled => _watchEnabled;

  String get watchDir => _watchDir;

  String get watchOutputDir => _watchOutputDir;

  /// AI 翻译配置是否完整
  bool get aiReady =>
      _aiApiKey.trim().isNotEmpty &&
      _aiBaseUrl.trim().isNotEmpty &&
      _aiModel.trim().isNotEmpty;

  /// FFmpeg 检测状态（main 启动时填充，设置页配置后刷新）
  String? ffmpegVersion;
  String? ffmpegError;
  String? ffmpegSource;

  bool get ffmpegReady => ffmpegVersion != null && ffmpegError == null;

  Future<void> load() async {
    final raw = StorageService.instance.getSetting(_kThemeMode);
    switch (raw) {
      case 'light':
        _themeMode = ThemeMode.light;
      case 'dark':
        _themeMode = ThemeMode.dark;
      default:
        _themeMode = ThemeMode.system;
    }
    final seedRaw =
        StorageService.instance.getSetting(_kSeedColor);
    final seedValue = int.tryParse(seedRaw);
    if (seedValue != null && seedValue >= 0xFF000000) {
      _seedColor = Color(seedValue);
    }
    _defaultOutputDir =
        StorageService.instance.getSetting(_kDefaultOutputDir);
    _filenameTemplate =
        StorageService.instance.getSetting(_kFilenameTemplate);
    _aiApiKey = StorageService.instance.getSetting(_kAiApiKey);
    _aiBaseUrl = StorageService.instance.getSetting(
      _kAiBaseUrl,
      fallback: 'https://api.openai.com',
    );
    _aiModel = StorageService.instance.getSetting(_kAiModel);
    int loadInt(String key, int def, {required int min, required int max}) {
      final v = int.tryParse(StorageService.instance.getSetting(key));
      if (v == null || v < min || v > max) return def;
      return v;
    }

    _aiTimeoutSeconds =
        loadInt(_kAiTimeout, 120, min: 10, max: 600);
    _aiRetries = loadInt(_kAiRetries, 2, min: 0, max: 5);
    _aiConcurrency = loadInt(_kAiConcurrency, 1, min: 1, max: 4);
    // v2.2.1 档案：损坏数据按无档案处理（沿用单配置字段）
    try {
      final raw = StorageService.instance.getSetting(_kAiProfiles);
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          _aiProfiles = [
            for (final e in decoded)
              if (e is Map) AiProfile.fromJson(e.cast<String, dynamic>()),
          ];
        }
      }
    } catch (_) {
      _aiProfiles = [];
    }
    _aiActiveProfile =
        StorageService.instance.getSetting(_kAiActiveProfile);
    if (_aiProfiles.isNotEmpty && !_aiProfiles.any((p) => p.name == _aiActiveProfile)) {
      _aiActiveProfile = _aiProfiles.first.name;
    }
    if (_aiProfiles.isEmpty) _aiActiveProfile = '';
    // 激活档案优先于单配置字段（旧值仅作档案为空时的回退）
    _syncSingleFromActiveProfile();
    _polishCustomRules =
        StorageService.instance.getSetting(_kPolishCustomRules);
    _closeToTray = StorageService.instance.getSetting(
      _kCloseToTray,
      fallback: 'true',
    ) != 'false';
    _autoUpdateCheck = StorageService.instance.getSetting(
      _kAutoUpdateCheck,
      fallback: 'true',
    ) != 'false';
    _watchEnabled =
        StorageService.instance.getSetting(_kWatchEnabled) == 'true';
    _watchDir = StorageService.instance.getSetting(_kWatchDir);
    _watchOutputDir = StorageService.instance.getSetting(_kWatchOutputDir);
    final glossaryRaw = StorageService.instance.getSetting(_kGlossary);
    if (glossaryRaw.isNotEmpty) {
      try {
        final decoded = jsonDecode(glossaryRaw);
        if (decoded is List) {
          _glossary = [
            for (final e in decoded)
              if (e is Map) GlossaryTerm.fromJson(e.cast<String, dynamic>()),
          ];
        }
      } catch (_) {
        // 损坏数据直接忽略，按空术语表处理
      }
    }
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    final raw = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
            ? 'dark'
            : 'system';
    await StorageService.instance.setSetting(_kThemeMode, raw);
  }

  /// 切换主题种子色（即时生效，无需重启）。
  Future<void> setSeedColor(Color color) async {
    if (_seedColor == color) return;
    _seedColor = color;
    notifyListeners();
    await StorageService.instance
        .setSetting(_kSeedColor, '${color.toARGB32()}');
  }

  /// 设置全局默认输出目录（空字符串 = 恢复应用默认）。
  Future<void> setDefaultOutputDir(String dir) async {
    _defaultOutputDir = dir;
    notifyListeners();
    await StorageService.instance.setSetting(_kDefaultOutputDir, dir);
  }

  /// 设置全局默认文件名模板（空字符串 = 恢复内置默认）。
  Future<void> setFilenameTemplate(String template) async {
    _filenameTemplate = template;
    notifyListeners();
    await StorageService.instance.setSetting(_kFilenameTemplate, template);
  }

  /// 保存 AI 翻译 API 配置（OpenAI 兼容）。
  Future<void> setAiConfig({
    required String apiKey,
    required String baseUrl,
    required String model,
  }) async {
    _aiApiKey = apiKey.trim();
    _aiBaseUrl = baseUrl.trim();
    _aiModel = model.trim();
    notifyListeners();
    await StorageService.instance.setSetting(_kAiApiKey, _aiApiKey);
    await StorageService.instance.setSetting(_kAiBaseUrl, _aiBaseUrl);
    await StorageService.instance.setSetting(_kAiModel, _aiModel);
  }

  /// 激活档案 → 单配置字段（TaskRunner / 翻译页只读单配置，
  /// 保持旧路径零改动；档案为空或激活名无效时不覆盖）。
  void _syncSingleFromActiveProfile() {
    if (_aiProfiles.isEmpty) return;
    AiProfile? active;
    for (final p in _aiProfiles) {
      if (p.name == _aiActiveProfile) {
        active = p;
        break;
      }
    }
    if (active == null) return;
    _aiApiKey = active.apiKey;
    _aiBaseUrl = active.baseUrl;
    _aiModel = active.model;
  }

  /// 保存配置档案列表（v2.2.1）：重名抛 [ArgumentError]；
  /// 激活档案缺失时默认激活首个；单配置字段随激活档案同步。
  Future<void> setAiProfiles(List<AiProfile> profiles) async {
    final names = <String>{};
    for (final p in profiles) {
      if (!names.add(p.name)) {
        throw ArgumentError('配置档案重名：${p.name}');
      }
    }
    _aiProfiles = List.of(profiles);
    if (_aiProfiles.isEmpty) {
      _aiActiveProfile = '';
    } else if (!_aiProfiles.any((p) => p.name == _aiActiveProfile)) {
      _aiActiveProfile = _aiProfiles.first.name;
    }
    _syncSingleFromActiveProfile();
    notifyListeners();
    await StorageService.instance.setSetting(
        _kAiProfiles, jsonEncode([for (final p in _aiProfiles) p.toJson()]));
    await StorageService.instance
        .setSetting(_kAiActiveProfile, _aiActiveProfile);
    await StorageService.instance.setSetting(_kAiApiKey, _aiApiKey);
    await StorageService.instance.setSetting(_kAiBaseUrl, _aiBaseUrl);
    await StorageService.instance.setSetting(_kAiModel, _aiModel);
  }

  /// 切换激活档案（v2.2.1）：不存在的名字忽略；
  /// 单配置字段同步覆盖（含持久化，重启后保持）。
  Future<void> switchAiProfile(String name) async {
    if (!_aiProfiles.any((p) => p.name == name)) return;
    _aiActiveProfile = name;
    _syncSingleFromActiveProfile();
    notifyListeners();
    await StorageService.instance.setSetting(_kAiActiveProfile, name);
    await StorageService.instance.setSetting(_kAiApiKey, _aiApiKey);
    await StorageService.instance.setSetting(_kAiBaseUrl, _aiBaseUrl);
    await StorageService.instance.setSetting(_kAiModel, _aiModel);
  }

  /// 保存 AI 网络参数（v2.2.1）：超时秒数（10–600，非法回退 120）、
  /// 额外重试次数（0–5）、网络车道并发 worker 数（1–4），范围外取边界。
  Future<void> setAiNetworkParams({
    int? timeoutSeconds,
    int? retries,
    int? concurrency,
  }) async {
    final t = timeoutSeconds ?? _aiTimeoutSeconds;
    _aiTimeoutSeconds = t >= 10 && t <= 600 ? t : 120;
    _aiRetries = (retries ?? _aiRetries).clamp(0, 5);
    _aiConcurrency = (concurrency ?? _aiConcurrency).clamp(1, 4);
    notifyListeners();
    await StorageService.instance.setSetting(_kAiTimeout, '$_aiTimeoutSeconds');
    await StorageService.instance.setSetting(_kAiRetries, '$_aiRetries');
    await StorageService.instance
        .setSetting(_kAiConcurrency, '$_aiConcurrency');
  }

  /// 保存术语表（人名/专名锁定，翻译时注入 prompt；上限 [kGlossaryMaxTerms]）。
  Future<void> setGlossary(List<GlossaryTerm> terms) async {
    _glossary = terms.length > kGlossaryMaxTerms
        ? terms.sublist(0, kGlossaryMaxTerms)
        : List.of(terms);
    notifyListeners();
    await StorageService.instance.setSetting(
      _kGlossary,
      jsonEncode([for (final t in _glossary) t.toJson()]),
    );
  }

  /// 保存润色模式自定义附加指令（空字符串 = 恢复内置规则）。
  Future<void> setPolishCustomRules(String rules) async {
    _polishCustomRules = rules;
    notifyListeners();
    await StorageService.instance.setSetting(_kPolishCustomRules, rules);
  }

  /// 设置关闭窗口行为：true = 最小化到托盘，false = 直接退出。
  Future<void> setCloseToTray(bool value) async {
    if (_closeToTray == value) return;
    _closeToTray = value;
    notifyListeners();
    await StorageService.instance.setSetting(_kCloseToTray, '$value');
  }

  /// 设置自动检查更新（v2.1.0）：开 = 启动每 6 小时的静默检查，
  /// 关 = 停止定时器；保存后即时生效，无需重启。
  Future<void> setAutoUpdateCheck(bool value) async {
    if (_autoUpdateCheck == value) return;
    _autoUpdateCheck = value;
    notifyListeners();
    if (value) {
      startPeriodicUpdateCheck();
    } else {
      stopPeriodicUpdateCheck();
    }
    await StorageService.instance.setSetting(_kAutoUpdateCheck, '$value');
  }

  /// 保存监视文件夹配置（v2.0）；调用方随后需触发
  /// `WatchFolderService.instance.syncFromSettings()` 让监视即时生效。
  Future<void> setWatchConfig({
    bool? enabled,
    String? dir,
    String? outputDir,
  }) async {
    if (enabled != null) _watchEnabled = enabled;
    if (dir != null) _watchDir = dir.trim();
    if (outputDir != null) _watchOutputDir = outputDir.trim();
    notifyListeners();
    await StorageService.instance.setSetting(_kWatchEnabled, '$_watchEnabled');
    await StorageService.instance.setSetting(_kWatchDir, _watchDir);
    await StorageService.instance.setSetting(_kWatchOutputDir, _watchOutputDir);
  }

  /// 刷新 FFmpeg 检测状态（设置页保存新路径后调用）。
  Future<void> refreshFfmpegStatus() async {
    final runner = FfmpegService.instance.runner;
    if (runner.isAvailable) {
      ffmpegVersion = await runner.getVersion();
      ffmpegError = null;
      ffmpegSource = runner.sourceLabel;
    } else {
      ffmpegVersion = null;
      ffmpegError = runner.initError ?? 'FFmpeg 不可用';
      ffmpegSource = null;
    }
    notifyListeners();
  }
}

// ───────────────────── 操作历史 ─────────────────────

class HistoryProvider extends ChangeNotifier {
  HistoryProvider._();

  static final HistoryProvider instance = HistoryProvider._();

  List<HistoryEntry> _entries = [];

  List<HistoryEntry> get entries => List.unmodifiable(_entries);

  Future<void> load() async {
    _entries = StorageService.instance.loadHistory();
    notifyListeners();
  }

  Future<void> add(HistoryEntry entry) async {
    await StorageService.instance.saveHistoryEntry(entry);
    _entries = StorageService.instance.loadHistory();
    notifyListeners();
  }

  /// 任务队列结束时自动记录（取消的任务不记录）。
  Future<void> addFromTask(QueueTask task) async {
    if (task.status == TaskStatus.cancelled) return;
    await add(historyEntryFromTask(task));
  }

  Future<void> remove(String id) async {
    await StorageService.instance.deleteHistoryEntry(id);
    _entries = StorageService.instance.loadHistory();
    notifyListeners();
  }

  Future<void> clear() async {
    await StorageService.instance.clearHistory();
    _entries = [];
    notifyListeners();
  }
}

// ───────────────────── Riverpod providers ─────────────────────

/// 应用设置 / 主题 / FFmpeg 状态
final settingsProvider = ChangeNotifierProvider<SettingsProvider>(
  (ref) => SettingsProvider.instance,
);

/// 启动参数带入的字幕文件路径（v1.5 文件关联：双击字幕文件打开应用，
/// main 里用 [subtitleFilesFromArgs] 的结果覆盖；字幕库消费后播种列表，
/// HomeShell 据此自动切到字幕库页）。
final startupSubtitleFilesProvider = Provider<List<String>>(
  (ref) => const [],
);

/// 操作历史
final historyProvider = ChangeNotifierProvider<HistoryProvider>(
  (ref) => HistoryProvider.instance,
);

/// 任务队列
final queueProvider = ChangeNotifierProvider<QueueService>(
  (ref) => QueueService.instance,
);
