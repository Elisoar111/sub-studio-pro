import 'package:media_kit/media_kit.dart';

/// 本地文件路径 → media_kit 的 [Media]。
///
/// 入参经 [Uri.file] 百分号编码后交给 [Media]；media_kit ≥1.2 在构造时
/// 自行归一化为 libmpv 内部使用的纯文件路径（正斜杠、特殊字符 `#` `%`
/// 中文空格原样保留直传 mpv，不会因 URI 分隔符截断），
/// [Media.uri] 即该归一化结果。
Media mediaFromPath(String path) {
  return Media(Uri.file(path).toString());
}
