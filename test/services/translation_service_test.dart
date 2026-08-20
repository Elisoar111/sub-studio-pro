import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

void main() {
  group('双语拼接', () {
    test('SRT 源用真实换行符，不写 ASS 的 \\N', () {
      final joined = TranslationService.bilingualJoin(
        SubtitleFormat.srt,
        '原文文本',
        '译文文本',
      );
      expect(joined, '原文文本\n译文文本');
      expect(joined, isNot(contains(r'\N')),
          reason: 'SRT/VTT/MicroDVD 播放器不解释 ASS 换行记号，'
              '写 \\N 会把反斜杠显示给用户');
    });

    test('ASS 源用 \\N', () {
      final joined = TranslationService.bilingualJoin(
        SubtitleFormat.ass,
        '原文文本',
        '译文文本',
      );
      expect(joined, r'原文文本\N译文文本');
    });
  });
}
