import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/core/utils/media_uri.dart';

void main() {
  group('mediaFromPath', () {
    // media_kit ≥1.2：Media 构造时把入参归一化为 libmpv 内部使用的
    // 纯文件路径（正斜杠、无 file:// 前缀、特殊字符原样保留）。
    test('普通 Windows 路径归一化为正斜杠纯路径', () {
      final uri = mediaFromPath(r'C:\Videos\a.mkv').uri;
      expect(uri, 'C:/Videos/a.mkv');
    });

    test('路径含 # 时保留原字、不截断（纯路径直传 mpv）', () {
      final uri = mediaFromPath(r'D:\Anime\EP#01 [合集]\video.mkv').uri;
      expect(uri, 'D:/Anime/EP#01 [合集]/video.mkv');
    });

    test('路径含 % 时原样保留，不发生二次解码错位', () {
      final uri = mediaFromPath(r'E:\100% 精华\pv.mkv').uri;
      expect(uri, 'E:/100% 精华/pv.mkv');
    });

    test('中文与空格原样保留', () {
      final uri = mediaFromPath(r'D:\动画 我的\第 01 集.mkv').uri;
      expect(uri, 'D:/动画 我的/第 01 集.mkv');
    });
  });
}
