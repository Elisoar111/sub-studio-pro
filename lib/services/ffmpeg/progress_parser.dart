import 'ffmpeg_runner.dart';

/// 从 `-progress pipe:1` 输出解析进度。
///
/// ffmpeg 的 `-progress` 会输出如下 key=value 行：
/// ```
/// out_time_us=12345678
/// out_time_ms=12345
/// out_time=00:00:12.345000
/// frame=296
/// fps=29.97
/// speed=1.24x
/// progress=continue|end
/// ```
/// 该解析器作为 Statistics 回调的补充（某些构建下 stdout 会进入日志流）。
class ProgressLineParser {
  Duration? _time;
  int _frame = 0;
  double _fps = 0;
  double _speed = 0;

  bool get hasTime => _time != null;

  void feed(String line) {
    final t = line.trim();
    if (t.isEmpty) return;

    var m = RegExp(r'^out_time_us=(\d+)$').firstMatch(t);
    if (m != null) {
      _time = Duration(microseconds: int.parse(m.group(1)!));
      return;
    }
    m = RegExp(r'^out_time_ms=(\d+)$').firstMatch(t);
    if (m != null) {
      // 历史遗留：ffmpeg 的 out_time_ms 实际输出微秒（与 out_time_us 同值），
      // 当毫秒会得到 1000 倍时间，进度瞬间跳 100%
      _time = Duration(microseconds: int.parse(m.group(1)!));
      return;
    }
    m = RegExp(r'^out_time=(\d+):(\d+):([\d.]+)$').firstMatch(t);
    if (m != null) {
      final h = int.parse(m.group(1)!);
      final min = int.parse(m.group(2)!);
      final sec = double.parse(m.group(3)!);
      _time = Duration(
          hours: h, minutes: min, seconds: sec.toInt(),
          milliseconds: ((sec - sec.toInt()) * 1000).round());
      return;
    }
    m = RegExp(r'^frame=(\d+)$').firstMatch(t);
    if (m != null) {
      _frame = int.parse(m.group(1)!);
      return;
    }
    m = RegExp(r'^fps=([\d.]+)$').firstMatch(t);
    if (m != null) {
      _fps = double.parse(m.group(1)!);
      return;
    }
    m = RegExp(r'^speed=([\d.]+)x$').firstMatch(t);
    if (m != null) {
      _speed = double.parse(m.group(1)!);
      return;
    }
  }

  void reset() {
    _time = null;
    _frame = 0;
    _fps = 0;
    _speed = 0;
  }

  /// 当前解析到的进度；尚无时间信息时返回 null。
  FfmpegProgress? get progress =>
      _time == null ? null : FfmpegProgress(
          time: _time!, frame: _frame, fps: _fps, speed: _speed);
}
