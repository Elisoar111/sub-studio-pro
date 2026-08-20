import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_models.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// v1.2 Whisper 后端（faster-whisper / whisper-ctranslate2）：
/// buildArgs 后端分支、VAD 过滤、GPU 探测、初始提示词 {episode} 模板。
void main() {
  group('WhisperBackend 枚举', () {
    test('code 序列化/反序列化 round-trip；未知码回退 auto', () {
      for (final b in WhisperBackend.values) {
        expect(WhisperBackend.fromCode(b.code), b);
      }
      expect(WhisperBackend.fromCode('nope'), WhisperBackend.auto);
      expect(WhisperBackend.fromCode(null), WhisperBackend.auto);
    });
  });

  group('buildArgs 后端分支', () {
    List<String> args({
      WhisperBackend backend = WhisperBackend.openai,
      bool useGpu = false,
      bool vad = false,
    }) =>
        WhisperService.buildArgs(
          inputPath: 'a.mkv',
          outputDir: 'out',
          model: 'small',
          outputFormat: 'srt',
          useGpu: useGpu,
          backend: backend,
          vadFilter: vad,
        );

    test('openai + CPU：--fp16 False，无 compute_type', () {
      final a = args();
      expect(a, containsAll(['--fp16', 'False']));
      expect(a.join(' '), isNot(contains('compute_type')));
    });

    test('faster + CPU：--compute_type int8 替代 --fp16 False', () {
      final a = args(backend: WhisperBackend.faster);
      expect(a.join(' '), contains('--compute_type int8'));
      expect(a.join(' '), isNot(contains('--fp16')));
    });

    test('两种后端 + GPU：cuda 且无 fp16 False', () {
      for (final b in [WhisperBackend.openai, WhisperBackend.faster]) {
        final a = args(backend: b, useGpu: true);
        expect(a, containsAll(['--device', 'cuda']));
        expect(a.join(' '), isNot(contains('--fp16 False')));
      }
    });

    test('VAD：仅 faster 后端追加 --vad_filter true；openai 忽略', () {
      final f = args(backend: WhisperBackend.faster, vad: true);
      expect(f.join(' '), contains('--vad_filter true'));

      final o = args(backend: WhisperBackend.openai, vad: true);
      expect(o.join(' '), isNot(contains('vad_filter')));
    });

    test('公共参数两种后端一致（model/format/dir/device）', () {
      final o = args();
      final f = args(backend: WhisperBackend.faster);
      for (final a in [o, f]) {
        expect(a.first, 'a.mkv');
        for (final flag in ['--model', '--output_format', '--output_dir', '--device']) {
          expect(a, contains(flag));
        }
      }
    });
  });

  group('detectNvidiaGpu', () {
    test('nvidia-smi -L 退出码 0 → true', () async {
      final r = await WhisperService.detectNvidiaGpu(
        runner: (cmd, args) async => ProcessResult(1, 0, '', ''),
      );
      expect(r, isTrue);
    });

    test('命令不存在 / 非零退出码 → false', () async {
      expect(
        await WhisperService.detectNvidiaGpu(
          runner: (cmd, args) async => throw ProcessException(cmd, args),
        ),
        isFalse,
      );
      expect(
        await WhisperService.detectNvidiaGpu(
          runner: (cmd, args) async => ProcessResult(1, 1, '', 'err'),
        ),
        isFalse,
      );
    });

    test('探测命令固定为 nvidia-smi -L', () async {
      String? seenCmd;
      List<String>? seenArgs;
      await WhisperService.detectNvidiaGpu(
        runner: (cmd, args) async {
          seenCmd = cmd;
          seenArgs = args;
          return ProcessResult(1, 0, '', '');
        },
      );
      expect(seenCmd, 'nvidia-smi');
      expect(seenArgs, ['-L']);
    });
  });

  group('初始提示词模板 {episode}', () {
    test('常见集数模式提取', () {
      expect(WhisperService.extractEpisode('Show - 12 [1080p]'), '12');
      expect(WhisperService.extractEpisode('MyShow EP03 720p'), '03');
      expect(WhisperService.extractEpisode('某番第05话'), '05');
      expect(WhisperService.extractEpisode('第12集'), '12');
    });

    test('无集数模式返回 null', () {
      expect(WhisperService.extractEpisode('random movie name'), isNull);
      expect(WhisperService.extractEpisode('2024年度总结'), isNull);
    });

    test('expandInitialPrompt 替换 {episode}；无匹配时移除占位符', () {
      expect(
        WhisperService.expandInitialPrompt(
            '以下是{episode}集的术语表', 'Show - 12 [1080p].mkv'),
        '以下是12集的术语表',
      );
      expect(
        WhisperService.expandInitialPrompt('第{episode}话', 'movie.mkv'),
        '第话',
      );
    });

    test('不含占位符原样返回', () {
      expect(
        WhisperService.expandInitialPrompt('普通提示词', 'a - 1.mkv'),
        '普通提示词',
      );
    });

    test('多个 {episode} 全部替换', () {
      expect(
        WhisperService.expandInitialPrompt('{episode} {episode}', 'EP07.mkv'),
        '07 07',
      );
    });
  });

  test('json 可编码性冒烟（枚举 code 为纯字符串）', () {
    final m = {'backend': WhisperBackend.faster.code};
    expect(jsonDecode(jsonEncode(m))['backend'], 'faster');
  });
}
