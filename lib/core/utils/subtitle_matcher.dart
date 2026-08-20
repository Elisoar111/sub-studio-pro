import 'package:path/path.dart' as p;

/// 视频 ↔ 字幕自动匹配结果。
class SubtitleMatchResult {
  final List<(String video, String subtitle)> pairs;
  final List<String> unmatchedVideos;
  final List<String> unmatchedSubtitles;

  const SubtitleMatchResult({
    required this.pairs,
    required this.unmatchedVideos,
    required this.unmatchedSubtitles,
  });
}

/// 单对匹配评分：归一化文件名相等 = 2；一方是另一方前缀 = 1；否则 0。
/// 封装页按类型逐轨配对时使用。
int subtitleMatchScore(String video, String trackFile) {
  String norm(String path) {
    var s = p.basenameWithoutExtension(path).toLowerCase();
    s = s.replaceAll(
      RegExp(
          r'[-_. ](zh|chs|cht|sc|tc|zhs|zht|gb|big5|en|jp|ja|简|繁|简中|繁中|中文|英文|日文|简体|繁体)\s*$'),
      '',
    );
    return s.trim();
  }

  final a = norm(video);
  final b = norm(trackFile);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 2;
  if (a.startsWith('$b.') || b.startsWith('$a.')) return 1;
  return 0;
}

/// 批量烧录自动匹配规则（字幕组常用命名习惯）：
/// 1. 归一化文件名（去扩展名、去语言后缀标记如 .zh/.chs/_cht/-SC）完全相等 → 配对；
/// 2. 剩余视频与字幕数量相等 → 按顺序配对（如 ep01..ep12 各配一个字幕）；
/// 3. 其余进入未匹配列表（页面给出提示）。
SubtitleMatchResult matchSubtitlePairs(
  List<String> videos,
  List<String> subtitles,
) {
  String norm(String path) {
    var s = p.basenameWithoutExtension(path).toLowerCase();
    s = s.replaceAll(
      RegExp(
          r'[-_. ](zh|chs|cht|sc|tc|zhs|zht|gb|big5|en|jp|ja|简|繁|简中|繁中|中文|英文|日文|简体|繁体)\s*$'),
      '',
    );
    return s.trim();
  }

  final pairs = <(String, String)>[];
  final unmatchedSubs = List.of(subtitles);
  final unmatchedVideos = <String>[];

  for (final v in videos) {
    final vn = norm(v);
    final idx = unmatchedSubs.indexWhere((s) => norm(s) == vn);
    if (idx >= 0) {
      pairs.add((v, unmatchedSubs.removeAt(idx)));
    } else {
      unmatchedVideos.add(v);
    }
  }
  // 剩余数量相等时才顺序配对；数量不等时强行配对会把无关字幕烧进视频
  if (unmatchedVideos.length == unmatchedSubs.length) {
    while (unmatchedVideos.isNotEmpty) {
      pairs.add((unmatchedVideos.removeAt(0), unmatchedSubs.removeAt(0)));
    }
  }
  return SubtitleMatchResult(
    pairs: pairs,
    unmatchedVideos: unmatchedVideos,
    unmatchedSubtitles: unmatchedSubs,
  );
}
