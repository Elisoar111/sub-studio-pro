import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';
import '../../models/subtitle.dart';
import 'translation_cache.dart';

/// OpenAI 兼容 API 配置（Key / BaseURL / 模型，设置页配置）。
class AiApiConfig {
  final String baseUrl;
  final String apiKey;
  final String model;

  const AiApiConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  bool get isReady =>
      apiKey.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  /// 归一化 BaseURL：去尾斜杠；仅 host 时补 /v1（如
  /// `https://api.openai.com`），已带路径的（Gemini `v1beta/openai`、
  /// 智谱 `/api/paas/v4` 等）原样保留。
  String get _normalizedBase {
    var u = baseUrl.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    final schemeEnd = u.indexOf('://');
    final pathStart = schemeEnd >= 0 ? u.indexOf('/', schemeEnd + 3) : u.indexOf('/');
    if (pathStart == -1) u = '$u/v1';
    return u;
  }

  String get chatCompletionsUrl => '$_normalizedBase/chat/completions';

  /// 模型列表接口（GET，OpenAI 兼容 /models）。
  String get modelsUrl => '$_normalizedBase/models';
}

/// 常用目标语言预设（显示名 → 传给模型的指令用语 + ISO 码）。
class TranslateLanguage {
  final String code;
  final String name;
  final String prompt;

  const TranslateLanguage(this.code, this.name, this.prompt);

  static const presets = [
    TranslateLanguage('zh', '简体中文', 'Simplified Chinese'),
    TranslateLanguage('zh-TW', '繁體中文', 'Traditional Chinese'),
    TranslateLanguage('en', 'English', 'English'),
    TranslateLanguage('ja', '日本語', 'Japanese'),
    TranslateLanguage('ko', '한국어', 'Korean'),
  ];
}

/// 术语表条目（人名 / 专名锁定）。[translation] 留空 = 本片不译（保留原文）。
class GlossaryTerm {
  final String source;
  final String translation;

  const GlossaryTerm({required this.source, required this.translation});

  Map<String, String> toJson() => {'source': source, 'translation': translation};

  factory GlossaryTerm.fromJson(Map<String, dynamic> j) => GlossaryTerm(
        source: (j['source'] ?? '') as String,
        translation: (j['translation'] ?? '') as String,
      );
}

/// 术语表条数上限（token 成本护栏，UI 同步提示）。
const int kGlossaryMaxTerms = 200;

/// 翻译 system prompt（独立函数便于测试锁定规则）：
/// 目标语言注入 + ASS 标签原样保留 + `\N` 硬换行保留 + 行数一致 +
/// 仅输出 JSON 对象（v2.2.1 起配合 `response_format: json_object`，
/// 契约从数组改为 `{"lines":[...]}`）；[glossary] 非空时追加术语锁定段。
String translateSystemPrompt(
  TranslateLanguage target, {
  List<GlossaryTerm> glossary = const [],
}) {
  var p = 'You are a professional subtitle translator. '
      'Translate each numbered line into ${target.prompt}. '
      'Rules: keep the ASS override tags like {\\i1} exactly as-is; '
      'keep the literal backslash-N line breaks exactly; '
      'do not add or remove lines; do not add quotes or numbering. '
      'Reply with ONLY a JSON object like {"lines":["...","..."]}, '
      'same length and order as the input.';
  if (glossary.isNotEmpty) {
    final lines = [
      for (final t in glossary)
        '${t.source} => ${t.translation.isEmpty ? 'do not translate' : t.translation}',
    ];
    p += ' Glossary (apply exactly): ${lines.join('; ')}.';
  }
  return p;
}

/// 翻译 user payload：`{"lines":[...]}`，[context]（前批尾部原文+已译文对）
/// 非空时附加为 `"context":[["src","dst"],...]`。响应契约不变（纯数组）。
String translateUserPayload(
  List<String> lines, {
  List<List<String>>? context,
}) {
  final m = <String, dynamic>{'lines': lines};
  if (context != null && context.isNotEmpty) m['context'] = context;
  return jsonEncode(m);
}

/// 润色 system prompt（二阶段调用，开关默认关闭）：
/// 只修断句/标点/口语表达，不改语义；ASS 标签与 `\N` 原样保留；
/// 行数一致、仅输出 JSON 对象（与翻译阶段同契约，便于复用解析）。
/// [customRules]（v1.3）为用户自定义附加段，拼接到内置规则之后。
String polishSystemPrompt(TranslateLanguage target, {String customRules = ''}) {
  final base = 'You are a professional subtitle proofreader. '
      'Polish each numbered line, which is already translated into '
      '${target.prompt}. Fix punctuation, segmentation and phrasing only; '
      'do NOT change the meaning. '
      'Rules: keep the ASS override tags like {\\i1} exactly as-is; '
      'keep the literal backslash-N line breaks exactly; '
      'do not add or remove lines; do not add quotes or numbering. '
      'Reply with ONLY a JSON object like {"lines":["...","..."]}, '
      'same length and order as the input.';
  final extra = customRules.trim();
  return extra.isEmpty ? base : '$base Custom rules: $extra。';
}

/// 单批 chat 调用签名（[TranslationService.translateDocument] 的
/// chatOverride 注入缝，测试用）。
typedef ChatFn = Future<String> Function({
  required String system,
  required String user,
});

/// 测试连接结果（设置页「测试连接」按钮）。
class TestConnectionResult {
  final bool ok;
  final int latencyMs;

  /// 成功时模型回复原文（截断展示用）。
  final String reply;

  /// 失败时的错误摘要。
  final String error;

