import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 翻译内容缓存（v2.2.1）：行文本哈希 → 译文，JSON 文件持久化。
///
/// 命中语义：
/// - 键 = 目标语言 + 原文（trim 归一）的 FNV-1a 64 哈希，跨运行稳定；
/// - 同剧集不同集数的相同台词 / 片头零成本命中；
/// - 不区分模型与词库（追求最大命中率，译文差异可接受）。
///
/// 持久化：应用文档目录 `translate_cache.json`；损坏文件按空缓存重建。
class TranslationCache {
  TranslationCache(this.path);

  /// JSON 文件路径。
  final String path;

  Map<String, String>? _entries;
  bool _dirty = false;

  static String? _defaultPath;

  /// 缓存键：`<lang>:<fnv1a64>`（与 [TranslationCache] 实例无关，纯函数）。
  static String keyFor(String lang, String text) =>
      '$lang:${_fnv1a64('$lang\u0000${text.trim()}')}';

  static String _fnv1a64(String s) {
    var h = 0xcbf29ce484222325;
    for (final cu in s.codeUnits) {
      h ^= cu;
      h *= 0x100000001b3;
    }
    return (h & 0x7fffffffffffffff).toRadixString(16);
  }

  /// 应用级缓存（文档目录）；path_provider 不可用时返回 null（缓存禁用）。
  static Future<TranslationCache?> openDefault() async {
    if (_defaultPath == null) {
      try {
        final dir = await getApplicationDocumentsDirectory();
        _defaultPath = p.join(dir.path, 'translate_cache.json');
      } catch (_) {
        return null;
      }
    }
    return TranslationCache(_defaultPath!);
  }

  /// 查缓存；未命中 / 空译文返回 null。
  Future<String?> get(String lang, String text) async {
    await _ensureLoaded();
    final v = _entries![keyFor(lang, text)];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 写入一条（内存 + 脏标记，落盘见 [flush]）。
  Future<void> put(String lang, String text, String translation) async {
    await _ensureLoaded();
    if (translation.isEmpty) return;
    _entries![keyFor(lang, text)] = translation;
    _dirty = true;
  }

  /// 脏数据落盘；无变更时零开销。
  Future<void> flush() async {
    if (!_dirty || _entries == null) return;
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(jsonEncode(_entries), flush: true);
    _dirty = false;
  }

  Future<void> _ensureLoaded() async {
    if (_entries != null) return;
    _entries = {};
    try {
      final f = File(path);
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map) {
          _entries = {for (final e in j.entries) '${e.key}': '${e.value}'};
        }
      }
    } catch (_) {}
  }
}
