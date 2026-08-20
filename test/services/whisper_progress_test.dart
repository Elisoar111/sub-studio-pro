import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_runner.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// Whisper verbose 输出解析：`[MM:SS.mmm --> MM:SS.mmm] 文本`（超 1 小时带 HH:）。
/// openai-whisper transcribe.py L478-482，verbose 默认开启，逐段打印到 stdout。
void main() {
  group('WhisperProgressParser', () {
    test('分钟级时间戳：取片段结束时间', () {
      final p = WhisperProgressParser();
      p.feed('[00:05.000 --> 00:10.500] 你好世界');
      expect(p.current, const Duration(seconds: 10, milliseconds: 500));
    });

    test('小时级时间戳（超 1 小时音频）', () {
      final p = WhisperProgressParser();
      p.feed('[01:02:03.400 --> 01:02:05.600] hello');
      expect(
        p.current,
        const Duration(hours: 1, minutes: 2, seconds: 5, milliseconds: 600),
      );
    });

    test('非时间戳行不推进进度', () {
      final p = WhisperProgressParser();
      p.feed('[00:05.000 --> 00:10.500] a');
      p.feed('Detected language: Chinese');
      p.feed('100%|██████████| 3.05G/3.05G [02:31<00:00, 20.2MiB/s]');
      expect(p.current, const Duration(seconds: 10, milliseconds: 500));
    });

    test('进度单调不减（时间戳乱序/重复时保留最大值）', () {
      final p = WhisperProgressParser();
      p.feed('[00:20.000 --> 00:25.000] b');
      p.feed('[00:01.000 --> 00:02.000] a');
      p.feed('[00:24.000 --> 00:25.000] c');
      expect(p.current, const Duration(seconds: 25));
    });

    test('reset 清零', () {
      final p = WhisperProgressParser();
      p.feed('[00:05.000 --> 00:10.500] a');
      p.reset();
      expect(p.current, isNull);
    });

    test('时间戳换算完成度（fractionOf）', () {
      final p = WhisperProgressParser();
      p.feed('[00:30.000 --> 01:00.000] x');
      final frac = FfmpegProgress(time: p.current!)
          .fractionOf(const Duration(minutes: 2));
      expect(frac, closeTo(0.5, 0.001));
    });

    test('毫秒分隔符兼容（[.,]）', () {
      final p = WhisperProgressParser();
      p.feed('[00:05.000 --> 00:10,500] x');
      expect(p.current, const Duration(seconds: 10, milliseconds: 500));
    });
  });
}
