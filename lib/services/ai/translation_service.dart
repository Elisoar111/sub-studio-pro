import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/utils/logger.dart';
import '../../models/subtitle.dart';

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
/// 仅输出 JSON 数组；[glossary] 非空时追加术语锁定段。
String translateSystemPrompt(
  TranslateLanguage target, {
  List<GlossaryTerm> glossary = const [],
}) {
  var p = 'You are a professional subtitle translator. '
      'Translate each numbered line into ${target.prompt}. '
      'Rules: keep the ASS override tags like {\\i1} exactly as-is; '
      'keep the literal backslash-N line breaks exactly; '
      'do not add or remove lines; do not add quotes or numbering. '
      'Reply with ONLY a JSON array of strings, same length and order '
      'as the input.';
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
/// 行数一致、仅输出 JSON 数组（与翻译阶段同契约，便于复用解析）。
String polishSystemPrompt(TranslateLanguage target) =>
    'You are a professional subtitle proofreader. '
    'Polish each numbered line, which is already translated into '
    '${target.prompt}. Fix punctuation, segmentation and phrasing only; '
    'do NOT change the meaning. '
    'Rules: keep the ASS override tags like {\\i1} exactly as-is; '
    'keep the literal backslash-N line breaks exactly; '
    'do not add or remove lines; do not add quotes or numbering. '
    'Reply with ONLY a JSON array of strings, same length and order '
    'as the input.';

/// 单批 chat 调用签名（[TranslationService.translateDocument] 的
/// chatOverride 注入缝，测试用）。
typedef ChatFn = Future<String> Function({
  required String system,
  required String user,
});

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

  /// 批间上下文携带条数（前批尾部）。
  static const _contextTail = 3;

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
  Future<SubtitleDocument> translateDocument(
    SubtitleDocument doc, {
    required AiApiConfig config,
    required TranslateLanguage target,
    List<GlossaryTerm> glossary = const [],
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
    ChatFn? chatOverride,
    String? checkpointPath,
    int? checkpointMtimeMs,
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
      final results = await _translateBatch(lines, config, target,
          glossary: glossary,
          context: context.isEmpty ? null : context,
          chatOverride: chatOverride);
      final finals = [
        for (var i = 0; i < batch.length; i++)
          results[i].trim().isEmpty ? batch[i].rawText : results[i].trim(),
      ];
      translated.addAll(finals);
      if (checkpointPath != null) {
        await TranslateCheckpoint(
          cueCount: cues.length,
          inputMtimeMs: checkpointMtimeMs ?? 0,
          lang: target.code,
          batches: _splitByBatchSizes(translated, batches),
        ).save(checkpointPath);
      }
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
    void Function(double progress)? onProgress,
    bool Function()? shouldCancel,
    ChatFn? chatOverride,
  }) async {
    if (!config.isReady) {
      throw StateError('AI 翻译未配置：请在设置页填写 API Key / BaseURL / 模型');
    }
    final cues = doc.cues;
    if (cues.isEmpty) return doc;

    final system = polishSystemPrompt(target);
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
      final results = await _chatBatch(lines, config,
          system: system,
          user: translateUserPayload(lines),
          tag: '润色',
          chatOverride: chatOverride);
      polished.addAll([
        for (var k = 0; k < batch.length; k++)
          results[k].trim().isEmpty ? batch[k].rawText : results[k].trim(),
      ]);
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

  /// 翻译一批文本行，返回与输入等长的译文列表（带重试）。
  Future<List<String>> _translateBatch(
    List<String> lines,
    AiApiConfig config,
    TranslateLanguage target, {
    List<GlossaryTerm> glossary = const [],
    List<List<String>>? context,
    ChatFn? chatOverride,
  }) =>
      _chatBatch(
        lines,
        config,
        system: translateSystemPrompt(target, glossary: glossary),
        user: translateUserPayload(lines, context: context),
        tag: '翻译',
        chatOverride: chatOverride,
      );

  /// 带重试的单批 chat 调用：请求 + 解析 JSON 数组（翻译/润色共用）。
  Future<List<String>> _chatBatch(
    List<String> lines,
    AiApiConfig config, {
    required String system,
    required String user,
    required String tag,
    ChatFn? chatOverride,
  }) async {
    const retries = 2;
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(seconds: 2 * attempt));
      }
      try {
        final content = chatOverride != null
            ? await chatOverride(system: system, user: user)
            : await _chat(config, system: system, user: user);
        return _parseArray(content, lines.length);
      } catch (e) {
        lastError = e;
        Logger.instance.log('$tag批次失败（第 $attempt 次重试）：$e', tag: 'AI');
      }
    }
    throw StateError('AI $tag失败：$lastError');
  }

  /// 解析模型输出为字符串数组；尽力兼容被 ```json 包裹 / 多余文本的情况。
  List<String> _parseArray(String content, int expected) {
    var text = content.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fence != null) text = fence.group(1)!.trim();
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start >= 0 && end > start) text = text.substring(start, end + 1);
    final dynamic decoded = jsonDecode(text);
    if (decoded is List) {
      final list = decoded.map((e) => '$e').toList();
      if (list.length == expected) return list;
      // 长度不符：截断/补齐，缺失项回退原文（调用方处理空串）
      return List.generate(expected, (i) => i < list.length ? list[i] : '');
    }
    throw const FormatException('模型输出不是 JSON 数组');
  }

  Future<String> _chat(
    AiApiConfig config, {
    required String system,
    required String user,
  }) async {
    final uri = Uri.parse(config.chatCompletionsUrl);
    HttpClient? client;
    try {
      client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 30)
        ..badCertificateCallback = (_, __, ___) => false;
      final req = await client
          .openUrl('POST', uri)
          .timeout(const Duration(seconds: 30));
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}');
      req.add(utf8.encode(jsonEncode({
        'model': config.model,
        'temperature': 0.3,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
      })));
      final res = await req.close().timeout(_httpTimeout);
      // 读 body 同样要超时：连接半开/服务端停滞时 join() 会永久挂起，
      // 卡死串行队列且取消（批间检查）无法生效
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(_httpTimeout);
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}: ${_brief(body)}');
      }
      final decoded = jsonDecode(body);
      final choices = (decoded as Map)['choices'];
      if (choices is List && choices.isNotEmpty) {
        final msg = (choices.first as Map)['message'];
        final content = msg is Map ? msg['content'] : null;
        if (content is String && content.trim().isNotEmpty) return content;
      }
      throw const FormatException('响应中无译文内容');
    } finally {
      client?.close();
    }
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