  const TestConnectionResult({
    required this.ok,
    this.latencyMs = 0,
    this.reply = '',
    this.error = '',
  });
}

/// 翻译过程中的实时事件种类（翻译页直播面板）。
enum TranslateEventKind { batchStart, batchDone, thinking, delta, retry }

/// 单个 SSE data 载荷的 token 用量（chat/completions usage 字段）。
class AiUsage {
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  const AiUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });

  AiUsage operator +(AiUsage o) => AiUsage(
        promptTokens: promptTokens + o.promptTokens,
        completionTokens: completionTokens + o.completionTokens,
        totalTokens: totalTokens + o.totalTokens,
      );

  @override
  bool operator ==(Object other) =>
      other is AiUsage &&
      other.promptTokens == promptTokens &&
      other.completionTokens == completionTokens &&
      other.totalTokens == totalTokens;

  @override
  int get hashCode =>
      Object.hash(promptTokens, completionTokens, totalTokens);
}

/// SSE 行流增量解析器（v2.2.1 流式译文上屏）：喂入原始响应行，
/// 产出 reasoning / content 增量回调；空行 = 事件边界（多行 `data:`
/// 拼接为一个载荷），[close] 冲刷流末未遇边界的尾包。
/// 其余 SSE 字段（event:/id:/注释行）与 `[DONE]`、非 JSON 载荷忽略。
class SseStreamParser {
  SseStreamParser({this.onThinking, this.onContent, this.onUsage});

  final void Function(String reasoningDelta)? onThinking;
  final void Function(String contentDelta)? onContent;

  /// 尾包 token 用量（choices 为空 + usage 字段，S3 统计入口）。
  final void Function(AiUsage usage)? onUsage;
  final List<String> _buf = [];

  void feed(String line) {
    if (line.isEmpty) {
      _flush();
      return;
    }
    if (line.startsWith('data:')) {
      _buf.add(line.substring(5).trimLeft());
    }
  }

  void close() => _flush();

  void _flush() {
    if (_buf.isEmpty) return;
    // 直接拼接而非按 SSE 规范插 \n：chat/completions 的 JSON 载荷内
    // 不会出现裸换行（换行均为 \n 转义），代理拆行时直接连接才能还原
    final payload = _buf.join();
    _buf.clear();
    final delta = TranslationService.parseSseDelta(payload);
    if (delta == null) {
      final usage = TranslationService.parseSseUsage(payload);
      if (usage != null) onUsage?.call(usage);
      return;
    }
    if (delta.reasoning.isNotEmpty) onThinking?.call(delta.reasoning);
    if (delta.content.isNotEmpty) onContent?.call(delta.content);
  }
}

/// 单个实时翻译事件。
class TranslateEvent {
  final TranslateEventKind kind;

  /// 阶段标签（'翻译' / '润色'）。
  final String tag;

  /// 0-based 批次索引。
  final int batchIndex;
  final int batchTotal;

  /// batchStart：本批首行预览；thinking：reasoning 增量；retry：错误摘要。
  final String text;

  /// batchDone：前 3 条 [原文, 译文] 预览对；其余事件为空列表。
  final List<List<String>> pairs;

  const TranslateEvent({
    required this.kind,
    required this.tag,
    required this.batchIndex,
    required this.batchTotal,
    this.text = '',
    this.pairs = const [],
  });
}

/// 翻译断点：记录已成功批次的译文，失败 / 取消后重跑同任务时
/// 跳过这些批次（校验 cueCount + 输入 mtime + 目标语言全一致才复用）。
class TranslateCheckpoint {
  final int cueCount;
  final int inputMtimeMs;
  final String lang;
  final List<List<String>> batches;

  const TranslateCheckpoint({
    required this.cueCount,
    required this.inputMtimeMs,
    required this.lang,
    required this.batches,
  });

  /// checkpoint 旁车路径：输出目录下 `.<输出文件名>.progress.json`
  /// （点前缀降低可见度；全部成功后删除）。
  static String pathFor(String outputPath) => p.join(p.dirname(outputPath),
      '.${p.basename(outputPath)}.progress.json');

  bool matches({
    required int cueCount,
    required int inputMtimeMs,
    required String lang,
  }) =>
      this.cueCount == cueCount &&
      this.inputMtimeMs == inputMtimeMs &&
      this.lang == lang;

  Map<String, dynamic> toJson() => {
        'cueCount': cueCount,
        'inputMtimeMs': inputMtimeMs,
        'lang': lang,
        'batches': batches,
      };

  Future<void> save(String path) => File(path).writeAsString(
        jsonEncode(toJson()),
        encoding: utf8,
        flush: true,
      );

  /// 读取 checkpoint；文件不存在 / 内容损坏返回 null（按全新任务处理）。
  static TranslateCheckpoint? load(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync());
      if (j is! Map) return null;
      final rawBatches = j['batches'];
      if (rawBatches is! List) return null;
      final batches = [
        for (final b in rawBatches)
          if (b is List) [for (final e in b) '$e'],
      ];
      if (batches.length != rawBatches.length) return null;
      return TranslateCheckpoint(
        cueCount: (j['cueCount'] ?? -1) as int,
        inputMtimeMs: (j['inputMtimeMs'] ?? -1) as int,
        lang: (j['lang'] ?? '') as String,
        batches: batches,
      );
    } catch (_) {
      return null;
    }
  }
}

