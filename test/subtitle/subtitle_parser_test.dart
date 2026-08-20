import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/subtitle/subtitle_parser.dart';

void main() {
  group('SSA v4 (Marked 格式) 解析', () {
    test('Dialogue 行应解析出 cue 而不是被静默丢弃', () {
      const ssa = '[Script Info]\n'
          'ScriptType: v4.00\n\n'
          '[V4 Styles]\n'
          'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
          'TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, '
          'Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding\n'
          'Style: Default,Arial,16,0,16777215,16777215,0,-1,0,1,1,0,2,10,10,10,0,1\n\n'
          '[Events]\n'
          'Format: Marked, Start, End, Style, Name, MarginL, MarginR, '
          'MarginV, Effect, Text\n'
          'Dialogue: Marked=0,0:00:01.00,0:00:03.00,Default,,0,0,0,,你好世界\n'
          'Dialogue: Marked=0,0:00:05.20,0:00:08.40,Default,N,0,0,0,,'
          '含逗号文本, 仍然要完整\n';
      final doc = SubtitleParser.parseText(ssa, format: SubtitleFormat.ssa);
      expect(doc.cues.length, 2,
          reason: 'SSA v4 的 Marked 字段被剥离后字段数与 Format 列数不匹配，'
              '导致全部 Dialogue 被丢弃');
      expect(doc.cues[0].start, const Duration(seconds: 1));
      expect(doc.cues[0].end, const Duration(seconds: 3));
      expect(doc.cues[0].rawText, '你好世界');
      expect(doc.cues[1].rawText, contains('仍然要完整'));
    });
  });

  group('VTT cue identifier', () {
    test('时间行之前的 cue 标识符不应混入字幕文本', () {
      const vtt = 'WEBVTT\n\n'
          'intro-cue\n'
          '00:00:01.000 --> 00:00:04.000\n'
          'Hello\n\n'
          '00:00:05.000 --> 00:00:06.000\n'
          'World\n';
      final doc = SubtitleParser.parseText(vtt, format: SubtitleFormat.vtt);
      expect(doc.cues.length, 2);
      expect(doc.cues[0].rawText, 'Hello',
          reason: 'cue 标识符 intro-cue 位于时间行之前，不是字幕内容');
      expect(doc.cues[1].rawText, 'World');
    });
  });

  group('SRT 基线行为', () {
    test('多行文本保留换行', () {
      const srt = '1\n'
          '00:00:01,000 --> 00:00:03,000\n'
          '第一行\n'
          '第二行\n';
      final doc = SubtitleParser.parseText(srt, format: SubtitleFormat.srt);
      expect(doc.cues.single.rawText, '第一行\n第二行');
    });
  });
}
