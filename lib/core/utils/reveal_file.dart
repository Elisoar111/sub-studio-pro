import 'dart:io';

import 'package:path/path.dart' as p;

/// 在系统文件管理器中定位文件：
/// - Windows：资源管理器打开所在目录并选中该文件（`explorer /select,`）
/// - macOS：Finder 选中（`open -R`）；Linux：打开所在目录
/// - 文件不存在时退化为打开所在目录
///
/// explorer 退出码不可靠（成功也可能返回 1），故不检查退出码。
Future<void> revealInFileManager(String path) async {
  final exists =
      FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
  final target = exists ? path : p.dirname(path);
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', [
        if (exists) ...['/select,', target] else target,
      ]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [
        if (exists) ...['-R', target] else target,
      ]);
    } else {
      await Process.run('xdg-open', [p.dirname(target)]);
    }
  } catch (_) {}
}
