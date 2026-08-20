import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// 实时转写输出状态：转写期间逐行累积 stdout，结束后保留供反复查看。
void main() {
  group('WhisperLiveOutput', () {
    test('初始状态：running=true，行列表为空且不可变', () {
      final s = WhisperLiveOutput.start(inputName: 'demo.mp4', model: 'small');
      expect(s.running, isTrue);
      expect(s.inputName, 'demo.mp4');
      expect(s.model, 'small');
      expect(s.lines, isEmpty);
      expect(() => s.lines.add('x'), throwsUnsupportedError);
    });

    test('appended：返回新值对象并追加一行', () {
      final s = WhisperLiveOutput.start(inputName: 'demo.mp4', model: 'small')
          .appended('[00:00.000 --> 00:02.000] 你好');
      expect(s.lines, ['[00:00.000 --> 00:02.000] 你好']);
      expect(s.running, isTrue);
    });

    test('finish：running=false 且内容保留（可反复查看）', () {
      final s = WhisperLiveOutput.start(inputName: 'demo.mp4', model: 'small')
          .appended('line')
          .finish();
      expect(s.running, isFalse);
      expect(s.lines, ['line']);
    });

    test('容量上限：超出 maxLines 时丢弃最旧的行', () {
      var s = WhisperLiveOutput.start(inputName: 'a.mp4', model: 'small');
      for (var i = 0; i < WhisperLiveOutput.maxLines + 50; i++) {
        s = s.appended('line$i');
      }
      expect(s.lines.length, WhisperLiveOutput.maxLines);
      expect(s.lines.first, 'line50');
      expect(s.lines.last, 'line${WhisperLiveOutput.maxLines + 49}');
    });
  });
}
