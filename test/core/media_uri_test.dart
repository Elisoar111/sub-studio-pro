import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/core/utils/media_uri.dart';

void main() {
  group('mediaFromPath', () {
    test('普通 Windows 路径转标准 file URI', () {
      final uri = mediaFromPath(r'C:\Videos\a.mkv').uri;
      expect(uri, 'file:///C:/Videos/a.mkv');
    });

    test('路径含 # 时不被截断为 fragment', () {
      final uri = mediaFromPath(r'D:\Anime\EP#01 [合集]\video.mkv').uri;
      final parsed = Uri.parse(uri);
      expect(parsed.fragment, isEmpty);
      expect(parsed.path, contains('EP%2301'));
    });

    test('路径含 % 时不发生二次解码错位', () {
      final uri = mediaFromPath(r'E:\100% 精华\pv.mkv').uri;
      final parsed = Uri.parse(uri);
      expect(parsed.path, contains('100%25'));
    });

    test('中文与空格可往返解码还原原路径', () {
      const path = r'D:\动画 我的\第 01 集.mkv';
      final parsed = Uri.parse(mediaFromPath(path).uri);
      expect(Uri.decodeComponent(parsed.path), '/D:/动画 我的/第 01 集.mkv');
    });
  });
}
