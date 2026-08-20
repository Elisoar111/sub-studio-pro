/// 时间 / 字节格式化工具。
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// 完整时长：`HH:MM:SS.mmm`（字幕时间戳风格）
String formatFullTimestamp(Duration d) {
  final ms = d.inMilliseconds;
  final h = ms ~/ 3600000;
  final m = (ms % 3600000) ~/ 60000;
  final s = (ms % 60000) ~/ 1000;
  final millis = ms % 1000;
  return '${_two(h)}:${_two(m)}:${_two(s)}.${millis.toString().padLeft(3, '0')}';
}

/// 短时长：`MM:SS`（播放器进度条用）
String formatClock(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  return h > 0 ? '$h:${_two(m)}:${_two(s)}' : '${_two(m)}:${_two(s)}';
}

/// 人性化字节大小：`1.23 MB`
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  var i = -1;
  do {
    v /= 1024;
    i++;
  } while (v >= 1024 && i < units.length - 1);
  return '${v.toStringAsFixed(v >= 100 ? 0 : 1)} ${units[i]}';
}

/// 根据进度与速度估算剩余时间，返回人性化文本。
String formatEta(double? progress, double? speedX) {
  if (progress == null || progress <= 0 || progress >= 1) return '--';
  final speed = speedX ?? 1.0;
  if (speed <= 0) return '--';
  // 已用时间未知时无法精确估算，这里用剩余比例与速度估算（速度≈实时倍率）。
  final remainingRatio = (1 - progress) / progress;
  final seconds = (remainingRatio * 30 / speed).round(); // 按"已过 30s"的近似推导
  if (seconds <= 0) return '即将完成';
  return '约 ${formatClock(Duration(seconds: seconds))}';
}
