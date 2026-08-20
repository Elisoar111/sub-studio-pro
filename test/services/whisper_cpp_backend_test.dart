import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:subtitle_studio_pro/services/storage_service.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_models.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// v1.3 whisper.cpp 实验性后端：枚举项默认隐藏，检测到可执行文件才显示；
/// 参数面按 whisper.cpp CLI（-m/-f/-osrt/-of/-ng）映射，预设 / 初始提示词 /
/// 自定义参数不适用（实验性限制）。
void main() {
  group('WhisperBackend.whisperCpp 枚举', () {
    test('code / label / experimental 标记；fromCode round-trip', () {
      const b = WhisperBackend.whisperCpp;
      expect(b.code, 'cpp');
      expect(b.label, contains('whisper.cpp'));
      expect(b.label, contains('实验性'));
      expect(b.experimental, isTrue);
      for (final other in [
        WhisperBackend.auto,
        WhisperBackend.openai,
        WhisperBackend.faster,
      ]) {
        expect(other.experimental, isFalse);
      }
      expect(WhisperBackend.fromCode('cpp'), b);
    });
  });

  group('selectableWhisperBackends 可见性门禁', () {
    test('未检测到可执行：隐藏实验性项，其余三项齐全', () {
      final list =
          selectableWhisperBackends(cppAvailable: false, selected: null);
      expect(list, containsAll([
        WhisperBackend.auto,
        WhisperBackend.openai,
        WhisperBackend.faster,
      ]));
      expect(list, isNot(contains(WhisperBackend.whisperCpp)));
    });

    test('检测到可执行：显示实验性项', () {
      expect(
        selectableWhisperBackends(cppAvailable: true, selected: null),
        contains(WhisperBackend.whisperCpp),
      );
    });

    test('已是当前持久化选择时保留（避免下拉 value 不在 items 的断言）', () {
      expect(
        selectableWhisperBackends(
            cppAvailable: false, selected: WhisperBackend.whisperCpp),
        contains(WhisperBackend.whisperCpp),
      );
    });
  });

  group('cppModelName：openai 模型名 → ggml 文件名', () {
    test('常见模型名映射', () {
      expect(WhisperService.cppModelName('base'), 'ggml-base.bin');
      expect(WhisperService.cppModelName('large-v3'), 'ggml-large-v3.bin');
      expect(
          WhisperService.cppModelName('large-v3-turbo'), 'ggml-large-v3-turbo.bin');
    });

    test('已带 ggml- 前缀原样；裸 .bin 扩展去重后补前缀', () {
      expect(WhisperService.cppModelName('ggml-medium.bin'), 'ggml-medium.bin');
      expect(WhisperService.cppModelName('small.bin'), 'ggml-small.bin');
    });
  });

  group('findCppExecutable：可执行文件检测（纯函数）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('whisper_cpp');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('PATH 扫描：whisper-cli.exe 全目录优先于任何位置的 main.exe', () async {
      final dirA = Directory(p.join(tmp.path, 'a'))..createSync();
      File(p.join(dirA.path, 'main.exe')).writeAsBytesSync([1]);
      final dirB = Directory(p.join(tmp.path, 'b'))..createSync();
      File(p.join(dirB.path, 'whisper-cli.exe')).writeAsBytesSync([1]);
      expect(
        WhisperService.findCppExecutable([dirA.path, dirB.path]),
        p.join(dirB.path, 'whisper-cli.exe'),
      );
    });

    test('自定义目录：目录内含 cpp 可执行 → 返回完整路径', () async {
      final exe = File(p.join(tmp.path, 'whisper-cli.exe'))
        ..writeAsBytesSync([1]);
      expect(
        WhisperService.findCppExecutable(const [], configured: tmp.path),
        exe.path,
      );
    });

    test('自定义文件：whisper-cli.exe / main.exe 接受；whisper.exe（openai）拒绝',
        () async {
      final cli = File(p.join(tmp.path, 'whisper-cli.exe'))
        ..writeAsBytesSync([1]);
      expect(
        WhisperService.findCppExecutable(const [], configured: cli.path),
        cli.path,
      );
      expect(
        WhisperService.findCppExecutable(const [],
            configured: p.join(tmp.path, 'main.exe')),
        p.join(tmp.path, 'main.exe'),
        reason: '路径本身即可执行文件名时按名字接受（探测阶段再验证）',
      );
      expect(
        WhisperService.findCppExecutable(const [],
            configured: p.join(tmp.path, 'whisper.exe')),
        isNull,
      );
    });

    test('均未命中 → null', () {
      final empty = Directory(p.join(tmp.path, 'empty'))..createSync();
      expect(
        WhisperService.findCppExecutable([empty.path], configured: empty.path),
        isNull,
      );
    });
  });

  group('buildArgs whisper.cpp 分支', () {
    List<String> cppArgs({
      String? language,
      bool useGpu = false,
      String outputFormat = 'srt',
      String? cacheDir,
      String? initialPrompt,
      int presetChoice = 1,
    }) =>
        WhisperService.buildArgs(
          inputPath: 'a.mkv',
          outputDir: 'out',
          model: 'base',
          outputFormat: outputFormat,
          language: language,
          useGpu: useGpu,
          presetChoice: presetChoice,
          initialPrompt: initialPrompt,
          cacheDir: cacheDir,
          backend: WhisperBackend.whisperCpp,
        );

    test('核心参数：-m / -f / -osrt / -of <out>/<主名>', () {
      final a = cppArgs();
      expect(a.join(' '), contains('-m ggml-base.bin'));
      expect(a.join(' '), contains('-f a.mkv'));
      expect(a, contains('-osrt'));
      expect(a.join(' '), contains('-of ${p.join('out', 'a')}'));
    });

    test('cacheDir 提供时 -m 为完整路径', () {
      expect(
        cppArgs(cacheDir: 'cache').join(' '),
        contains('-m ${p.join('cache', 'ggml-base.bin')}'),
      );
    });

    test('CPU 加 -ng；GPU 不加', () {
      expect(cppArgs(), contains('-ng'));
      expect(cppArgs(useGpu: true), isNot(contains('-ng')));
    });

    test('语言 -l；自动检测省略', () {
      expect(cppArgs(language: 'zh'), contains('-l'));
      expect(cppArgs(language: ''), isNot(contains('-l')));
    });

    test('格式映射：vtt→-ovtt、txt→-otxt；json/tsv/all 回退 -osrt', () {
      expect(cppArgs(outputFormat: 'vtt'), contains('-ovtt'));
      expect(cppArgs(outputFormat: 'txt'), contains('-otxt'));
      expect(cppArgs(outputFormat: 'json'), contains('-osrt'));
      expect(cppArgs(outputFormat: 'all'), contains('-osrt'));
    });

    test('不含 openai 风格参数与预设/提示词（实验性限制）', () {
      final a = cppArgs(initialPrompt: '提示词', presetChoice: 1).join(' ');
      for (final token in [
        '--model',
        '--output_format',
        '--output_dir',
        '--device',
        '--fp16',
        '--compute_type',
        'beam_size',
        'initial_prompt',
      ]) {
        expect(a, isNot(contains(token)));
      }
    });
  });

  group('服务集成（whisper.cpp 后端选择）', () {
    setUpAll(() {
      StorageService.instance.useMemoryStoreForTesting();
    });

    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('whisper_cpp_svc');
      WhisperService.instance.resetForTesting();
    });

    tearDown(() async {
      WhisperService.probeOverride = null;
      await tmp.delete(recursive: true);
    });

    test('选 cpp 后端 + 自定义路径：以 --help 探测 whisper-cli 生效', () async {
      final exe = File(p.join(tmp.path, 'whisper-cli.exe'))
        ..writeAsBytesSync([1]);
      String? seenCmd;
      List<String>? seenArgs;
      WhisperService.probeOverride = (cmd, args) async {
        seenCmd = cmd;
        seenArgs = args;
        return ProcessResult(0, 0, '', '');
      };

      await WhisperService.instance
          .configure(exe.path, null, backendCode: 'cpp');

      expect(WhisperService.instance.isAvailable, isTrue);
      expect(WhisperService.instance.backend, WhisperBackend.whisperCpp);
      expect(seenCmd, exe.path);
      expect(seenArgs, ['--help']);
    });

    test('自定义路径命中同时置位 cppAvailable（UI 显示实验项）', () async {
      final exe = File(p.join(tmp.path, 'whisper-cli.exe'))
        ..writeAsBytesSync([1]);
      WhisperService.probeOverride =
          (cmd, args) async => ProcessResult(0, 0, '', '');

      await WhisperService.instance
          .configure(exe.path, null, backendCode: 'cpp');

      expect(WhisperService.instance.cppAvailable.value, isTrue);
    });

    test('模型下载：cpp 后端返回明确不支持提示', () async {
      final exe = File(p.join(tmp.path, 'whisper-cli.exe'))
        ..writeAsBytesSync([1]);
      WhisperService.probeOverride =
          (cmd, args) async => ProcessResult(0, 0, '', '');

      await WhisperService.instance
          .configure(exe.path, null, backendCode: 'cpp');

      final r = await WhisperService.instance.downloadModel(model: 'base');
      expect(r.success, isFalse);
      expect(r.error, contains('ggml'));
    });
  });
}
