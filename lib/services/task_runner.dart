import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../core/utils/logger.dart';
import '../models/encode_options.dart';
import '../models/mux_track.dart';
import '../models/queue_task.dart';
import '../models/subtitle.dart';
import '../models/task_params.dart';
import '../providers/app_providers.dart';
import 'ai/glossary_store.dart';
import 'ai/translation_service.dart';
import 'ffmpeg/ffmpeg_runner.dart';
import 'ffmpeg/ffmpeg_service.dart';
import 'mkvtoolnix/mkvtoolnix_service.dart';
import 'subtitle/encoding_detector.dart';
import 'subtitle/subtitle_converter.dart';
import 'subtitle/subtitle_parser.dart';
import 'subtitle/subtitle_writer.dart';
import 'whisper/whisper_service.dart';

/// 独立任务执行器：按 [TaskType] 分发到各 runner（烧录 / 提取 / mux /
/// 转码 / 字幕转换 / AI 翻译 / Whisper）。
///
/// 职责边界（与 QueueService 的拆分约定）：
/// - 本类只负责「怎么执行一个任务」：参数解析、后端调用、进度回写节流；
/// - 队列调度、任务状态流转（pending → running → 终态）、取消令牌登记、
///   历史落盘、批量完成通知全部在 QueueService。
///
/// 进度回写：runner 直接把 time/speed/progress 写进 [QueueTask]，UI 刷新
/// 通过 [notify] 回调（由队列传入 notifyListeners）以 ~4Hz 节流触发。
class TaskRunner {
  const TaskRunner();

  /// 执行单个任务并返回结果；抛出的异常由调用方（队列）兜底。
  ///
  /// 不修改任务 status —— 终态判定（含取消归并）是队列的职责。
  Future<TaskRunResult?> run({
    required QueueTask task,
    required FfmpegService ffmpeg,
    required CancelToken token,
    required void Function() notify,
  }) async {
    // 进度节流：UI 更新限频 ~4Hz，避免任务运行时界面卡顿
    var lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
    void onProgress(FfmpegProgress prog) {
      task.time = prog.time;
      task.speed = prog.speed;
      final frac = prog.fractionOf(_totalOf(task));
      if (frac != null) task.progress = frac;
      final now = DateTime.now();
      if (now.difference(lastNotify) >= const Duration(milliseconds: 250)) {
        lastNotify = now;
        notify();
      }
    }

    void onLog(String line) {
      Logger.instance.ffmpeg(task.id.substring(0, 6), line);
    }

    switch (task.type) {
      case TaskType.subtitleConvert:
        return _runSubtitleConvert(task.params);

      case TaskType.burn:
        final encode = _encodeOf(task);
        final subtitle = task.params[TaskParams.subtitlePath];
        if (subtitle != null && subtitle.isNotEmpty) {
          return ffmpeg.burnSubtitles(
            videoPath: task.params[TaskParams.videoPath]!,
            subtitlePath: subtitle,
            outputPath: task.params[TaskParams.outputPath]!,
            encode: encode,
            useAssFilter:
                (task.params[TaskParams.useAssFilter] ?? 'false') == 'true',
            forceStyle: task.params[TaskParams.forceStyle],
            fontsDir: task.params[TaskParams.fontsDir],
            totalDuration: _totalOf(task),
            onProgress: onProgress,
            onLog: onLog,
            cancelToken: token,
          );
        }
        // 内嵌字幕轨烧录
        final track =
            int.tryParse(task.params[TaskParams.trackIndex] ?? '') ?? 0;
        return ffmpeg.burnEmbeddedTrack(
          videoPath: task.params[TaskParams.videoPath]!,
          trackIndex: track,
          outputPath: task.params[TaskParams.outputPath]!,
          encode: encode,
          useAssFilter:
              (task.params[TaskParams.useAssFilter] ?? 'false') == 'true',
          forceStyle: task.params[TaskParams.forceStyle],
          fontsDir: task.params[TaskParams.fontsDir],
          totalDuration: _totalOf(task),
          onProgress: onProgress,
          onLog: onLog,
          cancelToken: token,
        );

      case TaskType.extract:
        // 唯一后端 mkvextract（gMKVExtractGUI 方式）：
        // streamIndex = mkvmerge -J 轨道/附件 ID；非 MKV 输入由服务端
        // 先无损转封为临时 MKV 再提取。
        if (!task.params.containsKey(TaskParams.typeOrdinal)) {
          return const TaskRunResult(
            success: false,
            error: '旧版任务使用 FFmpeg 提取，已不再支持：请在提取页重新创建任务',
          );
        }
        return MkvToolNixService.instance.extractTrackAuto(
          videoPath: task.params[TaskParams.videoPath]!,
          id: int.tryParse(task.params[TaskParams.streamIndex] ?? '') ?? 0,
          trackType: task.params[TaskParams.trackType] ?? 'subtitle',
          outputPath: task.params[TaskParams.outputPath]!,
          typeOrdinal:
              int.tryParse(task.params[TaskParams.typeOrdinal] ?? '') ?? 0,
          totalDuration: _totalOf(task),
          onProgress: onProgress,
          onLog: onLog,
          cancelToken: token,
        );

      case TaskType.transcode:
        return ffmpeg.transcode(
          inputPath: task.params[TaskParams.videoPath]!,
          outputPath: task.params[TaskParams.outputPath]!,
          encode: _encodeOf(task),
          totalDuration: _totalOf(task),
          onProgress: onProgress,
          onLog: onLog,
          cancelToken: token,
        );

      case TaskType.mux:
        return _runMux(task, token, onProgress: onProgress, onLog: onLog);

      case TaskType.subtitleTranslate:
        return _runSubtitleTranslate(task, token, notify: notify);

      case TaskType.whisper:
        return _runWhisper(task, token, onProgress: onProgress, onLog: onLog);
    }
  }

