import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/models/task_params.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/mkvtoolnix/mkvtoolnix_service.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';

/// 纯重封装回归测试（dev-fix）：
/// 对同一 MKV 删减源轨道（无任何外部轨道文件）的封装任务必须成功执行，
/// 而不是被队列以「封装轨道列表为空」拒绝。
///
/// 夹具：audio@0 + subs@1,2,3（chi/eng/jpn），mkvmerge 现场生成；
/// 断言产物轨道构成与勾选一致（被取消勾选的轨道确实被删掉）。
void main() {
  final tmp = Directory.systemTemp.createTempSync('mux_pure_remux');
  late String fixture;
  late String mkvmerge;

  setUpAll(() async {
    mkvmerge = <String>[
      r'D:\Program Files\MKVToolNix\mkvmerge.exe',
      r'C:\Program Files\MKVToolNix\mkvmerge.exe',
      r'C:\Program Files (x86)\MKVToolNix\mkvmerge.exe',
      'mkvmerge',
    ].firstWhere((path) {
      if (!path.contains(Platform.pathSeparator) && !path.contains('/')) {
        return true; // 裸命令名，交给 PATH
      }
      return File(path).existsSync();
    });

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

    // 字体附件夹具（mkvmerge 不校验内容）；-J 附件 ID 从 1 起
    for (final font in ['TestFontA.ttf', 'TestFontB.otf']) {
      File(p.join(tmp.path, font))
          .writeAsBytesSync(List<int>.filled(256, 0x1a));
    }

    // 音频在前 → fixture 内 audio id=0，subs id=1,2,3
    fixture = p.join(tmp.path, 'fix.mkv');
    final r = await Process.run(mkvmerge, [
      '-o', fixture,
      '--attach-file', p.join(tmp.path, 'TestFontA.ttf'),
      '--attach-file', p.join(tmp.path, 'TestFontB.otf'),
      '--language', '0:jpn', wav.path,
      '--language', '0:chi', p.join(tmp.path, 'chi.srt'),
      '--language', '0:eng', p.join(tmp.path, 'eng.srt'),
      '--language', '0:jpn', p.join(tmp.path, 'jpn.srt'),
    ]);
    expect(r.exitCode, anyOf(0, 1), reason: '夹具生成失败：${r.stderr}');

    await MkvToolNixService.instance.init();
    expect(MkvToolNixService.instance.isAvailable, isTrue,
        reason: 'MKVToolNix 不可用，无法运行纯重封装测试');
    final ffmpeg = await FfmpegService.create();
    QueueService.instance.init(ffmpeg: ffmpeg);
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  /// 入队一个与封装页 _start() 生成的完全一致的纯重封装任务并执行。
  Future<QueueTask> runPureRemux(Map<String, dynamic> sourceSel, String out) {
    final task = QueueService.instance.addTask(
      type: TaskType.mux,
      title: '纯重封装',
      params: {
        TaskParams.videoPath: fixture,
        TaskParams.tracksJson: '[]',
        TaskParams.container: 'mkv',
        TaskParams.sourceSel: jsonEncode(sourceSel),
        TaskParams.outputPath: out,
        TaskParams.totalDurationMs: '3000',
      },
    );
    return QueueService.instance.start().then((_) => task);
  }

  /// mkvmerge -J 产物轨道构成（type@lang 列表）。
  Future<List<String>> tracksOf(String path) async {
    final r = await Process.run(mkvmerge, ['-J', path]);
    final data = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    return [
      for (final t in (data['tracks'] as List))
        '${t['type']}@${(t['properties'] as Map<String, dynamic>)['language']}',
    ];
  }

  /// mkvmerge -J 产物附件构成（id:文件名 列表）。
  Future<List<String>> attachmentsOf(String path) async {
    final r = await Process.run(mkvmerge, ['-J', path]);
    final data = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    return [
      for (final a in (data['attachments'] as List? ?? const []))
        '${a['id']}:${a['file_name']}',
    ];
  }

  test('取消勾选部分源字幕后封装必须成功（不再报「封装轨道列表为空」）', () async {
    final out = p.join(tmp.path, 'partial.mkv');
    final task = await runPureRemux({
      'audio': [0],
      'subs': [1], // 仅保留 chi；eng/jpn 被取消勾选
      'chapters': true,
      'tags': true,
    }, out);

    expect(task.status, TaskStatus.completed,
        reason: '纯重封装失败：${task.error ?? ''}');
    expect(File(out).existsSync(), isTrue);
    expect(await tracksOf(out), ['audio@jpn', 'subtitles@chi']);
  });

  test('默认选择（音轨保留、内嵌字幕全不保留）的纯重封装成功', () async {
    final out = p.join(tmp.path, 'defaults.mkv');
    final task = await runPureRemux({
      'audio': [0],
      'subs': <int>[],
      'chapters': true,
      'tags': true,
    }, out);

    expect(task.status, TaskStatus.completed,
        reason: '纯重封装失败：${task.error ?? ''}');
    expect(await tracksOf(out), ['audio@jpn']);
  });

  test('勾选部分源字体附件：产物只含勾选的字体', () async {
    final out = p.join(tmp.path, 'fontsel.mkv');
    final task = await runPureRemux({
      'audio': [0],
      'subs': <int>[],
      'chapters': true,
      'tags': true,
      'fonts': [1], // 只保留 AID 1（TestFontA.ttf）
    }, out);

    expect(task.status, TaskStatus.completed,
        reason: '字体选择封装失败：${task.error ?? ''}');
    expect(await attachmentsOf(out), ['1:TestFontA.ttf']);
  });

  test('字体全不勾选：产物无附件', () async {
    final out = p.join(tmp.path, 'nofonts.mkv');
    final task = await runPureRemux({
      'audio': [0],
      'subs': <int>[],
      'chapters': true,
      'tags': true,
      'fonts': <int>[],
    }, out);

    expect(task.status, TaskStatus.completed,
        reason: '字体排除封装失败：${task.error ?? ''}');
    expect(await attachmentsOf(out), isEmpty);
  });

  test('旧任务（sourceSel 无 fonts 字段）：源附件默认全保留', () async {
    final out = p.join(tmp.path, 'legacyfonts.mkv');
    final task = await runPureRemux({
      'audio': [0],
      'subs': <int>[],
      'chapters': true,
      'tags': true,
    }, out);

    expect(task.status, TaskStatus.completed,
        reason: '旧任务封装失败：${task.error ?? ''}');
    expect(await attachmentsOf(out), hasLength(2));
  });
}
