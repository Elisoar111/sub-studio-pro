import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/subtitle/subtitle_converter.dart';
import 'package:subtitle_studio_pro/services/subtitle/subtitle_parser.dart';

void main() {
  group('SRT → ASS 标签映射', () {
    test('生成的覆盖标签 {\\i1} 不应被花括号转义破坏', () {
      const srt = '1\n'
          '00:00:01,000 --> 00:00:03,000\n'
          '<i>斜体文字</i> 正常 <b>粗体</b>\n';
      final doc = SubtitleParser.parseText(srt, format: SubtitleFormat.srt);
      final bytes = SubtitleConverter.convertToBytes(
        doc,
        options: const SubtitleConvertOptions(targetFormat: SubtitleFormat.ass),
      );
      final out = String.fromCharCodes(bytes);
      expect(out, contains(r'{\i1}'), reason: '斜体标签应保留为 ASS 覆盖标签');
      expect(out, contains(r'{\b1}'));
      expect(out, isNot(contains('｛')), reason: '刚生成的标签不应被二次转成全角括号');
    });
  });

  group('MicroDVD 帧率', () {
    test('microDvdFps 选项应传导到输出帧号', () {
      const srt = '1\n'
          '00:00:01,000 --> 00:00:02,000\n'
          'hi\n';
      final doc = SubtitleParser.parseText(srt, format: SubtitleFormat.srt);
      final bytes = SubtitleConverter.convertToBytes(
        doc,
        options: const SubtitleConvertOptions(
          targetFormat: SubtitleFormat.sub,
          microDvdFps: 23.976,
        ),
      );
      final out = String.fromCharCodes(bytes);
      // 1s × 23.976fps → 起始帧 24；硬编码 25 会得 25
      expect(out, contains('{24}{48}'),
          reason: 'microDvdFps=23.976 时帧号应按 23.976 计算，'
              '而不是被硬编码 25 覆盖');
    });
  });
}
