import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitle_studio_pro/models/subtitle.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('translate_naming');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('翻译输出命名（无模板）', () {
    test('译文：demo.srt → demo_en.srt', () {
      final out = TranslationService.translatedPath(
        inputPath: p.join(tmp.path, 'demo.srt'),
        outputDir: tmp.path,
        langCode: 'en',
      );
      expect(out, p.join(tmp.path, 'demo_en.srt'));
    });

    test('译文保持源扩展名：demo.ass → demo_ja.ass', () {
      final out = TranslationService.translatedPath(
        inputPath: p.join(tmp.path, 'demo.ass'),
        outputDir: tmp.path,
        langCode: 'ja',
      );
      expect(out, p.join(tmp.path, 'demo_ja.ass'));
    });

    test('译文写入目录可与源目录不同', () {
      final out = TranslationService.translatedPath(
        inputPath: p.join(tmp.path, 'src', 'demo.srt'),
        outputDir: tmp.path,
        langCode: 'zh',
      );
      expect(out, p.join(tmp.path, 'demo_zh.srt'));
    });

    test('合并：demo.srt → demo_mixed.srt', () {
      final out = TranslationService.mixedPath(
        inputPath: p.join(tmp.path, 'demo.srt'),
        outputDir: tmp.path,
      );
      expect(out, p.join(tmp.path, 'demo_mixed.srt'));
    });

    test('重名（磁盘）：已有 demo_en.srt → demo_en_1.srt', () {
      File(p.join(tmp.path, 'demo_en.srt')).writeAsStringSync('旧');
      final out = TranslationService.dedupePath(
        p.join(tmp.path, 'demo_en.srt'),
        <String>{},
      );
      expect(out, p.join(tmp.path, 'demo_en_1.srt'));
    });

    test('重名（同批 used + 磁盘）：_1 被占用 → _2', () {
      final used = <String>{};
      final first = TranslationService.dedupePath(
        p.join(tmp.path, 'demo_en.srt'),
        used,
      );
      expect(first, p.join(tmp.path, 'demo_en.srt'));
      File(p.join(tmp.path, 'demo_en_1.srt')).writeAsStringSync('占位');
      final third = TranslationService.dedupePath(
        p.join(tmp.path, 'demo_en.srt'),
        used,
      );
      expect(third, p.join(tmp.path, 'demo_en_2.srt'));
    });
  });

  group('双语合并文档（_mixed）', () {
    SubtitleCue cue(int i, String text) => SubtitleCue(
          index: i,
          start: Duration(seconds: i),
          end: Duration(seconds: i + 1),
          rawText: text,
        );

    test('SRT：时间轴与索引不变，文本 = 原文\\n译文', () {
      final src = SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [cue(1, 'Hello'), cue(2, 'World')],
      );
      final tr = SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [cue(1, '你好'), cue(2, '世界')],
      );
      final mixed = TranslationService.mixedDocument(src, tr);
      expect(mixed.format, SubtitleFormat.srt);
      expect(mixed.cues.length, 2);
      expect(mixed.cues[0].start, const Duration(seconds: 1));
      expect(mixed.cues[0].end, const Duration(seconds: 2));
      expect(mixed.cues[0].index, 1);
      expect(mixed.cues[0].rawText, 'Hello\n你好');
      expect(mixed.cues[1].rawText, 'World\n世界');
    });

    test('ASS：用 \\N 连接（写入后播放器可正确换行）', () {
      final src = SubtitleDocument(
        format: SubtitleFormat.ass,
        cues: [cue(1, 'Hello')],
      );
      final tr = SubtitleDocument(
        format: SubtitleFormat.ass,
        cues: [cue(1, '你好')],
      );
      final mixed = TranslationService.mixedDocument(src, tr);
      expect(mixed.cues.single.rawText, r'Hello\N你好');
    });

    test('译文为空或与原文相同：保留原文，不输出重复两行', () {
      final src = SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [
          const SubtitleCue(
            index: 1,
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            rawText: 'Hello',
          ),
          const SubtitleCue(
            index: 2,
            start: Duration(seconds: 2),
            end: Duration(seconds: 3),
            rawText: 'World',
          ),
        ],
      );
      final tr = SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [
          const SubtitleCue(
            index: 1,
            start: Duration(seconds: 1),
            end: Duration(seconds: 2),
            rawText: '',
          ),
          const SubtitleCue(
            index: 2,
            start: Duration(seconds: 2),
            end: Duration(seconds: 3),
            rawText: 'World',
          ),
        ],
      );
      final mixed = TranslationService.mixedDocument(src, tr);
      expect(mixed.cues[0].rawText, 'Hello');
      expect(mixed.cues[1].rawText, 'World');
    });

    test('译文条数少于原文（异常防御）：缺失项保留原文', () {
      final src = SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [cue(1, 'Hello'), cue(2, 'World')],
      );
      final tr = SubtitleDocument(
        format: SubtitleFormat.srt,
        cues: [cue(1, '你好')],
      );
      final mixed = TranslationService.mixedDocument(src, tr);
      expect(mixed.cues[0].rawText, 'Hello\n你好');
      expect(mixed.cues[1].rawText, 'World');
    });
  });
}
