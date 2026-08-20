import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_models.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// Whisper CLI 参数构建（对齐 WhisperElectron buildArgs，openai-whisper transcribe.py）。
void main() {
  group('WhisperService.buildArgs', () {
    test('基础参数：输入/模型/格式/输出目录/CPU 设备', () {
      final args = WhisperService.buildArgs(
        inputPath: r'D:\video\demo.mp4',
        outputDir: r'D:\video',
        model: 'small',
        outputFormat: 'srt',
      );
      expect(args, containsAllInOrder([
        r'D:\video\demo.mp4',
        '--model', 'small',
        '--output_format', 'srt',
        '--device', 'cpu',
        '--output_dir', r'D:\video',
        '--fp16', 'False',
      ]));
      // 自动检测语言：不传 --language
      expect(args, isNot(contains('--language')));
      expect(args, isNot(contains('--initial_prompt')));
    });

    test('GPU：cuda 设备且不追加 --fp16 False', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        useGpu: true,
      );
      expect(args, containsAllInOrder(['--device', 'cuda']));
      expect(args, isNot(contains('--fp16')));
    });

    test('语言参数：指定中文 → --language zh', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        language: 'zh',
      );
      expect(args, containsAllInOrder(['--language', 'zh']));
    });

    test('英文专用模型（.en）强制 language=en，即使传了其他语言', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small.en',
        outputFormat: 'srt',
        language: 'zh',
      );
      final i = args.indexOf('--language');
      expect(args[i + 1], 'en');
    });

    test('英文专用模型：语言为空（自动）时不传 --language', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'base.en',
        outputFormat: 'srt',
      );
      expect(args, isNot(contains('--language')));
    });

    test('初始提示词：非空才传 --initial_prompt', () {
      final withPrompt = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        initialPrompt: '  以下是字幕  ',
      );
      expect(withPrompt, containsAllInOrder(['--initial_prompt', '以下是字幕']));

      final noPrompt = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        initialPrompt: '   ',
      );
      expect(noPrompt, isNot(contains('--initial_prompt')));
    });

    test('预设 1（通用最佳默认）附加完整参数串', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        presetChoice: 1,
      );
      expect(
          args.join(' '),
          contains(
              '--beam_size 5 --temperature 0.0 --condition_on_previous_text '
              'True --compression_ratio_threshold 2.4 --logprob_threshold '
              '-1.0 --no_speech_threshold 0.6'));
    });

    test('预设 6：自定义参数按空白切分附加', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        presetChoice: 6,
        customParams: ' --beam_size 8  --temperature 0.3 ',
      );
      expect(args.sublist(args.length - 4),
          ['--beam_size', '8', '--temperature', '0.3']);
    });

    test('预设 6：自定义参数为空则不附加', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        presetChoice: 6,
      );
      expect(args, isNot(contains('--beam_size')));
    });

    test('自定义缓存目录 → --model_dir', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        cacheDir: r'D:\models\whisper',
      );
      expect(args, containsAllInOrder(['--model_dir', r'D:\models\whisper']));
    });

    test('未知预设号：不附加任何预设参数', () {
      final args = WhisperService.buildArgs(
        inputPath: 'a.mp4',
        outputDir: '.',
        model: 'small',
        outputFormat: 'srt',
        presetChoice: 99,
      );
      expect(args, isNot(contains('--beam_size')));
    });
  });

  group('输出文件路径', () {
    test('格式 → 扩展名映射（all 取 .srt）', () {
      expect(WhisperService.outputExtensionFor('srt'), '.srt');
      expect(WhisperService.outputExtensionFor('vtt'), '.vtt');
      expect(WhisperService.outputExtensionFor('txt'), '.txt');
      expect(WhisperService.outputExtensionFor('json'), '.json');
      expect(WhisperService.outputExtensionFor('tsv'), '.tsv');
      expect(WhisperService.outputExtensionFor('all'), '.srt');
      expect(WhisperService.outputExtensionFor('未知'), '.srt');
    });

    test('whisper 原始写出路径 = 输出目录/输入主名/扩展名（重命名前）', () {
      expect(
        WhisperService.rawOutputPath(
          inputPath: r'D:\video\demo.mp4',
          outputDir: r'D:\out',
          outputFormat: 'srt',
        ),
        r'D:\out\demo.srt',
      );
      expect(
        WhisperService.rawOutputPath(
          inputPath: r'D:\video\a.b.mkv',
          outputDir: r'D:\out',
          outputFormat: 'vtt',
        ),
        r'D:\out\a.b.vtt',
      );
    });
  });

  group('模型清单（与 openai-whisper _MODELS 一致）', () {
    test('全部模型均为 openai-whisper 有效模型名', () {
      const valid = {
        'tiny.en', 'tiny', 'base.en', 'base', 'small.en', 'small',
        'medium.en', 'medium', 'large-v1', 'large-v2', 'large-v3', 'large',
        'large-v3-turbo', 'turbo',
      };
      for (final c in whisperModelCategories) {
        for (final m in c.models) {
          expect(valid, contains(m), reason: '模型 $m 不在 openai-whisper 清单中');
        }
      }
      expect(whisperModelInfo.keys.toSet(), valid);
    });

    test('模型不重复且都有说明', () {
      final all = [
        for (final c in whisperModelCategories) ...c.models,
      ];
      expect(all.toSet().length, all.length);
      for (final m in all) {
        expect(whisperModelInfo[m], isNotNull, reason: '$m 缺少说明信息');
      }
    });

    test('输出格式不含 whisper CLI 不支持的 csv', () {
      for (final f in whisperFormats) {
        expect(f.name, isNot('csv'));
        expect(whisperFormatExtension.containsKey(f.name), isTrue);
      }
    });

    test('语言清单：9 项，自动检测参数为空串', () {
      expect(whisperLanguages.length, 9);
      final auto = whisperLanguages.firstWhere((l) => l.name == '自动检测');
      expect(auto.code, isEmpty);
      expect(whisperLanguages.map((l) => l.code).toSet().length, 9);
    });

    test('预设清单：6 项，第 6 项为空参数（自定义）', () {
      expect(whisperPresets.length, 6);
      expect(whisperPresets.last.args, isEmpty);
    });
  });
}
