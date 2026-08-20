import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/progress_parser.dart';

void main() {
  group('FFmpeg -progress 输出解析', () {
    test('out_time_ms 的值是微秒（FFmpeg 历史遗留），不应当毫秒', () {
      final p = ProgressLineParser();
      p.feed('out_time_us=1234567');
      expect(p.progress!.time, const Duration(microseconds: 1234567));
      p.feed('out_time_ms=1234567');
      expect(p.progress!.time, const Duration(microseconds: 1234567),
          reason: 'ffmpeg 的 out_time_ms 实际输出微秒值，'
              '当毫秒会得到 1000 倍时间，进度瞬间 100%');
    });

    test('完整 progress 块行序解析保持单调正确', () {
      final p = ProgressLineParser();
      final times = <Duration>[];
      for (final block in [
        ['out_time_us=500000', 'out_time_ms=500000', 'out_time=00:00:00.500000'],
        ['out_time_us=1000000', 'out_time_ms=1000000', 'out_time=00:00:01.000000'],
      ]) {
        for (final line in block) {
          p.feed(line);
        }
        times.add(p.progress!.time);
      }
      expect(times[0], const Duration(milliseconds: 500));
      expect(times[1], const Duration(seconds: 1));
    });
  });
}
