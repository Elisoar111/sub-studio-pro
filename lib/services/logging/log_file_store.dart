import 'dart:convert';
import 'dart:io';

/// 结构化日志落盘：JSON Lines 追加写入 + 按大小轮转。
///
/// 当前文件 `app.log`，轮转后 `app.1.log`、`app.2.log`…（数字越大越老），
/// 总文件数（含当前）超过 [maxFiles] 时删除最老。
class LogFileStore {
  LogFileStore(this.directory, {this.maxBytesPerFile = 2 * 1024 * 1024, this.maxFiles = 5}) {
    if (!directory.existsSync()) directory.createSync(recursive: true);
  }

  static const _baseName = 'app.log';

  final Directory directory;
  final int maxBytesPerFile;
  final int maxFiles;

  File get _current =>
      File('${directory.path}${Platform.pathSeparator}$_baseName');

  File _rotated(int n) => File(
      '${directory.path}${Platform.pathSeparator}app.$n.log');

  /// 追加一条 JSON 记录；当前文件超过大小阈值时先轮转。
  void write(Map<String, Object?> record) {
    final current = _current;
    if (current.existsSync() && current.lengthSync() >= maxBytesPerFile) {
      _rotate();
    }
    current.writeAsStringSync('${jsonEncode(record)}\n',
        mode: FileMode.append);
  }

  void _rotate() {
    final oldest = _rotated(maxFiles - 1);
    if (oldest.existsSync()) oldest.deleteSync();
    for (var n = maxFiles - 2; n >= 1; n--) {
      final src = _rotated(n);
      if (src.existsSync()) src.renameSync(_rotated(n + 1).path);
    }
    if (_current.existsSync()) {
      _current.renameSync(_rotated(1).path);
    }
  }
}