  /// 封装轨道任务：文本字幕非 UTF-8 时先预转（保证容器内字幕编码统一），
  /// 再执行全类型 mux（字幕 / 音频 / 附件）。
  Future<TaskRunResult> _runMux(
    QueueTask task,
    CancelToken token, {
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
  }) async {
    var tracks = MuxTrack.decodeList(task.params[TaskParams.tracksJson] ?? '');
    if (tracks.isEmpty) {
      // v1 旧任务（tracksJson 引入前）以 subtitlePaths/languages/titles 存储，
      // 历史重跑时降级重建字幕轨
      final legacyPaths = _jsonStringList(task.params['subtitlePaths']);
      if (legacyPaths.isNotEmpty) {
        final langs = _jsonStringList(task.params['subLanguages']);
        final titles = _jsonStringList(task.params['subTitles']);
        tracks = [
          for (var i = 0; i < legacyPaths.length; i++)
            MuxTrack(
              type: MuxTrackType.subtitle,
              path: legacyPaths[i],
              language: i < langs.length ? langs[i] : 'chi',
              title: i < titles.length ? titles[i] : '',
              isDefault: i == 0,
            ),
        ];
      }
      // 纯重封装（无外部轨道，仅按 sourceSel 删减源轨道）合法：tracks 保持空，
      // 不得以「轨道列表为空」拒绝
    }

    // 文本字幕统一转 UTF-8（GBK/BIG5 直接 copy 进容器会乱码；
    // mkvmerge 按 UTF-8 读取，预转必要；纯 Dart 实现，不涉及 FFmpeg）
    final temp = await MkvToolNixService.instance.tempDir();
    final normalized = <MuxTrack>[];
    final tempFiles = <String>[];
    for (final t in tracks) {
      if (t.type != MuxTrackType.subtitle) {
        normalized.add(t);
        continue;
      }
      final fixed = await _ensureUtf8Subtitle(t, temp);
      normalized.add(fixed ?? t);
      if (fixed != null) tempFiles.add(fixed.path);
    }
    tracks = normalized;

    // 唯一后端 mkvmerge：输出固定 MKV（源视频/音轨流拷贝，附件保留）
    final outPath = task.params[TaskParams.outputPath]!;
    if (p.extension(outPath).toLowerCase() != '.mkv') {
      _deleteQuiet(tempFiles);
      return const TaskRunResult(
        success: false,
        error: '封装已切换为 MKVToolNix（mkvmerge），仅输出 MKV：'
            '旧版 MP4/MOV 任务请重新创建',
      );
    }
    try {
      final video = task.params[TaskParams.videoPath]!;
      final sel = await _parseSourceSel(task, video);
      return await MkvToolNixService.instance.merge(
        videoPath: video,
        tracks: tracks,
        outputPath: outPath,
        keepAudioIds: sel.$1,
        keepSubIds: sel.$2,
        keepChapters: sel.$3,
        keepTags: sel.$4,
        sourceEdits: sel.$5,
        keepAttachmentIds: sel.$6,
        totalDuration: _totalOf(task),
        onProgress: onProgress,
        onLog: onLog,
        cancelToken: token,
      );
    } finally {
      _deleteQuiet(tempFiles);
    }
  }

