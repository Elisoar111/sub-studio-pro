/// FFmpeg 滤镜参数中的路径 / 文本转义工具。
///
/// 这是烧录字幕最常踩的坑：Windows 盘符冒号、反斜杠、单引号、
/// 滤镜特殊字符（`:,;[]`）都会让 `subtitles=` / `ass=` 滤镜解析失败。
/// 详见 README「注意事项」。
library;

/// 转义滤镜中使用的**文件路径**。
///
/// 规则（FFmpeg filter 语法）：
/// 1. 反斜杠统一转正斜杠（Windows 下 ffmpeg 可接受）；
/// 2. 单引号 `'` 转义为 `'\''`（滤镜内单引号包围字符串时）；
/// 3. 冒号 `:` 转义为 `\:`（Windows 盘符 `C:` 必须转义）；
/// 4. 整个路径用单引号包围。
///
/// 示例：`C:\Subs\我的 字幕.srt` → `'C\:/Subs/我的 字幕.srt'`
String escapeFilterPath(String path) {
  var s = path.replaceAll('\\', '/');
  s = s.replaceAll("'", r"'\''");
  s = s.replaceAll(':', r'\:');
  return "'$s'";
}

/// 转义滤镜选项中的**字符串值**（如 `force_style` 里的字体名）。
String escapeFilterValue(String value) {
  var s = value.replaceAll('\\', r'\\');
  s = s.replaceAll("'", r"\'");
  s = s.replaceAll(':', r'\:');
  s = s.replaceAll(',', r'\,');
  s = s.replaceAll(';', r'\;');
  return s;
}

/// 构建 `force_style` 参数字符串（键值对用逗号分隔）。
/// 例：`FontSize=20,PrimaryColour=&H00FFFFFF&,OutlineColour=&H00000000&`
String buildForceStyle(Map<String, String> pairs) {
  return pairs.entries
      .map((e) => '${e.key}=${escapeFilterValue(e.value)}')
      .join(',');
}

/// 把用户可见文本安全地放入滤镜字符串（去除换行等）。
String sanitizeFilterText(String text) =>
    text.replaceAll('\n', ' ').replaceAll('\r', ' ');
