import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/core/utils/startup_args.dart';

/// 启动参数筛选（v1.5 文件关联）：只保留真实存在的字幕文件，
/// 视频文件 / 不存在路径 / 未知扩展名一律丢弃，重复参数去重。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('startup_args_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String fileIn(String name, [String content = 'demo']) {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    f.writeAsStringSync(content);
    return f.path;
  }

  test('存在的字幕文件保留，扩展名大小写不敏感', () {
    final srt = fileIn('a.srt');
    final ass = fileIn('b.ASS');

    final result = subtitleFilesFromArgs([srt, ass]);

    expect(result, unorderedEquals(<String>[srt, ass]));
  });

  test('视频扩展名 / 不存在路径 / 无扩展名 / 空参数 → 丢弃', () {
    final mp4 = fileIn('c.mp4');
    final srt = fileIn('d.srt');

    final result = subtitleFilesFromArgs([
      mp4, // 视频格式不收
      '${tmp.path}${Platform.pathSeparator}ghost.srt', // 不存在
      '${tmp.path}${Platform.pathSeparator}noext', // 无扩展名
      '',
      srt,
    ]);

    expect(result, [srt]);
  });

  test('重复参数去重（保持首次出现顺序）', () {
    final srt = fileIn('e.srt');

    final result = subtitleFilesFromArgs([srt, srt, srt]);

    expect(result, [srt]);
  });
}
