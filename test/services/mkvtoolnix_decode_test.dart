import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/mkvtoolnix/mkvtoolnix_service.dart';

/// mkv 工具输出解码（v2.0.2 修复）：
/// mkvmerge/mkvextract 输出含旧式 ANSI/GBK 文件名或轨道名时会产生
/// 非 UTF-8 字节——严格解码会抛 FormatException，令整个任务以
/// 「MKVToolNix 进程异常」失败。宽容解码把坏字节替换为 U+FFFD，
/// 与 Whisper / FFmpeg 后端的解码策略一致。
void main() {
  test('含非 UTF-8 字节（GBK 文件名）的输出不抛异常', () async {
    // 「文件名」的 GBK 编码（严格 UTF-8 解码下为非法序列）
    final gbk = <int>[0xCE, 0xC4, 0xBC, 0xFE, 0xC3, 0xFB, 0x0A];

    final lines = await MkvToolNixService.decodeToolLines(
      Stream<List<int>>.fromIterable([gbk]),
    ).toList();

    expect(lines, hasLength(1));
    expect(lines.single, contains('\uFFFD'),
        reason: '坏字节应替换为 U+FFFD 而不是抛 FormatException');
  });

  test('多字节序列跨 chunk 边界仍正确解码', () async {
    // 「文」的 UTF-8 编码 E6 96 87，首字节拆到独立 chunk
    final lines = await MkvToolNixService.decodeToolLines(
      Stream<List<int>>.fromIterable([
        [0xE6],
        [0x96, 0x87, 0x0A],
      ]),
    ).toList();

    expect(lines, ['文'],
        reason: '跨 chunk 的合法多字节序列不应被误判为坏字节');
  });

  test('正常 UTF-8 输出按行原样解码', () async {
    final lines = await MkvToolNixService.decodeToolLines(
      Stream<List<int>>.fromIterable([utf8.encode('Progress: 50%\nok')]),
    ).toList();

    expect(lines, ['Progress: 50%', 'ok']);
  });
}