  /// 解析源轨道选择：新任务读 sourceSel JSON；旧任务（历史重跑）按
  /// audioMode/keepSubs 映射（null = 该类全保留，[] = 全排除）。
  /// 返回 (音轨, 字幕轨, 章节, 标签, 轨道级编辑, 附件)；附件 null = 全保留。
  Future<(List<int>?, List<int>?, bool, bool, List<SourceTrackEdit>, List<int>?)>
      _parseSourceSel(QueueTask task, String video) async {
    final raw = task.params[TaskParams.sourceSel];
    if (raw != null && raw.isNotEmpty) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        List<int>? ids(String key) => (j[key] as List?)
            ?.map((e) => e as int)
            .toList(growable: false);
        return (
          ids('audio'),
          ids('subs'),
          j['chapters'] != false,
          j['tags'] != false,
          SourceTrackEdit.listFromJson(j['edits']),
          // fonts 缺失（旧任务）= null 全保留，与 mkvmerge 默认行为一致
          ids('fonts'),
        );
      } catch (_) {}
    }
    // 旧参数映射（缺省 = all / false，与 v1 行为一致）
    final audioMode = task.params[TaskParams.audioMode] ?? 'all';
    List<int>? audio;
    if (audioMode == 'none') {
      audio = const [];
    } else if (audioMode == 'first') {
      final id = await MkvToolNixService.instance.firstAudioTrackId(video);
      audio = id == null ? null : [id];
    }
    final subs = (task.params[TaskParams.keepSubs] ?? 'false') == 'true'
        ? null
        : const <int>[];
    return (audio, subs, true, true, const <SourceTrackEdit>[], null);
  }

  static void _deleteQuiet(List<String> paths) {
    for (final path in paths) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// 字幕非 UTF-8 → 纯转码写 UTF-8 临时副本；UTF-8 / 失败时返回 null（原样使用）。
  ///
  /// 只做字节层转码、不做解析重构：parse→rewrite 会把 ASS 的多样式 /
  /// PlayRes / [Fonts] 等结构性信息压成单一 Default 骨架，特效字幕
  /// 封装后样式尽毁。编码转换不需要理解格式语义。
  /// 返回的轨道保留原轨全部元数据（语言/标题/默认/强制/启用/延迟）。
  Future<MuxTrack?> _ensureUtf8Subtitle(
    MuxTrack track,
    String tempDir,
  ) async {
    try {
      final bytes = await File(track.path).readAsBytes();
      final decoded = EncodingDetector.decode(bytes);
      final enc = decoded.encodingName.toLowerCase();
      if (enc == 'utf-8' || enc == 'utf8' || enc == 'us-ascii') return null;
      final outPath = p.join(
        tempDir,
        'mux_utf8_${const Uuid().v4()}${p.extension(track.path)}',
      );
      await File(outPath).writeAsString(
        decoded.text,
        encoding: utf8,
        flush: true,
      );
      return MuxTrack(
        type: MuxTrackType.subtitle,
        path: outPath,
        language: track.language,
        title: track.title,
        isDefault: track.isDefault,
        isForced: track.isForced,
        enabled: track.enabled,
        delayMs: track.delayMs,
      );
    } catch (_) {
      return null;
    }
  }

  /// 解析 JSON 字符串数组（历史任务参数兜底用）。
  static List<String> _jsonStringList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.map((e) => '$e').toList();
    } catch (_) {}
    return const [];
  }

  Duration? _totalOf(QueueTask task) {
    final ms = int.tryParse(task.params[TaskParams.totalDurationMs] ?? '');
    return ms == null || ms <= 0 ? null : Duration(milliseconds: ms);
  }

  /// 字幕格式转换（纯 Dart，Isolate 内执行，不占 FFmpeg 会话）。
  Future<TaskRunResult> _runSubtitleConvert(Map<String, String> params) async {
    final input = params[TaskParams.subtitlePath] ?? '';
    final output = params[TaskParams.outputPath] ?? '';
    final target = params[TaskParams.targetFormat] ?? 'srt';
    if (input.isEmpty || output.isEmpty) {
      return const TaskRunResult(success: false, error: '缺少输入/输出路径');
    }
    try {
      final format =
          SubtitleFormat.values.asNameMap()[target] ?? SubtitleFormat.srt;
      await SubtitleConverter.convertFile(
        inputPath: input,
        outputPath: output,
        options: SubtitleConvertOptions(
          targetFormat: format,
          encoding: params[TaskParams.encoding] ?? 'utf-8',
          includeBom: (params[TaskParams.includeBom] ?? 'false') == 'true',
          microDvdFps: double.tryParse(params[TaskParams.microDvdFps] ?? '') ?? 25,
        ),
      );
      return TaskRunResult(
        success: true,
        outputs: [TaskOutputFile(name: p.basename(output), path: output)],
      );
    } catch (e) {
      return TaskRunResult(success: false, error: '$e');
    }
  }

  VideoEncodeOptions _encodeOf(QueueTask task) =>
      VideoEncodeOptions.fromParams(task.params);

  /// AI 字幕翻译（纯 Dart + 网络，不占 FFmpeg 会话）。
  /// 只翻译文本，时间轴不动；输出格式始终跟随源文件（不转换、不改扩展名）。
  /// 产物：译文 `output`（`源主名_<语言码>`）；任务带 [TaskParams.mixedPath]
  /// 时另存双语内容合并文件（`源主名_mixed`，原文+译文同行）。
  Future<TaskRunResult> _runSubtitleTranslate(
    QueueTask task,
    CancelToken token, {
    required void Function() notify,
  }) async {
    final input = task.params[TaskParams.subtitlePath] ?? '';
    final output = task.params[TaskParams.outputPath] ?? '';
    final mixedOut = task.params[TaskParams.mixedPath] ?? '';
    final langCode = task.params[TaskParams.targetLang] ?? 'zh';
    final doPolish = task.params[TaskParams.polishMode] == '1';
    if (input.isEmpty || output.isEmpty) {
      return const TaskRunResult(success: false, error: '缺少输入/输出路径');
    }

    final settings = SettingsProvider.instance;
    final config = AiApiConfig(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.aiApiKey,
      model: settings.aiModel,
    );
    if (!config.isReady) {
      return const TaskRunResult(
        success: false,
        error: 'AI 翻译未配置：请在设置页填写 API Key / BaseURL / 模型',
      );
    }
    final target = TranslateLanguage.presets
        .where((l) => l.code == langCode)
        .firstOrNull ?? TranslateLanguage.presets.first;

    try {
      final doc = await SubtitleParser.parseFile(input);
      // 断点续传：失败/取消后重试同任务不重译已成功批次
      final inputMtime = File(input).existsSync()
          ? File(input).lastModifiedSync().millisecondsSinceEpoch
          : null;
      // 进度切分：润色开启时翻译占 0–0.6、润色 0.6–end；关闭时翻译直达 end
      final endAt = mixedOut.isEmpty ? 1.0 : 0.95;
      final translateEnd = doPolish ? 0.6 : endAt;
      var translated = await TranslationService.instance.translateDocument(
        doc,
        config: config,
        target: target,
        // 全局词库 + 字幕目录旁车 .glossary.json（旁车同 source 优先）
        glossary: GlossaryStore.mergedFor(input, settings.glossary),
        checkpointPath: TranslateCheckpoint.pathFor(output),
        checkpointMtimeMs: inputMtime,
        onProgress: (frac) {
          task.progress = frac * translateEnd;
          notify();
        },
        shouldCancel: () => token.isCancelled,
      );
      if (doPolish) {
        translated = await TranslationService.instance.polishDocument(
          translated,
          config: config,
          target: target,
          customRules: settings.polishCustomRules,
          onProgress: (frac) {
            task.progress = 0.6 + frac * (endAt - 0.6);
            notify();
          },
          shouldCancel: () => token.isCancelled,
        );
      }
      // P1 约定：输出格式由源文件格式决定，不修改（同格式写出，UTF-8）
      final format = doc.format == SubtitleFormat.unknown
          ? SubtitleFormat.srt
          : doc.format;
      final outputs = <TaskOutputFile>[
        TaskOutputFile(name: p.basename(output), path: output),
      ];
      await File(output).writeAsString(
        SubtitleWriter.write(translated, format),
        encoding: utf8,
        flush: true,
      );
      if (mixedOut.isNotEmpty) {
        final mixed = TranslationService.mixedDocument(doc, translated);
        await File(mixedOut).writeAsString(
          SubtitleWriter.write(mixed, format),
          encoding: utf8,
          flush: true,
        );
        outputs.add(TaskOutputFile(
          name: p.basename(mixedOut),
          path: mixedOut,
        ));
        task.progress = 1;
        notify();
      }
      return TaskRunResult(success: true, outputs: outputs);
    } on TranslationCancelledException {
      return const TaskRunResult(success: false, cancelled: true);
    } catch (e) {
      return TaskRunResult(success: false, error: '$e');
    }
  }

  /// Whisper 语音转写（外部 whisper CLI 子进程，不占 FFmpeg 会话）。
  /// 输出 = `<输出目录>/<输入主名><格式扩展名>`；skipExisting 时已存在则直接成功。
  Future<TaskRunResult> _runWhisper(
    QueueTask task,
    CancelToken token, {
    void Function(FfmpegProgress progress)? onProgress,
    void Function(String line)? onLog,
  }) async {
    final input = task.params[TaskParams.videoPath] ?? '';
    final outputDir = task.params[TaskParams.outputPath] ?? '';
    final model = task.params[TaskParams.whisperModel] ?? 'small';
    final format = task.params[TaskParams.whisperFormat] ?? 'srt';
    if (input.isEmpty || outputDir.isEmpty) {
      return const TaskRunResult(success: false, error: '缺少输入文件或输出目录');
    }
    final expected = WhisperService.expectedOutputPath(
      inputPath: input,
      outputDir: outputDir,
      outputFormat: format,
      model: model,
    );
    if ((task.params[TaskParams.skipExisting] ?? 'false') == 'true' &&
        File(expected).existsSync()) {
      onLog?.call('输出已存在，跳过转写：$expected');
      return TaskRunResult(
        success: true,
        outputs: [TaskOutputFile(name: p.basename(expected), path: expected)],
      );
    }
    final promptTemplate = task.params[TaskParams.whisperPrompt];
    return WhisperService.instance.transcribe(
      inputPath: input,
      outputDir: outputDir,
      model: model,
      outputFormat: format,
      language: task.params[TaskParams.whisperLanguage],
      useGpu: (task.params[TaskParams.whisperGpu] ?? 'false') == 'true',
      presetChoice:
          int.tryParse(task.params[TaskParams.whisperPreset] ?? '') ?? 1,
      // {episode} 占位符按各输入文件名展开
      initialPrompt: promptTemplate == null || promptTemplate.isEmpty
          ? null
          : WhisperService.expandInitialPrompt(promptTemplate, input),
      customParams: task.params[TaskParams.whisperCustomParams],
      vadFilter: task.params[TaskParams.vadFilter] == '1',
      onProgress: onProgress,
      onLog: onLog,
      cancelToken: token,
    );
  }
}
