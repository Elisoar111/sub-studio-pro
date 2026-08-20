import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// Whisper 输出命名规则：`<源文件主名>_<模型名><扩展名>`，重名追加 _1/_2…
/// （whisper CLI 固定写 `<主名><ext>`，重命名逻辑由应用侧完成）
void main() {
  group('buildOutputBase', () {
    test('源文件主名 + 下划线 + 模型名', () {
      expect(
        WhisperService.buildOutputBase(inputPath: r'D:\video\demo.mp4', model: 'small'),
        'demo_small',
      );
      expect(
        WhisperService.buildOutputBase(inputPath: 'a.b.mkv', model: 'large-v3-turbo'),
        'a.b_large-v3-turbo',
      );
    });
  });

  group('expectedOutputPath（带模型）', () {
    test('输出目录/主名_模型/扩展名', () {
      expect(
        WhisperService.expectedOutputPath(
          inputPath: r'D:\video\demo.mp4',
          outputDir: r'D:\out',
          outputFormat: 'srt',
          model: 'small',
        ),
        r'D:\out\demo_small.srt',
      );
      expect(
        WhisperService.expectedOutputPath(
          inputPath: r'D:\video\a.b.mkv',
          outputDir: r'D:\out',
          outputFormat: 'vtt',
          model: 'turbo',
        ),
        r'D:\out\a.b_turbo.vtt',
      );
    });

    test('all 格式取 .srt 主产物', () {
      expect(
        WhisperService.expectedOutputPath(
          inputPath: 'demo.mp4',
          outputDir: r'D:\out',
          outputFormat: 'all',
          model: 'base',
        ),
        p.join(r'D:\out', 'demo_base.srt'),
      );
    });
  });

  group('adoptOutput（whisper 产物重命名，真实文件）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('whisper_naming_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    File writeFile(String name, [String content = 'x']) {
      final f = File(p.join(tmp.path, name));
      f.writeAsStringSync(content);
      return f;
    }

    test('首次：demo.srt → demo_small.srt', () async {
      final written = writeFile('demo.srt', '1');
      final out = await WhisperService.adoptOutput(written.path, 'small');
      expect(out, p.join(tmp.path, 'demo_small.srt'));
      expect(File(out).existsSync(), isTrue);
      expect(written.existsSync(), isFalse, reason: '原文件应已被重命名');
      expect(File(out).readAsStringSync(), '1');
    });

    test('重名：已存在 demo_small.srt 时新产物 → demo_small_1.srt', () async {
      writeFile('demo_small.srt', '旧');
      final written = writeFile('demo.srt', '新');
      final out = await WhisperService.adoptOutput(written.path, 'small');
      expect(out, p.join(tmp.path, 'demo_small_1.srt'));
      expect(File(out).readAsStringSync(), '新');
      expect(File(p.join(tmp.path, 'demo_small.srt')).readAsStringSync(), '旧');
    });

    test('连续重名：_1 也占用时 → _2', () async {
      writeFile('demo_small.srt');
      writeFile('demo_small_1.srt');
      final written = writeFile('demo.srt');
      final out = await WhisperService.adoptOutput(written.path, 'small');
      expect(out, p.join(tmp.path, 'demo_small_2.srt'));
    });

    test('源文件不存在时返回原路径', () async {
      final missing = p.join(tmp.path, 'ghost.srt');
      final out = await WhisperService.adoptOutput(missing, 'small');
      expect(out, missing);
    });

    test('其他扩展名同样生效（vtt）', () async {
      final written = writeFile('demo.vtt');
      final out = await WhisperService.adoptOutput(written.path, 'small');
      expect(p.extension(out), '.vtt');
      expect(p.basenameWithoutExtension(out), 'demo_small');
    });
  });
}
