import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../core/utils/logger.dart';
import '../models/history_entry.dart';

/// 简易 KV 抽象：Hive 持久化，失败时回退内存（Web 无后端时）。
abstract class KVStore {
  List<String> get keys;
  dynamic get(String key);
  Future<void> put(String key, dynamic value);
  Future<void> delete(String key);
  Future<void> clear();
}

class HiveKVStore implements KVStore {
  HiveKVStore(this._box);
  final Box _box;

  @override
  List<String> get keys => _box.keys.cast<String>().toList();

  @override
  dynamic get(String key) => _box.get(key);

  @override
  Future<void> put(String key, dynamic value) => _box.put(key, value);

  @override
  Future<void> delete(String key) => _box.delete(key);

  @override
  Future<void> clear() => _box.clear();
}

class MemoryKVStore implements KVStore {
  final Map<String, dynamic> _data = {};

  @override
  List<String> get keys => _data.keys.toList();

  @override
  dynamic get(String key) => _data[key];

  @override
  Future<void> put(String key, dynamic value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<void> clear() async => _data.clear();
}

/// 本地存储：历史记录 / 设置（Hive，跨平台）。
/// 选择 Hive 而非 sqflite 的理由：
/// - 数据结构为简单 KV/列表，无需 SQL 关系能力；
/// - 纯 Dart 实现，Android/iOS/桌面/Web 开箱即用（sqflite 不支持 Web）；
/// - 读写为毫秒级，无需异步线程管理。
class StorageService {
  StorageService._();

  static final StorageService instance = StorageService._();

  /// 设置项键名：自定义 FFmpeg / FFprobe 可执行文件路径（空 = 自动：捆绑版 → PATH）
  static const String kFfmpegPath = 'ffmpeg_path';
  static const String kFfprobePath = 'ffprobe_path';

  /// MKVToolNix 目录（空 = 自动：捆绑版 → 应用内导入 → 常见安装路径 → PATH）
  static const String kMkvtoolnixDir = 'mkvtoolnix_dir';

  /// Whisper 可执行文件路径（空 = 自动：conda/Python Scripts → PATH → python -m）
  static const String kWhisperPath = 'whisper_path';

  /// Whisper 模型缓存目录（空 = openai-whisper 默认 ~/.cache/whisper）
  static const String kWhisperCacheDir = 'whisper_cache_dir';

  /// Whisper 后端偏好（auto / openai / faster；空 = auto）
  static const String kWhisperBackend = 'whisper_backend';

  KVStore? _history;
  KVStore? _settings;
  bool _ready = false;

  bool get ready => _ready;

  Future<void> init() async {
    if (_ready) return;
    try {
      try {
        // hive_flutter 的 initFlutter 依赖插件初始化时机，这里直接用
        // path_provider 获取文档目录后同步初始化 Hive（更可控）。
        final dir = await getApplicationDocumentsDirectory();
        Hive.init(dir.path);
      } catch (_) {
        try {
          Hive.init('');
        } catch (_) {}
      }
      _history = await _openBox(AppConstants.boxHistory);
      _settings = await _openBox(AppConstants.boxSettings);
    } catch (e) {
      Logger.instance.error('Hive 初始化失败，回退内存存储', e);
      _history = MemoryKVStore();
      _settings = MemoryKVStore();
    }
    _ready = true;
  }

  Future<KVStore> _openBox(String name) async {
    try {
      return HiveKVStore(await Hive.openBox(name));
    } catch (e) {
      Logger.instance.error('打开 Hive Box 失败: $name', e);
      return MemoryKVStore();
    }
  }

  // ─────────────────────── 历史记录 ───────────────────────

  List<HistoryEntry> loadHistory() {
    final store = _history;
    if (store == null) return const [];
    final list = store.keys.map((k) {
      final raw = store.get(k);
      if (raw is String) {
        try {
          return HistoryEntry.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        } catch (_) {
          return null;
        }
      }
      if (raw is Map) {
        try {
          return HistoryEntry.fromJson(Map<String, dynamic>.from(raw));
        } catch (_) {
          return null;
        }
      }
      return null;
    }).whereType<HistoryEntry>().toList();
    list.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return list;
  }

  Future<void> saveHistoryEntry(HistoryEntry entry) async {
    final store = _history;
    if (store == null) return;
    await store.put(entry.id, jsonEncode(entry.toJson()));
    // 容量控制
    final keys = store.keys.toList();
    if (keys.length > AppConstants.maxHistoryEntries) {
      final toRemove = keys.length - AppConstants.maxHistoryEntries;
      for (var i = 0; i < toRemove && i < keys.length; i++) {
        await store.delete(keys[i]);
      }
    }
  }

  Future<void> deleteHistoryEntry(String id) async {
    await _history?.delete(id);
  }

  Future<void> clearHistory() async {
    await _history?.clear();
  }

  // ─────────────────────── 设置 ───────────────────────

  String getSetting(String key, {String fallback = ''}) =>
      _settings?.get(key) as String? ?? fallback;

  Future<void> setSetting(String key, String value) async {
    await _settings?.put(key, value);
  }
}
