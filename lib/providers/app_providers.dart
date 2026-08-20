import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/theme.dart';
import '../models/history_entry.dart';
import '../models/queue_task.dart';
import '../services/ai/translation_service.dart' show GlossaryTerm, kGlossaryMaxTerms;
import '../services/ffmpeg/ffmpeg_service.dart';
import '../services/queue_service.dart';
import '../services/storage_service.dart';

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
  static const _kGlossary = 'ai_glossary';
  static const _kPolishCustomRules = 'ai_polish_custom_rules';

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

  /// AI 翻译：术语表（人名/专名锁定）
  List<GlossaryTerm> _glossary = [];

  /// AI 翻译：润色模式自定义附加指令（v1.3，空 = 仅内置规则）
  String _polishCustomRules = '';

  ThemeMode get themeMode => _themeMode;

  /// 当前主题种子色
  Color get seedColor => _seedColor;

  String get defaultOutputDir => _defaultOutputDir;

  String get filenameTemplate => _filenameTemplate;

  String get aiApiKey => _aiApiKey;

  String get aiBaseUrl => _aiBaseUrl;

  String get aiModel => _aiModel;

  List<GlossaryTerm> get glossary => List.unmodifiable(_glossary);

  String get polishCustomRules => _polishCustomRules;

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
    _polishCustomRules =
        StorageService.instance.getSetting(_kPolishCustomRules);
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

/// 操作历史
final historyProvider = ChangeNotifierProvider<HistoryProvider>(
  (ref) => HistoryProvider.instance,
);

/// 任务队列
final queueProvider = ChangeNotifierProvider<QueueService>(
  (ref) => QueueService.instance,
);
