import 'package:media_kit/media_kit.dart';

/// 本地文件路径 → media_kit 的 file:// URI。
///
/// Windows 路径 `C:\a\b.mkv` → `file:///C:/a/b.mkv`
/// （media_kit 需要标准 file URI）。
///
/// 必须走 [Uri.file] 做百分号编码：文件名含 `#` `?` `%` 等字符时，
/// 手工拼接的 URI 会被 mpv 当作 fragment/query 分隔符截断，导致播放失败。
Media mediaFromPath(String path) {
  return Media(Uri.file(path).toString());
}
