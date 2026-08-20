import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/mkvtoolnix/mkvtoolnix_service.dart';

/// mkvmerge -J 输出样例（节选自真实结构；字幕轨 type 为复数 "subtitles"）。
const _identifyJson = '''
{
  "container": {
    "properties": {
      "container_type": 17,
      "duration": 1453.024
    }
  },
  "tracks": [
    {
      "id": 0,
      "type": "video",
      "codec": "MPEG-4p10/ISO/AVC",
      "properties": {
        "track_number": 1,
        "uid": 123456789,
        "codec_id": "V_MPEG4/ISO/AVC",
        "language": "und",
        "pixel_width": 1920,
        "pixel_height": 1080,
        "default_track": true,
        "enabled_track": true
      }
    },
    {
      "id": 1,
      "type": "audio",
      "codec": "AAC",
      "properties": {
        "track_number": 2,
        "codec_id": "A_AAC",
        "language": "jpn",
        "track_name": "Commentary",
        "num_channels": 2,
        "sampling_frequency": 48000,
        "default_track": true,
        "minimum_timestamp": 1000000000
      }
    },
    {
      "id": 2,
      "type": "subtitles",
      "codec": "SubRip/SRT",
      "properties": {
        "track_number": 3,
        "codec_id": "S_TEXT/UTF8",
        "language": "chi",
        "forced_track": true
      }
    }
  ],
  "attachments": [
    {
      "id": 0,
      "file_name": "NotoSansSC.ttf",
      "content_type": "font/sfnt"
    }
  ],
  "chapters": [
    { "uid": 1, "num_sub_chapters": 0 }
  ],
  "global_tags": [ { "uid": 99 } ]
}
''';

void main() {
  final json =
      jsonDecode(_identifyJson) as Map<String, dynamic>;

  test('mkvmerge -J 字幕轨 type 为复数 subtitles，应归一化为 subtitle',
      () {
    final info = MkvToolNixService.parseIdentify(json, 'x.mkv');
    final subs = info.tracks.where((t) => t.type == 'subtitle').toList();
    expect(subs, hasLength(1));
    expect(subs.first.id, 2);
    expect(subs.first.codecId, 'S_TEXT/UTF8');
    expect(subs.first.forcedTrack, isTrue);
  });

  test('视频/音频轨解析（type 单数不受归一化影响）', () {
    final info = MkvToolNixService.parseIdentify(json, 'x.mkv');
    final video = info.tracks.where((t) => t.type == 'video').single;
    final audio = info.tracks.where((t) => t.type == 'audio').single;
    expect(video.pixelWidth, 1920);
    expect(video.defaultTrack, isTrue);
    expect(audio.channels, 2);
    expect(audio.samplingRate, 48000);
    expect(audio.minTimestampNs, 1000000000);
    expect(audio.trackName, 'Commentary');
  });

  test('轨道序号 / UID / 启用标志 / 章节标签附件', () {
    final info = MkvToolNixService.parseIdentify(json, 'x.mkv');
    final video = info.tracks.first;
    expect(video.number, 1);
    expect(video.uid, 123456789);
    expect(video.enabled, isTrue);
    expect(info.hasChapters, isTrue);
    expect(info.hasTags, isTrue);
    expect(info.attachments, hasLength(1));
    expect(info.attachments.first.fileName, 'NotoSansSC.ttf');
    expect(info.duration, const Duration(milliseconds: 1453024));
  });

  test('禁用轨（enabled_track=false）', () {
    final j = {
      'tracks': [
        {
          'id': 0,
          'type': 'audio',
          'properties': {'codec_id': 'A_AAC', 'enabled_track': false},
        }
      ],
    };
    final info = MkvToolNixService.parseIdentify(j, 'x.mkv');
    expect(info.tracks.single.enabled, isFalse);
    // 缺省 enabled_track 时视为启用
    final j2 = {
      'tracks': [
        {'id': 0, 'type': 'audio', 'properties': {'codec_id': 'A_AAC'}},
      ],
    };
    expect(MkvToolNixService.parseIdentify(j2, 'x.mkv').tracks.single.enabled,
        isTrue);
  });

  test('超大 UID（uint64 超 int64 范围）不得使整个解析失败', () {
    // Matroska UID 为 uint64 随机数，约半数超出 Dart int（有符号 64 位）；
    // jsonDecode 将其解析为 double，`as int?` 会抛 TypeError 导致
    // probe 整体失败（曾致「导入视频无法解析轨道」）。
    // 注意：Dart 源码整数字面量本身不能超 int64，须经 jsonDecode 构造。
    final j = jsonDecode('''
    {
      "attachments": [
        {
          "id": 0,
          "file_name": "cover.jpg",
          "properties": {"uid": 14401483379528806630}
        }
      ],
      "tracks": [
        {
          "id": 0,
          "type": "video",
          "properties": {
            "codec_id": "V_MPEG4/ISO/AVC",
            "uid": 18446744073709551615,
            "pixel_width": 1920,
            "pixel_height": 1080
          }
        },
        {
          "id": 1,
          "type": "audio",
          "properties": {"codec_id": "A_AAC", "num_channels": 2}
        }
      ]
    }
    ''') as Map<String, dynamic>;
    final info = MkvToolNixService.parseIdentify(j, 'x.mp4');
    // 解析不抛异常且轨道完整；超范围 UID 安全降级为 null
    expect(info.tracks, hasLength(2));
    expect(info.tracks[0].pixelWidth, 1920);
    expect(info.tracks[1].channels, 2);
    expect(info.tracks[0].uid, isNull);
    expect(info.attachments, hasLength(1));
  });
}
