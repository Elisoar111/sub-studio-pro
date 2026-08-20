// gmkv_extract_namer 规则直跑检查（沙箱无 git 跑不了 flutter test，
// 用 dart.exe 直跑本脚本验证；长期回归见 test/core/gmkv_extract_namer_test.dart）。
// ignore_for_file: avoid_print
import 'package:subtitle_studio_pro/core/utils/gmkv_extract_namer.dart';

int _pass = 0;
int _fail = 0;

void check(String label, Object actual, Object expected) {
  if (actual == expected) {
    _pass++;
  } else {
    _fail++;
    print('FAIL: $label\n  expected: $expected\n  actual:   $actual');
  }
}

void main() {
  const src = r'D:\video\MyMovie.mkv';

  check(
    'video track',
    GmkvExtractNamer.trackFilename(
      sourcePath: src,
      trackNumber: 1,
      language: 'jpn',
      codecId: 'V_MPEG4/ISO/AVC',
      kind: 'video',
    ),
    'MyMovie_track1_[jpn].avc',
  );
  check(
    'hevc track no language',
    GmkvExtractNamer.trackFilename(
      sourcePath: src,
      trackNumber: 2,
      language: '',
      codecId: 'V_MPEGH/ISO/HEVC',
      kind: 'video',
    ),
    'MyMovie_track2_[].hevc',
  );
  check(
    'audio track with delay',
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
  check(
    'audio track delay 0 + und',
    GmkvExtractNamer.trackFilename(
      sourcePath: src,
      trackNumber: 3,
      language: 'und',
      codecId: 'A_AAC',
      kind: 'audio',
    ),
    'MyMovie_track3_[und]_DELAY 0ms.aac',
  );
  check(
    'srt track',
    GmkvExtractNamer.trackFilename(
      sourcePath: src,
      trackNumber: 5,
      language: 'eng',
      codecId: 'S_TEXT/UTF8',
      kind: 'subtitle',
    ),
    'MyMovie_track5_[eng].srt',
  );
  check(
    'ssa track -> ass',
    GmkvExtractNamer.trackFilename(
      sourcePath: src,
      trackNumber: 6,
      language: 'chi',
      codecId: 'S_TEXT/SSA',
      kind: 'subtitle',
    ),
    'MyMovie_track6_[chi].ass',
  );
  check(
    'illegal chars sanitized',
    GmkvExtractNamer.trackFilename(
      sourcePath: r'D:\video\Ep: 01.mkv',
      trackNumber: 1,
      language: 'jpn',
      codecId: 'V_MPEG4/ISO/AVC',
      kind: 'video',
    ),
    'Ep_ 01_track1_[jpn].avc',
  );

  check('chapters', GmkvExtractNamer.chaptersFilename(src), 'MyMovie_chapters.xml');
  check('tags', GmkvExtractNamer.tagsFilename(src), 'MyMovie_tags.xml');
  check(
    'attachment original name',
    GmkvExtractNamer.attachmentFilename('NotoSansCJK-Regular.ttf'),
    'NotoSansCJK-Regular.ttf',
  );
  check(
    'attachment illegal char',
    GmkvExtractNamer.attachmentFilename('font:name.ttf'),
    'font_name.ttf',
  );
  check(
    'attachment empty fallback',
    GmkvExtractNamer.attachmentFilename('', id: 7),
    'attachment_7',
  );

  check(
    'delay = audio - video (ns->ms)',
    GmkvExtractNamer.effectiveDelayMs(
      trackMinTsNs: 10500000,
      videoMinTsNs: 500000,
    ),
    10,
  );
  check(
    'delay no video -> 0',
    GmkvExtractNamer.effectiveDelayMs(trackMinTsNs: 10500000, videoMinTsNs: null),
    0,
  );
  check(
    'delay no track ts -> 0',
    GmkvExtractNamer.effectiveDelayMs(trackMinTsNs: null, videoMinTsNs: 500000),
    0,
  );
  check(
    'negative delay',
    GmkvExtractNamer.effectiveDelayMs(trackMinTsNs: 0, videoMinTsNs: 3000000),
    -3,
  );

  const videoExt = {
    'V_MS/VFW/FOURCC': 'avi',
    'V_UNCOMPRESSED': 'raw',
    'V_MPEG4/ISO/AVC': 'avc',
    'V_MPEG4/ISO/ASP': 'avc',
    'V_MPEGH/ISO/HEVC': 'hevc',
    'V_AV1': 'av1',
    'V_MPEG4/MS/V3': 'mp4',
    'V_MPEG1': 'mpg',
    'V_MPEG2': 'mpg',
    'V_REAL/RV40': 'rm',
    'V_QUICKTIME': 'mov',
    'V_THEORA': 'ogv',
    'V_PRORES': 'mov',
    'V_VP8': 'ivf',
    'V_VP9': 'ivf',
    'V_DIRAC': 'drc',
    'V_UNKNOWN': 'mkv',
  };
  videoExt.forEach((k, v) => check('video ext $k', GmkvExtractNamer.videoExtension(k), v));

  const audioExt = {
    'A_MPEG/L3': 'mp3',
    'A_MPEG/L2': 'mp2',
    'A_MPEG/L1': 'mpa',
    'A_PCM/INT/LIT': 'wav',
    'A_MPC': 'mpc',
    'A_AC3': 'ac3',
    'A_EAC3': 'eac3',
    'A_ALAC': 'caf',
    'A_DTS': 'dts',
    'A_VORBIS': 'ogg',
    'A_FLAC': 'flac',
    'A_REAL/COOK': 'ra',
    'A_MS/ACM': 'wav',
    'A_AAC': 'aac',
    'A_QUICKTIME/QDMC': 'mov',
    'A_TRUEHD': 'thd',
    'A_TTA1': 'tta',
    'A_WAVPACK4': 'wv',
    'A_OPUS': 'opus',
    'A_MLP': 'mlp',
    'A_UNKNOWN': 'mka',
  };
  audioExt.forEach((k, v) => check('audio ext $k', GmkvExtractNamer.audioExtension(k), v));

  const subExt = {
    'S_TEXT/UTF8': 'srt',
    'S_TEXT/ASCII': 'srt',
    'S_TEXT/SSA': 'ass',
    'S_TEXT/ASS': 'ass',
    'S_TEXT/USF': 'usf',
    'S_TEXT/WEBVTT': 'webvtt',
    'S_IMAGE/BMP': 'sub',
    'S_VOBSUB': 'sub',
    'S_DVBSUB': 'dvbsub',
    'S_HDMV/PGS': 'sup',
    'S_HDMV/TEXTST': 'textst',
    'S_KATE': 'ogg',
    'S_UNKNOWN': 'sub',
  };
  subExt.forEach((k, v) => check('subtitle ext $k', GmkvExtractNamer.subtitleExtension(k), v));

  print('$_pass passed, $_fail failed');
  if (_fail > 0) {
    throw StateError('gmkv namer checks failed');
  }
}