/// AI 字幕翻译服务：OpenAI 兼容 chat/completions，按批次翻译 cue 文本。
///
/// 设计要点：
/// - 只翻译文本，时间轴 / 索引 / 样式头一律不动；
/// - ASS 覆盖标签（`{\i1}` 等）与 `\N` 换行在提示词中要求原样保留，
///   返回内容若丢失标签则回退原文（保证不坏轴不坏样式）；
/// - 每批独立重试（默认 2 次），批间检查取消；
/// - 输出命名固定（无模板）：译文 `源主名_<语言码>`、双语内容合并
///   `源主名_mixed`（见 [translatedPath] / [mixedPath] / [mixedDocument]）。
class TranslationService {
  TranslationService._();

  static final TranslationService instance = TranslationService._();

  /// 单批最大 cue 数（兼顾上下文质量与失败重传成本）。
  static const int batchSize = 30;

  /// 单批 HTTP 超时。
  static const _httpTimeout = Duration(seconds: 120);

  /// 失败批次拆分的粒度下限（≤8 条的批解析失败不再切半，
  /// 直接按重试耗尽失败，避免小批/鉴权类错误引发调用爆炸）。
  static const int _splitMinBatchSize = 8;

  /// 重试退避延迟（attempt 从 1 起：2s、4s…）；测试注入口置零加速。
  static Duration retryDelay(int attempt) =>
      retryDelayOverride?.call(attempt) ?? Duration(seconds: 2 * attempt);

  /// 测试注入口：重试延迟覆写。
  @visibleForTesting
  static Duration Function(int attempt)? retryDelayOverride;

  /// 批间上下文携带条数（前批尾部）。
  static const _contextTail = 3;

  // ───────────────────────── 测试连接（设置页） ─────────────────────────

  /// 发送最小 chat 请求验证 AI 配置可用：成功返回延迟与模型回复，
  /// 失败返回错误摘要（不抛异常，供设置页直接展示）。
  Future<TestConnectionResult> testConnection(
    AiApiConfig config, {
    ChatFn? chatOverride,
  }) async {
    final override = testConnectionOverride;
    if (override != null) return override(config);
    if (!config.isReady) {
      return const TestConnectionResult(
          ok: false, error: 'AI 翻译未配置：请先填写 API Key / BaseURL / 模型');
    }
    final sw = Stopwatch()..start();
    try {
      final reply = chatOverride != null
          ? await chatOverride(system: 'You are a connectivity probe.',
              user: 'ping')
          : await _chat(config,
              system: 'You are a connectivity probe.', user: 'ping');
      return TestConnectionResult(
        ok: true,
        latencyMs: sw.elapsedMilliseconds,
        reply: reply.trim(),
      );
    } catch (e) {
      return TestConnectionResult(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        error: '$e',
      );
    }
  }

  /// 测试注入口：设置页「测试连接」按钮（widget 测试替代真实 HTTP）。
  @visibleForTesting
  static Future<TestConnectionResult> Function(AiApiConfig config)?
      testConnectionOverride;

  /// 测试注入口：设置页「获取模型」按钮（widget 测试替代真实 HTTP）。
  @visibleForTesting
  static Future<List<String>> Function(AiApiConfig config)?
      listModelsOverride;

  /// 解析单个 SSE data 载荷（已去掉 `data:` 前缀）：返回该 chunk 的
  /// content / reasoning 增量；`[DONE]`、空 choices（usage 尾包）或
  /// 非 JSON 载荷返回 null（跳过，不视为错误）。
  static ({String reasoning, String content})? parseSseDelta(String payload) {
    if (payload.trim() == '[DONE]') return null;
    final dynamic decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final delta = (choices.first as Map)['delta'];
    if (delta is! Map) return null;
    final content = delta['content'];
    final reasoning = delta['reasoning_content'];
    if (content is! String && reasoning is! String) return null;
    return (
      reasoning: reasoning is String ? reasoning : '',
      content: content is String ? content : '',
    );
  }

