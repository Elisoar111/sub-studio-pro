import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'translation_service.dart' show GlossaryTerm, kGlossaryMaxTerms;

/// 术语表旁车存储（v1.3）：`.glossary.json` 跟随字幕所在目录，
/// 同目录下多任务（翻译/重译/其他字幕）共享一份项目级词库。
///
/// 合并语义：旁车条目与全局词库同 source 时**旁车优先**（项目目录
/// 覆盖全局默认），不同 source 叠加；合并结果受 [kGlossaryMaxTerms]
/// 约束，超限时旁车条目优先保留。
class GlossaryStore {
  GlossaryStore._();

  /// 旁车文件名（固定，位于字幕/项目目录下）。
  static const String fileName = '.glossary.json';

  static String pathFor(String dir) => p.join(dir, fileName);

  /// 读取目录旁车词库；不存在 / JSON 损坏 / 字段缺失均返回空列表。
  static List<GlossaryTerm> load(String dir) => loadFile(pathFor(dir));

  /// 读取任意词库 JSON 文件（旁车或导出的副本）。
  static List<GlossaryTerm> loadFile(String path) {
    final file = File(path);
    if (!file.existsSync()) return const [];
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      // 兼容两种形态：{"terms":[...]} 包装 与 顶层 [...]
      final List raw = decoded is Map
          ? (decoded['terms'] as List? ?? const [])
          : (decoded is List ? decoded : const []);
      return [
        for (final e in raw)
          if (e is Map &&
              ((e['source'] ?? '') as String).trim().isNotEmpty)
            GlossaryTerm(
              source: ((e['source'] ?? '') as String).trim(),
              translation: ((e['translation'] ?? '') as String).trim(),
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 写入目录旁车词库（覆盖式）。
  static Future<void> save(String dir, List<GlossaryTerm> terms) async {
    final file = File(pathFor(dir));
    await file.writeAsString(jsonEncode({
      'terms': [for (final t in terms) t.toJson()],
    }));
  }

  /// 全局词库 + 旁车词库合并：旁车同 source 覆盖全局；受
  /// [kGlossaryMaxTerms] 上限约束，超限时旁车条目优先保留。
  static List<GlossaryTerm> merge({
    required List<GlossaryTerm> global,
    required List<GlossaryTerm> sidecar,
  }) {
    if (sidecar.isEmpty) return global;
    final bySource = {for (final t in global) t.source: t};
    for (final t in sidecar) {
      bySource[t.source] = t;
    }
    final sidecarSet = sidecar.toSet();
    final sidecarTerms = [
      for (final t in bySource.values)
        if (sidecarSet.contains(t)) t,
    ];
    final rest = [
      for (final t in bySource.values)
        if (!sidecarSet.contains(t)) t,
    ];
    final merged = [...sidecarTerms, ...rest];
    return merged.length > kGlossaryMaxTerms
        ? merged.sublist(0, kGlossaryMaxTerms)
        : merged;
  }

  /// 文件级便捷入口：取 [filePath] 所在目录旁车并与 [global] 合并。
  static List<GlossaryTerm> mergedFor(
      String filePath, List<GlossaryTerm> global) {
    return merge(global: global, sidecar: load(p.dirname(filePath)));
  }
}
