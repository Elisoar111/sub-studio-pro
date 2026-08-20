import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/core/utils/gmkv_extract_namer.dart';

/// gMKVExtractGUI v2.15.0（Gpower2）输出文件名规则复刻测试。
///
/// 规则来源：gSettings.cs 默认 pattern + gMKVExtractExtensions.cs
/// （GetOutputFilename / ReplaceFilenamePlaceholders / *FileExtensionFromCodecID）。
void main() {
  const src = r'D:\video\MyMovie.mkv';

  group('轨道命名（默认 pattern）', () {
    test('视频轨：{名}_track{N}_[{语言}].{扩展}', () {
      expect(
        GmkvExtractNamer.trackFilename(
          sourcePath: src,
          trackNumber: 1,
          language: 'jpn',
          codecId: 'V_MPEG4/ISO/AVC',
          kind: 'video',
        ),
        'MyMovie_track1_[jpn].avc',
      );
    });

    test('HEVC 视频轨扩展名为 hevc', () {
      expect(
        GmkvExtractNamer.trackFilename(
          sourcePath: src,
          trackNumber: 2,
          language: '',
          codecId: 'V_MPEGH/ISO/HEVC',
          kind: 'video',
        ),
        'MyMovie_track2_[].hevc',
      );
    });

    test('音频轨：含 _DELAY {ms}ms 段', () {
      expect(
        GmkvExtractNamer.trackFilename(
          sourcePath: src,
          trackNumber: 3,
          language: 'chi',
          codecId: 'A_AAC',
          kind: 'audio',
          effectiveDelayMs: 10,
        ),
        'MyMovie_track3_[chi]_DELAY 10ms.aac',
      );
    });

    test('音频轨延迟为 0 时仍输出 _DELAY 0ms（gMKV 同行为）', () {
      expect(
        GmkvExtractNamer.trackFilename(
          sourcePath: src,
          trackNumber: 3,
          language: 'und',
          codecId: 'A_AAC',
          kind: 'audio',
        ),
        'MyMovie_track3_[und]_DELAY 0ms.aac',
      );
    });

    test('字幕轨：S_TEXT/UTF8 → srt', () {
      expect(
        GmkvExtractNamer.trackFilename(
          sourcePath: src,
          trackNumber: 5,
          language: 'eng',
          codecId: 'S_TEXT/UTF8',
          kind: 'subtitle',
        ),
        'MyMovie_track5_[eng].srt',
      );
    });

    test('字幕轨：S_TEXT/SSA → ass（gMKV 将 SSA 也写为 .ass）', () {
      expect(
        GmkvExtractNamer.trackFilename(
          sourcePath: src,
          trackNumber: 6,
          language: 'chi',
          codecId: 'S_TEXT/SSA',
          kind: 'subtitle',
        ),
        'MyMovie_track6_[chi].ass',
      );
    });

    test('非法字符替换为 _ 并去首尾空白', () {
      expect(
        GmkvExtractNamer.trackFilename(
          sourcePath: r'D:\video\Ep: 01.mkv',
          trackNumber: 1,
          language: 'jpn',
          codecId: 'V_MPEG4/ISO/AVC',
          kind: 'video',
        ),
        'Ep_ 01_track1_[jpn].avc',
      );
    });
  });

  group('章节 / 标签 / 附件', () {
    test('章节：{名}_chapters.xml', () {
      expect(GmkvExtractNamer.chaptersFilename(src), 'MyMovie_chapters.xml');
    });

    test('标签：{名}_tags.xml', () {
      expect(GmkvExtractNamer.tagsFilename(src), 'MyMovie_tags.xml');
    });

    test('附件：容器内原始文件名', () {
      expect(
        GmkvExtractNamer.attachmentFilename('NotoSansCJK-Regular.ttf'),
        'NotoSansCJK-Regular.ttf',
      );
    });

    test('附件名含非法字符时替换为 _', () {
      expect(
        GmkvExtractNamer.attachmentFilename('font:name.ttf'),
        'font_name.ttf',
      );
    });
  });

  group('EffectiveDelay（相对视频轨）', () {
    test('音轨 minTs − 视频轨 minTs（纳秒 → 毫秒）', () {
      expect(
        GmkvExtractNamer.effectiveDelayMs(
          trackMinTsNs: 10500000,
          videoMinTsNs: 500000,
        ),
        10,
      );
    });

    test('无视频轨（videoMinTs 为 null）→ 0', () {
      expect(
        GmkvExtractNamer.effectiveDelayMs(
          trackMinTsNs: 10500000,
          videoMinTsNs: null,
        ),
        0,
      );
    });

    test('音轨无 minTs → 0', () {
      expect(
        GmkvExtractNamer.effectiveDelayMs(
          trackMinTsNs: null,
          videoMinTsNs: 500000,
        ),
        0,
      );
    });

    test('负延迟保留符号（音轨早于视频）', () {
      expect(
        GmkvExtractNamer.effectiveDelayMs(
          trackMinTsNs: 0,
          videoMinTsNs: 3000000,
        ),
        -3,
      );
    });
  });

  group('扩展名映射（CodecID 前缀，gMKV v2.15 全表）', () {
    test('视频', () {
      expect(GmkvExtractNamer.videoExtension('V_MS/VFW/FOURCC'), 'avi');
      expect(GmkvExtractNamer.videoExtension('V_UNCOMPRESSED'), 'raw');
      expect(GmkvExtractNamer.videoExtension('V_MPEG4/ISO/AVC'), 'avc');
      expect(GmkvExtractNamer.videoExtension('V_MPEG4/ISO/ASP'), 'avc');
      expect(GmkvExtractNamer.videoExtension('V_MPEGH/ISO/HEVC'), 'hevc');
      expect(GmkvExtractNamer.videoExtension('V_AV1'), 'av1');
      expect(GmkvExtractNamer.videoExtension('V_MPEG4/MS/V3'), 'mp4');
      expect(GmkvExtractNamer.videoExtension('V_MPEG1'), 'mpg');
      expect(GmkvExtractNamer.videoExtension('V_MPEG2'), 'mpg');
      expect(GmkvExtractNamer.videoExtension('V_REAL/RV40'), 'rm');
      expect(GmkvExtractNamer.videoExtension('V_QUICKTIME'), 'mov');
      expect(GmkvExtractNamer.videoExtension('V_THEORA'), 'ogv');
      expect(GmkvExtractNamer.videoExtension('V_PRORES'), 'mov');
      expect(GmkvExtractNamer.videoExtension('V_VP8'), 'ivf');
      expect(GmkvExtractNamer.videoExtension('V_VP9'), 'ivf');
      expect(GmkvExtractNamer.videoExtension('V_DIRAC'), 'drc');
      expect(GmkvExtractNamer.videoExtension('V_UNKNOWN'), 'mkv');
    });

    test('音频（A_AC3 不误吞 A_EAC3）', () {
      expect(GmkvExtractNamer.audioExtension('A_MPEG/L3'), 'mp3');
      expect(GmkvExtractNamer.audioExtension('A_MPEG/L2'), 'mp2');
      expect(GmkvExtractNamer.audioExtension('A_MPEG/L1'), 'mpa');
      expect(GmkvExtractNamer.audioExtension('A_PCM/INT/LIT'), 'wav');
      expect(GmkvExtractNamer.audioExtension('A_MPC'), 'mpc');
      expect(GmkvExtractNamer.audioExtension('A_AC3'), 'ac3');
      expect(GmkvExtractNamer.audioExtension('A_EAC3'), 'eac3');
      expect(GmkvExtractNamer.audioExtension('A_ALAC'), 'caf');
      expect(GmkvExtractNamer.audioExtension('A_DTS'), 'dts');
      expect(GmkvExtractNamer.audioExtension('A_VORBIS'), 'ogg');
      expect(GmkvExtractNamer.audioExtension('A_FLAC'), 'flac');
      expect(GmkvExtractNamer.audioExtension('A_REAL/COOK'), 'ra');
      expect(GmkvExtractNamer.audioExtension('A_MS/ACM'), 'wav');
      expect(GmkvExtractNamer.audioExtension('A_AAC'), 'aac');
      expect(GmkvExtractNamer.audioExtension('A_QUICKTIME/QDMC'), 'mov');
      expect(GmkvExtractNamer.audioExtension('A_TRUEHD'), 'thd');
      expect(GmkvExtractNamer.audioExtension('A_TTA1'), 'tta');
      expect(GmkvExtractNamer.audioExtension('A_WAVPACK4'), 'wv');
      expect(GmkvExtractNamer.audioExtension('A_OPUS'), 'opus');
      expect(GmkvExtractNamer.audioExtension('A_MLP'), 'mlp');
      expect(GmkvExtractNamer.audioExtension('A_UNKNOWN'), 'mka');
    });

    test('字幕', () {
      expect(GmkvExtractNamer.subtitleExtension('S_TEXT/UTF8'), 'srt');
      expect(GmkvExtractNamer.subtitleExtension('S_TEXT/ASCII'), 'srt');
      expect(GmkvExtractNamer.subtitleExtension('S_TEXT/SSA'), 'ass');
      expect(GmkvExtractNamer.subtitleExtension('S_TEXT/ASS'), 'ass');
      expect(GmkvExtractNamer.subtitleExtension('S_TEXT/USF'), 'usf');
      expect(GmkvExtractNamer.subtitleExtension('S_TEXT/WEBVTT'), 'webvtt');
      expect(GmkvExtractNamer.subtitleExtension('S_IMAGE/BMP'), 'sub');
      expect(GmkvExtractNamer.subtitleExtension('S_VOBSUB'), 'sub');
      expect(GmkvExtractNamer.subtitleExtension('S_DVBSUB'), 'dvbsub');
      expect(GmkvExtractNamer.subtitleExtension('S_HDMV/PGS'), 'sup');
      expect(GmkvExtractNamer.subtitleExtension('S_HDMV/TEXTST'), 'textst');
      expect(GmkvExtractNamer.subtitleExtension('S_KATE'), 'ogg');
      expect(GmkvExtractNamer.subtitleExtension('S_UNKNOWN'), 'sub');
    });
  });
}