  /// SSE 尾包 / 非流式响应的 token 用量（v2.2.1）。
  static AiUsage? parseSseUsage(String payload) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final usage = decoded['usage'];
    if (usage is! Map) return null;
    final prompt = usage['prompt_tokens'];
    final completion = usage['completion_tokens'];
    final total = usage['total_tokens'];
    if (prompt is! int || completion is! int || total is! int) return null;
    return AiUsage(
        promptTokens: prompt, completionTokens: completion, totalTokens: total);
  }

  /// 把扁平译文按批次尺寸切回嵌套结构（checkpoint 落盘用）。
  static List<List<String>> _splitByBatchSizes(
    List<String> flat,
    List<List<SubtitleCue>> batches,
  ) {
    final out = <List<String>>[];
    var i = 0;
    for (final b in batches) {
      if (i >= flat.length) break;
      out.add(flat.sublist(i, i + b.length));
      i += b.length;
    }
    return out;
  }

  /// 翻译整个字幕文档，返回新文档（原 cue 时间轴与索引保持不变）。
  ///
  /// [chatOverride]：测试注入缝（替代真实 HTTP，不发请求）。
  /// [checkpointPath]/[checkpointMtimeMs]：断点续传——已成功批次落盘，
  /// 失败/取消后重跑同任务跳过这些批次；全部成功后删除 checkpoint。
  /// [onEvent]：实时事件流（批次开始/完成、思考增量、译文增量、重试）。
  /// [onUsage]（v2.2.1）：每个请求的尾包 token 用量（累计由调用方处理）。
  /// [retries]/[timeout]（v2.2.1）：单批重试次数与请求超时，默认 2 / 120s。
  Future<SubtitleDocument> translateDocument(
    SubtitleDocument doc, {
    required AiApiConfig config,
    required TranslateLanguage target,
    List<GlossaryTerm> glossary = const [],
    void Function(double progress)? onProgress,
    void Function(TranslateEvent event)? onEvent,
    void Function(AiUsage usage)? onUsage,
    bool Function()? shouldCancel,
    ChatFn? chatOverride,
    String? checkpointPath,
    int? checkpointMtimeMs,
    TranslationCache? cache,
    int? retries,
    Duration? timeout,
  }) async {
    if (!config.isReady) {
      throw StateError('AI 翻译未配置：请在设置页填写 API Key / BaseURL / 模型');
    }
    final cues = doc.cues;
    if (cues.isEmpty) return doc;

    final batches = <List<SubtitleCue>>[];
    for (var i = 0; i < cues.length; i += batchSize) {
      batches.add(cues.sublist(
        i,
        i + batchSize > cues.length ? cues.length : i + batchSize,
      ));
    }

    // 断点续传：校验通过则从已完成的批次之后继续
    var startBatch = 0;
    final translated = <String>[];
    if (checkpointPath != null && checkpointMtimeMs != null) {
      final cp = TranslateCheckpoint.load(checkpointPath);
      final valid = cp != null &&
          cp.batches.isNotEmpty &&
          cp.batches.length <= batches.length &&
          cp.matches(
            cueCount: cues.length,
            inputMtimeMs: checkpointMtimeMs,
            lang: target.code,
          );
      if (valid) {
        startBatch = cp.batches.length;
        for (final b in cp.batches) {
          translated.addAll(b);
        }
        onProgress?.call(startBatch / batches.length);
      }
    }

    // 批间上下文：前批尾部（原文 + 已译文）对，滚动维护；
    // 从 checkpoint 恢复时用已译尾部衔接
    var context = <List<String>>[];
    if (startBatch > 0) {
      final src = [for (final c in batches[startBatch - 1]) c.rawText];
      final dst = translated.sublist(
          translated.length - src.length, translated.length);
      final pairs = [
        for (var i = 0; i < src.length; i++) [src[i], dst[i]],
      ];
      context = pairs.length > _contextTail
          ? pairs.sublist(pairs.length - _contextTail)
          : pairs;
    }
    for (var b = startBatch; b < batches.length; b++) {
      if (shouldCancel?.call() ?? false) {
        throw const TranslationCancelledException();
      }
      final batch = batches[b];
      final lines = [for (final c in batch) c.rawText];
      onEvent?.call(TranslateEvent(
        kind: TranslateEventKind.batchStart,
        tag: '翻译',
        batchIndex: b,
        batchTotal: batches.length,
        text: lines.first,
      ));

      // v2.2.1 翻译缓存：命中行零网络回填，仅未命中行送模型
      final cached = cache == null
          ? null
          : [for (final l in lines) await cache.get(target.code, l)];
      final sendIdx = cached == null
          ? [for (var i = 0; i < lines.length; i++) i]
          : [
              for (var i = 0; i < lines.length; i++)
                if (cached[i] == null) i,
            ];
      final results = List<String>.filled(lines.length, '');
      if (cached != null) {
        for (var i = 0; i < lines.length; i++) {
          if (cached[i] != null) results[i] = cached[i]!;
        }
      }
      final sendLines = [for (final i in sendIdx) lines[i]];
      if (sendLines.isNotEmpty) {
        final fresh = await _translateBatch(sendLines, config, target,
          glossary: glossary,
          context: context.isEmpty ? null : context,
          chatOverride: chatOverride,
          retries: retries,
          timeout: timeout,
          onUsage: onUsage,
          onContent: onEvent == null
              ? null
              : (delta) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.delta,
                    tag: '翻译',
                    batchIndex: b,
                    batchTotal: batches.length,
                    text: delta,
                  )),
          onThinking: onEvent == null
              ? null
              : (delta) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.thinking,
                    tag: '翻译',
                    batchIndex: b,
                    batchTotal: batches.length,
                    text: delta,
                  )),
          onRetry: onEvent == null
              ? null
              : (attempt, error) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.retry,
                    tag: '翻译',
                    batchIndex: b,
                    batchTotal: batches.length,
                    text: '第 $attempt 次重试：$error',
                  )),
          onSplit: onEvent == null
              ? null
              : (half) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.retry,
                    tag: '翻译',
                    batchIndex: b,
                    batchTotal: batches.length,
                    text: '批次解析失败，拆分为 2×$half 条重试',
                  )));
        for (var k = 0; k < sendIdx.length; k++) {
          results[sendIdx[k]] = fresh[k];
        }
      }
      final finals = [
        for (var i = 0; i < batch.length; i++)
          results[i].trim().isEmpty ? batch[i].rawText : results[i].trim(),
      ];
      translated.addAll(finals);
      // 新译文写回缓存（命中行跳过），随 checkpoint 同步落盘
      if (cache != null) {
        for (final i in sendIdx) {
          await cache.put(target.code, lines[i], finals[i]);
        }
      }
      if (checkpointPath != null) {
        await TranslateCheckpoint(
          cueCount: cues.length,
          inputMtimeMs: checkpointMtimeMs ?? 0,
          lang: target.code,
          batches: _splitByBatchSizes(translated, batches),
        ).save(checkpointPath);
      }
      await cache?.flush();
      onEvent?.call(TranslateEvent(
        kind: TranslateEventKind.batchDone,
        tag: '翻译',
        batchIndex: b,
        batchTotal: batches.length,
        pairs: [
          for (var i = 0; i < finals.length && i < 3; i++)
            [lines[i], finals[i]],
        ],
      ));
      // 滚动更新上下文（尾部最多 3 条）
      final pairs = [
        for (var i = 0; i < lines.length; i++) [lines[i], finals[i]],
      ];
      context = pairs.length > _contextTail
          ? pairs.sublist(pairs.length - _contextTail)
          : pairs;
      onProgress?.call((b + 1) / batches.length);
    }
    if (checkpointPath != null) {
      final f = File(checkpointPath);
      if (f.existsSync()) f.deleteSync();
    }

    return SubtitleDocument(
      format: doc.format,
      title: doc.title,
      style: doc.style,
      cues: [
        for (var i = 0; i < cues.length; i++)
          SubtitleCue(
            index: cues[i].index,
            start: cues[i].start,
            end: cues[i].end,
            rawText: translated[i],
          ),
      ],
    );
  }

  /// 润色已翻译文档（二阶段第二跳，仅 UI 开启润色模式时调用）：
  /// 逐批送润色 prompt，只优化标点/断句/口语表达；时间轴、索引、
  /// 行数不变，空结果回退原文。不支持 checkpoint（重试代价 = 重译）。
  Future<SubtitleDocument> polishDocument(
    SubtitleDocument doc, {
    required AiApiConfig config,
    required TranslateLanguage target,
    String customRules = '',
    void Function(double progress)? onProgress,
    void Function(TranslateEvent event)? onEvent,
    void Function(AiUsage usage)? onUsage,
    bool Function()? shouldCancel,
    ChatFn? chatOverride,
    int? retries,
    Duration? timeout,
  }) async {
    if (!config.isReady) {
      throw StateError('AI 翻译未配置：请在设置页填写 API Key / BaseURL / 模型');
    }
    final cues = doc.cues;
    if (cues.isEmpty) return doc;

    final system = polishSystemPrompt(target, customRules: customRules);
    final total = (cues.length / batchSize).ceil();
    final polished = <String>[];
    for (var i = 0; i < cues.length; i += batchSize) {
      if (shouldCancel?.call() ?? false) {
        throw const TranslationCancelledException();
      }
      final batch = cues.sublist(
        i,
        i + batchSize > cues.length ? cues.length : i + batchSize,
      );
      final lines = [for (final c in batch) c.rawText];
      final b = i ~/ batchSize;
      onEvent?.call(TranslateEvent(
        kind: TranslateEventKind.batchStart,
        tag: '润色',
        batchIndex: b,
        batchTotal: total,
        text: lines.first,
      ));
      final results = await _chatBatchResilient(lines, config,
          system: system,
          userFor: (sub) => translateUserPayload(sub),
          tag: '润色',
          chatOverride: chatOverride,
          retries: retries,
          timeout: timeout,
          onUsage: onUsage,
          onContent: onEvent == null
              ? null
              : (delta) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.delta,
                    tag: '润色',
                    batchIndex: b,
                    batchTotal: total,
                    text: delta,
                  )),
          onThinking: onEvent == null
              ? null
              : (delta) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.thinking,
                    tag: '润色',
                    batchIndex: b,
                    batchTotal: total,
                    text: delta,
                  )),
          onRetry: onEvent == null
              ? null
              : (attempt, error) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.retry,
                    tag: '润色',
                    batchIndex: b,
                    batchTotal: total,
                    text: '第 $attempt 次重试：$error',
                  )),
          onSplit: onEvent == null
              ? null
              : (half) => onEvent(TranslateEvent(
                    kind: TranslateEventKind.retry,
                    tag: '润色',
                    batchIndex: b,
                    batchTotal: total,
                    text: '批次解析失败，拆分为 2×$half 条重试',
                  )));
      polished.addAll([
        for (var k = 0; k < batch.length; k++)
          results[k].trim().isEmpty ? batch[k].rawText : results[k].trim(),
      ]);
      onEvent?.call(TranslateEvent(
        kind: TranslateEventKind.batchDone,
        tag: '润色',
        batchIndex: b,
        batchTotal: total,
        pairs: [
          for (var k = 0; k < batch.length && k < 3; k++)
            [lines[k], polished[i + k]],
        ],
      ));
      onProgress?.call(polished.length / cues.length);
    }

    return SubtitleDocument(
      format: doc.format,
      title: doc.title,
      style: doc.style,
      cues: [
        for (var i = 0; i < cues.length; i++)
          SubtitleCue(
            index: cues[i].index,
            start: cues[i].start,
            end: cues[i].end,
            rawText: polished[i],
          ),
      ],
    );
  }

  /// 双语拼接：ASS/SSA 用 `\N` 换行记号，其余格式用真实换行符。
  /// （SRT/VTT/MicroDVD 播放器不解释 `\N`，写出后会把反斜杠显示给用户）
  static String bilingualJoin(
    SubtitleFormat format,
    String original,
    String translated,
  ) {
    final t = translated.trim().isEmpty ? original : translated.trim();
    final sep = format.isAssFamily ? r'\N' : '\n';
    return '$original$sep$t';
  }

  // ───────────────────── 输出命名（无模板，与 Whisper 规则一致） ─────────────────────

  /// 译文输出路径：`<outputDir>/<源主名>_<语言码><源扩展名>`（如 demo_en.srt）。
  /// 只翻译内容、时间轴不动；扩展名跟随源文件（不转换格式），
  /// 无扩展名时兜底 .srt。
  static String translatedPath({
    required String inputPath,
    required String outputDir,
    required String langCode,
  }) =>
      p.join(outputDir,
          '${p.basenameWithoutExtension(inputPath)}_$langCode${_extOrSrt(inputPath)}');

  /// 双语合并输出路径：`<outputDir>/<源主名>_mixed<源扩展名>`。
  static String mixedPath({
    required String inputPath,
    required String outputDir,
  }) =>
      p.join(outputDir,
          '${p.basenameWithoutExtension(inputPath)}_mixed${_extOrSrt(inputPath)}');

  static String _extOrSrt(String inputPath) {
    final ext = p.extension(inputPath);
    return ext.isEmpty ? '.srt' : ext;
  }

  /// 重名去重：目标已存在（磁盘文件 / 同批 [used] 集合）时依次追加
  /// `_1`、`_2`…。返回最终路径并登记进 [used]（小写键），
  /// 防止同批多任务输出互相覆盖。
  static String dedupePath(String path, Set<String> used) {
    var candidate = path;
    var i = 1;
    while (used.contains(candidate.toLowerCase()) ||
        File(candidate).existsSync()) {
      candidate = p.join(p.dirname(path),
          '${p.basenameWithoutExtension(path)}_$i${p.extension(path)}');
      i++;
    }
    used.add(candidate.toLowerCase());
    return candidate;
  }

  /// 双语合并文档（_mixed 产物）：每条 cue 的文本 = 原文 + 换行 + 译文
  /// （ASS 系用 `\N`，其余真实换行），时间轴与索引取原文档不变。
  /// 译文缺失或与原文相同时保留原文，避免同一行重复两遍。
  static SubtitleDocument mixedDocument(
    SubtitleDocument source,
    SubtitleDocument translated,
  ) {
    final src = source.cues;
    final tr = translated.cues;
    return SubtitleDocument(
      format: source.format,
      title: source.title,
      style: source.style,
      cues: [
        for (var i = 0; i < src.length; i++)
          SubtitleCue(
            index: src[i].index,
            start: src[i].start,
            end: src[i].end,
            rawText: _mixedText(
              source.format,
              src[i].rawText,
              i < tr.length ? tr[i].rawText : '',
            ),
          ),
      ],
    );
  }

  static String _mixedText(
    SubtitleFormat format,
    String original,
    String translated,
  ) {
    final t = translated.trim();
    if (t.isEmpty || t == original.trim()) return original;
    return bilingualJoin(format, original, t);
  }

  /// 翻译一批文本行，返回与输入等长的译文列表（带重试 + 失败拆半）。
  Future<List<String>> _translateBatch(
    List<String> lines,
    AiApiConfig config,
    TranslateLanguage target, {
    List<GlossaryTerm> glossary = const [],
    List<List<String>>? context,
    ChatFn? chatOverride,
    void Function(String reasoningDelta)? onThinking,
    void Function(String contentDelta)? onContent,
    void Function(int attempt, String error)? onRetry,
    void Function(int halfSize)? onSplit,
    void Function(AiUsage usage)? onUsage,
    int? retries,
    Duration? timeout,
  }) =>
      _chatBatchResilient(
        lines,
        config,
        system: translateSystemPrompt(target, glossary: glossary),
        userFor: (sub) => translateUserPayload(sub, context: context),
        tag: '翻译',
        chatOverride: chatOverride,
        onThinking: onThinking,
        onContent: onContent,
        onRetry: onRetry,
        onSplit: onSplit,
        onUsage: onUsage,
        retries: retries,
        timeout: timeout,
      );

  /// 带重试的单批 chat 调用：请求 + 解析 JSON（翻译/润色共用）。
  /// [retries] 额外重试次数（null = 默认 2）；[timeout] 单次请求超时
  /// （null = 默认 120s，v2.2.1 设置页可调）。
  /// 重试耗尽抛 [TranslationBatchException]（携带是否解析失败标记，
  /// 供失败批次拆分重试判定）。
  Future<List<String>> _chatBatch(
    List<String> lines,
    AiApiConfig config, {
    required String system,
    required String user,
    required String tag,
    ChatFn? chatOverride,
    void Function(String reasoningDelta)? onThinking,
    void Function(String contentDelta)? onContent,
    void Function(AiUsage usage)? onUsage,
    void Function(int attempt, String error)? onRetry,
    int? retries,
    Duration? timeout,
  }) async {
    final maxRetries = retries ?? 2;
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(retryDelay(attempt));
      }
      try {
        final content = chatOverride != null
            ? await chatOverride(system: system, user: user)
            : await _chat(config,
                system: system, user: user,
                onThinking: onThinking, onContent: onContent,
                onUsage: onUsage, timeout: timeout);
        return parseModelOutput(content, lines.length);
      } catch (e) {
        lastError = e;
        onRetry?.call(attempt, '$e');
        Logger.instance.log('$tag批次失败（第 $attempt 次重试）：$e', tag: 'AI');
      }
    }
    throw TranslationBatchException(
        tag, lastError ?? 'unknown', lastError is FormatException);
  }

  /// 失败批次拆分重试（v2.2.1）：长批次（> [_splitMinBatchSize] 条）因
  /// 解析失败（输出非 JSON / 长输出截断）重试耗尽时自动切半递归
  /// （30→15→8），拼接结果保持原顺序；HTTP 类错误与小批不拆分。
  /// 翻译 / 润色共用。[userFor] 按行重建 user payload（半批行集不同）。
  Future<List<String>> _chatBatchResilient(
    List<String> lines,
    AiApiConfig config, {
    required String system,
    required String Function(List<String> lines) userFor,
    required String tag,
    ChatFn? chatOverride,
    void Function(String reasoningDelta)? onThinking,
    void Function(String contentDelta)? onContent,
    void Function(AiUsage usage)? onUsage,
    void Function(int attempt, String error)? onRetry,
    void Function(int halfSize)? onSplit,
    int? retries,
    Duration? timeout,
  }) async {
    try {
      return await _chatBatch(lines, config,
          system: system,
          user: userFor(lines),
          tag: tag,
          chatOverride: chatOverride,
          onThinking: onThinking,
          onContent: onContent,
          onUsage: onUsage,
          onRetry: onRetry,
          retries: retries,
          timeout: timeout);
    } on TranslationBatchException catch (e) {
      if (!e.parseFailure || lines.length <= _splitMinBatchSize) rethrow;
      final mid = (lines.length / 2).ceil();
      onSplit?.call(mid);
      Future<List<String>> half(List<String> sub) => _chatBatchResilient(sub,
          config,
          system: system,
          userFor: userFor,
          tag: tag,
          chatOverride: chatOverride,
          onThinking: onThinking,
          onContent: onContent,
          onUsage: onUsage,
          onRetry: onRetry,
          onSplit: onSplit,
          retries: retries,
          timeout: timeout);
      final left = await half(lines.sublist(0, mid));
      final right = await half(lines.sublist(mid));
      return [...left, ...right];
    }
  }

  /// chat/completions 请求体（v2.2.1 JSON 输出模式）：
  /// `response_format: json_object` 强制模型输出合法 JSON 对象，
  /// 减少「输出非 JSON → 整批重试（重复计费）」的失败率。
  static Map<String, dynamic> chatRequestBody({
    required String model,
    required String system,
    required String user,
    bool jsonMode = true,
  }) =>
      {
        'model': model,
        'temperature': 0.3,
        // 流式请求：reasoning 模型的思考增量（delta.reasoning_content）
        // 可实时回调 [onThinking]；不支持流式的服务商仍返回完整 JSON，
        // _chat 内按 Content-Type 分流兼容。
        'stream': true,
        if (jsonMode) 'response_format': {'type': 'json_object'},
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      };

  /// 服务商不支持 `response_format` 参数时的 400 判定（重发不带该参数）。
  static bool shouldRetryWithoutJsonMode(int statusCode, String error) =>
      statusCode == 400 && error.toLowerCase().contains('response_format');

  /// 解析模型输出为字符串数组（v2.2.1 双契约兼容）：
  /// 优先 `{"lines":[...]}` 对象（json_object 模式契约），回退旧纯数组；
  /// 尽力兼容被 ```json 包裹 / 混有解释文字的情况；长度不符截断/补齐，
  /// 缺失项为空串（调用方处理空串回退原文）。
  static List<String> parseModelOutput(String content, int expected) {
    var text = content.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    final candidates = <String>[];
    final objStart = text.indexOf('{');
    final objEnd = text.lastIndexOf('}');
    if (objStart >= 0 && objEnd > objStart) {
      candidates.add(text.substring(objStart, objEnd + 1));
    }
    final arrStart = text.indexOf('[');
    final arrEnd = text.lastIndexOf(']');
    if (arrStart >= 0 && arrEnd > arrStart) {
      candidates.add(text.substring(arrStart, arrEnd + 1));
    }
    candidates.add(text);
    for (final c in candidates) {
      final dynamic decoded;
      try {
        decoded = jsonDecode(c);
      } catch (_) {
        continue;
      }
      List? list;
      if (decoded is Map) {
        final lines = decoded['lines'];
        if (lines is List) list = lines;
      } else if (decoded is List) {
        list = decoded;
      }
      if (list == null) continue;
      final out = [for (final e in list) '$e'];
      if (out.length == expected) return out;
      return List.generate(expected, (i) => i < out.length ? out[i] : '');
    }
    throw const FormatException('模型输出不是 {"lines":[...]} 对象或 JSON 数组');
  }

  /// 流式译文转写清洗（v2.2.1 直播面板）：把累积的原始 content 增量
  /// （模型逐 token 输出的 JSON 文本）尽力还原为人读译文——提取字符串
  /// 值、丢弃 JSON 键与脚手架、还原转义；尾部未闭合的字符串按已到达
  /// 部分逐字显示。非 JSON 文本原样返回（兼容不走 JSON 契约的输出）。
  static String parseLiveTranscript(String raw) {
    var text = raw.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*)').firstMatch(text);
    if (fence != null) text = (fence.group(1) ?? '').trim();
    final parts = <String>[];
    final buf = StringBuffer();
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (!inString) {
        if (ch == '"') {
          inString = true;
          escaped = false;
        }
        continue;
      }
      if (escaped) {
        escaped = false;
        switch (ch) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case 'r':
            buf.write('\r');
          case 'u':
            if (i + 4 < text.length) {
              final code =
                  int.tryParse(text.substring(i + 1, i + 5), radix: 16);
              if (code != null) {
                buf.writeCharCode(code);
                i += 4;
              } else {
                buf.write(ch);
              }
            } else {
              buf.write(ch);
            }
          default:
            buf.write(ch);
        }
        continue;
      }
      if (ch == r'\') {
        escaped = true;
      } else if (ch == '"') {
        inString = false;
        // 向前看：字符串后紧跟 ':' 的是 JSON 键（如 "lines"），丢弃
        var j = i + 1;
        while (j < text.length && ' \n\r\t'.contains(text[j])) {
          j++;
        }
        final isKey = j < text.length && text[j] == ':';
        if (!isKey) parts.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    if (inString && buf.isNotEmpty) parts.add(buf.toString());
    return parts.isEmpty ? text : parts.join('\n');
  }

  Future<String> _chat(
    AiApiConfig config, {
    required String system,
    required String user,
    void Function(String reasoningDelta)? onThinking,
    void Function(String contentDelta)? onContent,
    void Function(AiUsage usage)? onUsage,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? _httpTimeout;
    final uri = Uri.parse(config.chatCompletionsUrl);
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..badCertificateCallback = (_, __, ___) => false;
      var jsonMode = true;
      while (true) {
        final req = await client
            .openUrl('POST', uri)
            .timeout(const Duration(seconds: 30));
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
        req.add(utf8.encode(jsonEncode(chatRequestBody(
          model: config.model,
          system: system,
          user: user,
          jsonMode: jsonMode,
        ))));
        final res = await req.close().timeout(effectiveTimeout);
        final contentType =
            res.headers.value(HttpHeaders.contentTypeHeader) ?? '';
        if (contentType.contains('text/event-stream')) {
          return await _readSse(res,
              onThinking: onThinking, onContent: onContent,
              onUsage: onUsage, timeout: effectiveTimeout);
        }
        // 非 SSE（服务商忽略 stream 参数）：整包 JSON，兼容读取
        // message.reasoning_content（DeepSeek R1 系非流式也返回该字段）。
        // 读 body 同样要超时：连接半开/服务端停滞时 join() 会永久挂起，
        // 卡死串行队列且取消（批间检查）无法生效
        final body = await res
            .transform(utf8.decoder)
            .join()
            .timeout(effectiveTimeout);
        if (res.statusCode != 200) {
          // 部分中转/兼容端点不支持 response_format：去掉该参数重发一次
          if (jsonMode && shouldRetryWithoutJsonMode(res.statusCode, body)) {
            jsonMode = false;
            continue;
          }
          throw HttpException('HTTP ${res.statusCode}: ${_brief(body)}');
        }
        final bodyUsage = parseSseUsage(body);
        if (bodyUsage != null) onUsage?.call(bodyUsage);
        final decoded = jsonDecode(body);
        final choices = (decoded as Map)['choices'];
        if (choices is List && choices.isNotEmpty) {
          final msg = (choices.first as Map)['message'];
          final content = msg is Map ? msg['content'] : null;
          final reasoning = msg is Map ? msg['reasoning_content'] : null;
          if (reasoning is String && reasoning.isNotEmpty) {
            onThinking?.call(reasoning);
          }
          if (content is String && content.trim().isNotEmpty) return content;
        }
        throw const FormatException('响应中无译文内容');
      }
    } finally {
      client?.close();
    }
  }

  /// 读取 SSE 流式响应：逐行喂入 [SseStreamParser]，累积 content 返回；
  /// reasoning / content（v2.2.1 流式译文）增量与尾包 usage 实时回调。
  /// 行级超时防服务端停滞挂起。
  Future<String> _readSse(
    HttpClientResponse res, {
    void Function(String reasoningDelta)? onThinking,
    void Function(String contentDelta)? onContent,
    void Function(AiUsage usage)? onUsage,
    Duration? timeout,
  }) async {
    final content = StringBuffer();
    final parser = SseStreamParser(
      onThinking: onThinking,
      onUsage: onUsage,
      onContent: (delta) {
        content.write(delta);
        onContent?.call(delta);
      },
    );

    final lines = res
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(timeout ?? _httpTimeout);
    await for (final line in lines) {
      parser.feed(line);
    }
    parser.close();
    final text = content.toString();
    if (text.trim().isEmpty) {
      throw const FormatException('流式响应中无译文内容');
    }
    return text;
  }

  static String _brief(String s) =>
      s.length > 300 ? s.substring(0, 300) : s;

  // ───────────────────────── 模型列表（设置页） ─────────────────────────

  /// 解析 OpenAI 兼容 /models 响应体：提取 `data[].id` 去重并排序。
  static List<String> parseModelsJson(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw const FormatException('响应不是 JSON 对象');
    final data = decoded['data'];
    if (data is! List) return const [];
    final ids = <String>{};
    for (final e in data) {
      if (e is Map && e['id'] is String) ids.add(e['id'] as String);
    }
    return ids.toList()..sort();
  }

  /// 按当前配置从服务商拉取可用模型列表（GET /models）。
  Future<List<String>> listModels(AiApiConfig config) async {
    final override = listModelsOverride;
    if (override != null) return override(config);
    if (config.apiKey.trim().isEmpty || config.baseUrl.trim().isEmpty) {
      throw StateError('请先填写 API Key 与 BaseURL');
    }
    final uri = Uri.parse(config.modelsUrl);
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..badCertificateCallback = (_, __, ___) => false;
      final req = await client
          .openUrl('GET', uri)
          .timeout(const Duration(seconds: 30));
      req.headers
          .set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
      final res = await req.close().timeout(_httpTimeout);
      final body =
          await res.transform(utf8.decoder).join().timeout(_httpTimeout);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}: ${_brief(body)}');
      }
      return parseModelsJson(body);
    } finally {
      client?.close();
    }
  }
}

/// 用户取消翻译。
class TranslationCancelledException implements Exception {
  const TranslationCancelledException();
  @override
  String toString() => '翻译已取消';
}

/// 批次重试耗尽（继承 StateError 保持既有错误语义/文案）。
/// [parseFailure] = 根因是模型输出解析失败（FormatException），
/// 是失败批次拆分重试（30→15→8）的触发条件。
class TranslationBatchException extends StateError {
  final Object cause;
  final bool parseFailure;

  TranslationBatchException(String tag, this.cause, this.parseFailure)
      : super('AI $tag失败：$cause');
}
