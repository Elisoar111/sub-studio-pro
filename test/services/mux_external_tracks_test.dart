import 'dart:convert';
import 'dart:io';

import 'package:charset/charset.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:subtitle_studio_pro/models/mux_track.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_params.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/mkvtoolnix/mkvtoolnix_service.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';
import 'package:uuid/uuid.dart';

/// 外部轨道封装回归测试（dev-fix）：
/// 症状：封装页添加外部字幕 / 音频 / 字体后任务失败，产物缺失。
/// 根因：merge() 对外部轨与源轨编辑发射 `--track-enabled`，
/// mkvmerge v100 已无此选项名（被当作输入文件名 → 退出码 2 整体失败）；
/// 纯重封装测试（tracksJson 为空且无 edits）不经过该分支，长期漏网。
///
/// 夹具：audio@0（默认轨）+ subs@1,2,3（chi 默认 / eng / jpn）+ 附件×2。
void main() {
  final tmp = Directory.systemTemp.createTempSync('mux_external');
  late String fixture;
  late String mkvmerge;
  late String mkvextract;

  setUpAll(() async {
    mkvmerge = <String>[
      r'D:\Program Files\MKVToolNix\mkvmerge.exe',
      r'C:\Program Files\MKVToolNix\mkvmerge.exe',
      r'C:\Program Files (x86)\MKVToolNix\mkvmerge.exe',
      'mkvmerge',
    ].firstWhere((path) {
      if (!path.contains(Platform.pathSeparator) && !path.contains('/')) {
        return true;
      }
      return File(path).existsSync();
    });
    final dir = p.dirname(mkvmerge);
    mkvextract = dir.isEmpty ? 'mkvextract' : p.join(dir, 'mkvextract.exe');

    // 静音 WAV：48kHz 立体声 16bit 3 秒
    final wav = File(p.join(tmp.path, 'a.wav'));
    const dataLen = 48000 * 2 * 2 * 3;
    final bw = wav.openSync(mode: FileMode.write);
    void ascii(String s) => bw.writeFromSync(s.codeUnits);
    void i32(int v) => bw.writeFromSync([
          v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff,
        ]);
    void i16(int v) => bw.writeFromSync([v & 0xff, (v >> 8) & 0xff]);
    ascii('RIFF');
    i32(36 + dataLen);
    ascii('WAVE');
    ascii('fmt ');
    i32(16);
    i16(1);
    i16(2);
    i32(48000);
    i32(48000 * 2 * 2);
    i16(4);
    i16(16);
    ascii('data');
    i32(dataLen);
    bw.writeFromSync(List<int>.filled(dataLen, 0));
    bw.closeSync();

    const srt = '1\n00:00:00,000 --> 00:00:02,000\n测试\n';
    for (final lang in ['chi', 'eng', 'jpn']) {
      File(p.join(tmp.path, '$lang.srt')).writeAsStringSync(srt);
    }
    for (final font in ['TestFontA.ttf', 'TestFontB.otf']) {
      File(p.join(tmp.path, font))
          .writeAsBytesSync(List<int>.filled(256, 0x1a));
    }

    fixture = p.join(tmp.path, 'fix.mkv');
    final r = await Process.run(mkvmerge, [
      '-o', fixture,
      '--attach-file', p.join(tmp.path, 'TestFontA.ttf'),
      '--attach-file', p.join(tmp.path, 'TestFontB.otf'),
      '--language', '0:jpn', wav.path,
      '--language', '0:chi', '--default-track', '0:1',
      p.join(tmp.path, 'chi.srt'),
      '--language', '0:eng', p.join(tmp.path, 'eng.srt'),
      '--language', '0:jpn', p.join(tmp.path, 'jpn.srt'),
    ]);
    expect(r.exitCode, anyOf(0, 1), reason: '夹具生成失败：${r.stderr}');

    await MkvToolNixService.instance.init();
    expect(MkvToolNixService.instance.isAvailable, isTrue,
        reason: 'MKVToolNix 不可用，无法运行外部轨封装测试');
    final ffmpeg = await FfmpegService.create();
    QueueService.instance.init(ffmpeg: ffmpeg);
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// 入队一个与封装页 _start() 生成的一致的封装任务并执行。
  Future<QueueTask> runMux({
    required List<MuxTrack> tracks,
    Map<String, dynamic>? sourceSel,
    required String out,
  }) {
    final task = QueueService.instance.addTask(
      type: TaskType.mux,
      title: '外部轨封装',
      params: {
        TaskParams.videoPath: fixture,
        TaskParams.tracksJson: MuxTrack.encodeList(tracks),
        TaskParams.container: 'mkv',
        if (sourceSel != null) TaskParams.sourceSel: jsonEncode(sourceSel),
        TaskParams.outputPath: out,
        TaskParams.totalDurationMs: '3000',
      },
    );
    return QueueService.instance.start().then((_) => task);
  }

  Map<String, dynamic> sel({
    List<int> audio = const [0],
    List<int> subs = const [],
    List<int>? fonts,
    List<Map<String, dynamic>>? edits,
  }) =>
      {
        'audio': audio,
        'subs': subs,
        if (fonts != null) 'fonts': fonts,
        'chapters': true,
        'tags': true,
        if (edits != null) 'edits': edits,
      };

  Future<Map<String, dynamic>> jsonOf(String path) async {
    final r = await Process.run(mkvmerge, ['-J', path],
        stdoutEncoding: utf8, stderrEncoding: utf8);
    return jsonDecode(r.stdout as String) as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> tracksOf(Map<String, dynamic> j) =>
      (j['tracks'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  Map<String, dynamic> props(Map<String, dynamic> t) =>
      t['properties'] as Map<String, dynamic>;

  /// 从产物中提取指定字幕轨文本（mkvextract）。
  Future<String> extractSub(String mkv, Map<String, dynamic> track) async {
    final dest = p.join(tmp.path, 'ext_${const Uuid().v4()}.srt');
    final r = await Process.run(mkvextract, ['tracks', mkv, '${track['id']}:$dest']);
    expect(r.exitCode, anyOf(0, 1), reason: 'mkvextract 失败：${r.stderr}');
    return File(dest).readAsStringSync(encoding: utf8);
  }

  test('外部字幕 + 新字体封装必须成功且元数据正确', () async {
    final ext = p.join(tmp.path, 'ext_eng.srt');
    File(ext).writeAsStringSync('1\n00:00:00,000 --> 00:00:02,000\nhello\n');
    final font = p.join(tmp.path, 'NewFont.ttf');
    File(font).writeAsBytesSync(List<int>.filled(128, 0x1a));

    final out = p.join(tmp.path, 'ext.mkv');
    final task = await runMux(
      tracks: [
        MuxTrack(
          type: MuxTrackType.subtitle,
          path: ext,
          language: 'eng',
          title: 'English',
          isDefault: false,
        ),
        MuxTrack(type: MuxTrackType.attachment, path: font),
      ],
      sourceSel: sel(subs: [1], fonts: [1, 2]),
      out: out,
    );

    expect(task.status, TaskStatus.completed,
        reason: '外部轨封装失败：${task.error ?? ''}');
    expect(File(out).existsSync(), isTrue);

    final j = await jsonOf(out);
    final subs =
        tracksOf(j).where((t) => t['type'] == 'subtitles').toList();
    expect(subs, hasLength(2), reason: '源 chi + 外部 eng 均应在产物中');
    final extTrack = subs.firstWhere((t) => props(t)['language'] == 'eng');
    expect(props(extTrack)['track_name'], 'English');
    // 显式 --default-track 0:0：不得继承源 chi 轨的默认标记
    expect(props(extTrack)['default_track'], isFalse);

    final atts = (j['attachments'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((a) => a['file_name'])
        .toList();
    expect(atts,
        containsAll(['TestFontA.ttf', 'TestFontB.otf', 'NewFont.ttf']));
  });

  test('外部字幕延迟（--sync）正确应用', () async {
    final ext = p.join(tmp.path, 'delay.srt');
    File(ext).writeAsStringSync('1\n00:00:00,000 --> 00:00:02,000\n延迟\n');

    final out = p.join(tmp.path, 'delay.mkv');
    final task = await runMux(
      tracks: [
        MuxTrack(
          type: MuxTrackType.subtitle,
          path: ext,
          language: 'chi',
          delayMs: 500,
        ),
      ],
      sourceSel: sel(),
      out: out,
    );

    expect(task.status, TaskStatus.completed,
        reason: '延迟轨封装失败：${task.error ?? ''}');
    final j = await jsonOf(out);
    final sub = tracksOf(j).firstWhere((t) => t['type'] == 'subtitles');
    final text = await extractSub(out, sub);
    expect(text, contains('00:00:00,500 --> 00:00:02,500'));
  });

  test('GBK 字幕预转 UTF-8 封装成功，内容与延迟元数据不丢失', () async {
    const body = '这是一条GBK编码的测试字幕内容';
    final gbkFile = p.join(tmp.path, 'gbk.srt');
    File(gbkFile).writeAsBytesSync(
      gbk.encode('1\n00:00:00,000 --> 00:00:02,000\n$body\n'),
    );

    final out = p.join(tmp.path, 'gbk.mkv');
    final task = await runMux(
      tracks: [
        MuxTrack(
          type: MuxTrackType.subtitle,
          path: gbkFile,
          language: 'chi',
          title: '简体中文',
          isDefault: true,
          delayMs: 500,
        ),
      ],
      sourceSel: sel(),
      out: out,
    );

    expect(task.status, TaskStatus.completed,
        reason: 'GBK 字幕封装失败：${task.error ?? ''}');
    final j = await jsonOf(out);
    final sub = tracksOf(j).firstWhere((t) => t['type'] == 'subtitles');
    expect(props(sub)['track_name'], '简体中文');
    expect(props(sub)['default_track'], isTrue);
    final text = await extractSub(out, sub);
    // 预转后内容不乱码；延迟（预转重建轨道时不得丢失）同样生效
    expect(text, contains(body));
    expect(text, contains('00:00:00,500 --> 00:00:02,500'));
  });

  test('禁用外部轨（--track-enabled-flag）封装成功且产物该轨禁用', () async {
    final ext = p.join(tmp.path, 'off.srt');
    File(ext).writeAsStringSync('1\n00:00:00,000 --> 00:00:02,000\noff\n');

    final out = p.join(tmp.path, 'off.mkv');
    final task = await runMux(
      tracks: [
        MuxTrack(
          type: MuxTrackType.subtitle,
          path: ext,
          language: 'chi',
          enabled: false,
        ),
      ],
      sourceSel: sel(),
      out: out,
    );

    expect(task.status, TaskStatus.completed,
        reason: '禁用轨封装失败：${task.error ?? ''}');
    final j = await jsonOf(out);
    final sub = tracksOf(j).firstWhere((t) => t['type'] == 'subtitles');
    expect(props(sub)['enabled_track'], isFalse);
  });

  test('源轨道编辑禁用源音轨：任务成功且产物音轨禁用', () async {
    final out = p.join(tmp.path, 'editoff.mkv');
    final task = await runMux(
      tracks: const [],
      sourceSel: sel(edits: [
        {'id': 0, 'enabled': false},
      ]),
      out: out,
    );

    expect(task.status, TaskStatus.completed,
        reason: '源轨编辑封装失败：${task.error ?? ''}');
    final j = await jsonOf(out);
    final audio = tracksOf(j).firstWhere((t) => t['type'] == 'audio');
    expect(props(audio)['enabled_track'], isFalse);
  });
}
