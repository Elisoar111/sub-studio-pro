import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/core/utils/subtitle_matcher.dart';

void main() {
  group('批量匹配兜底规则', () {
    test('数量不等时不应强行顺序配对', () {
      final r = matchSubtitlePairs(
        ['D:/a/ep01.mkv'],
        ['D:/s/番外.srt', 'D:/s/特典.srt'],
      );
      expect(r.pairs, isEmpty,
          reason: '1 个视频对 2 个无关字幕，数量不等，'
              '按声明的规则不应顺序强配');
      expect(r.unmatchedVideos.length, 1);
      expect(r.unmatchedSubtitles.length, 2);
    });

    test('数量相等时按顺序配对', () {
      final r = matchSubtitlePairs(
        ['D:/a/ep01.mkv', 'D:/a/ep02.mkv'],
        ['D:/s/第一话.srt', 'D:/s/第二话.srt'],
      );
      expect(r.pairs.length, 2);
      expect(r.unmatchedVideos, isEmpty);
      expect(r.unmatchedSubtitles, isEmpty);
    });

    test('归一化同名优先配对', () {
      final r = matchSubtitlePairs(
        ['D:/a/EP01.mkv'],
        ['D:/s/EP01.chs.srt', 'D:/s/other.srt'],
      );
      expect(r.pairs.length, 1);
      expect(r.pairs.single.$1, 'D:/a/EP01.mkv');
      expect(r.pairs.single.$2, 'D:/s/EP01.chs.srt');
    });
  });
}
