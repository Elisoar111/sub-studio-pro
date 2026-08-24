import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../providers/app_providers.dart';
import '../services/ai/glossary_store.dart';
import '../services/ai/translation_service.dart'
    show
        TranslateLanguage,
        GlossaryTerm,
        TranslationService,
        kGlossaryMaxTerms;
import '../services/file_service.dart';
import '../services/queue_service.dart';
import '../widgets/common.dart';
import '../widgets/file_drop_zone.dart';
import '../widgets/output_settings_card.dart';
import 'settings_screen.dart';
import 'task_queue_screen.dart';

/// AI 字幕翻译页：OpenAI 兼容 API 批量翻译，只翻译文本、时间轴不动。
/// - 输出目录默认与各源字幕同目录，可自定义统一目录
/// - 输出命名固定（无模板）：译文 `源主名_<语言码>.<扩展名>`
///   （如 demo_en.srt，重名自动 _1/_2…）
/// - 可选同时输出双语内容合并文件 `源主名_mixed.<扩展名>`
///   （每条字幕：原文 + 换行 + 译文）
/// - 队列中以"字幕翻译"任务执行，可取消 / 失败重试
class TranslateScreen extends StatefulWidget {
  const TranslateScreen({super.key});

  @override
  State<TranslateScreen> createState() => _TranslateScreenState();
}

class _TranslateScreenState extends State<TranslateScreen> {
  final List<String> _files = [];
  TranslateLanguage _target = TranslateLanguage.presets.first;

  /// 同时输出双语合并字幕（原文 + 译文内容合并，_mixed）
  bool _mergeMixed = false;

  /// 译文润色模式（翻译后二阶段调用，默认关）
  bool _polish = false;

  /// 自定义输出目录（null = 与各源文件同目录）
  String? _outputDir;

  @override
  void initState() {
    super.initState();
    // 直播面板数据源：队列通知驱动重绘（思考流已在 runner 侧 120ms 节流）
    QueueService.instance.addListener(_onQueueChanged);
  }

  @override
  void dispose() {
    QueueService.instance.removeListener(_onQueueChanged);
    super.dispose();
  }

  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  /// 直播面板展示对象（像 Whisper 一样可回看）：进行中任务全部展示 +
  /// 最近 2 条已完成的（不设过期时间，结束后随时回本页查看）。
  List<QueueTask> get _liveTasks {
    final translate = QueueService.instance.tasks
        .where((t) => t.type == TaskType.subtitleTranslate)
        .toList();
    final active = translate
        .where((t) =>
            t.status == TaskStatus.pending || t.status == TaskStatus.running)
        .toList();
    final finishedAll = translate
        .where((t) => t.status.isFinished)
        .toList();
    final keep = finishedAll.length > 2 ? finishedAll.length - 2 : 0;
    final finished = finishedAll.sublist(keep);
    return [...active, ...finished.reversed];
  }

  Future<void> _pickFiles() async {
    try {
      final picked = await FileService.instance.pickSubtitles(multi: true);
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final path = f.path;
          if (path != null && !_files.contains(path)) _files.add(path);
        }
      });
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  /// 拖拽放入文件：按字幕扩展名过滤、去重后入列。
  void _handleDroppedFiles(List<String> paths) {
    final exts =
        AppConstants.subtitleExtensions.map((e) => e.toLowerCase()).toSet();
    final added = <String>[];
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      final extNoDot = ext.isEmpty ? '' : ext.substring(1);
      if (!exts.contains(extNoDot)) continue;
      if (_files.contains(path)) continue;
      added.add(path);
    }
    if (added.isEmpty) return;
    setState(() => _files.addAll(added));
  }

  Future<void> _start() async {
    if (_files.isEmpty) {
      showErrorSnack(context, '请先选择字幕文件');
      return;
    }
    final settings = SettingsProvider.instance;
    if (!settings.aiReady) {
      showErrorSnack(context, 'AI 翻译未配置：请先在设置页填写 API 配置');
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      );
      return;
    }
    final q = QueueService.instance;
    final used = <String>{};
    for (final f in _files) {
      final dir = _outputDir ?? p.dirname(f);
      final translated = TranslationService.dedupePath(
        TranslationService.translatedPath(
          inputPath: f,
          outputDir: dir,
          langCode: _target.code,
        ),
        used,
      );
      final mixed = _mergeMixed
          ? TranslationService.dedupePath(
              TranslationService.mixedPath(inputPath: f, outputDir: dir),
              used,
            )
          : null;
      q.addTask(
        type: TaskType.subtitleTranslate,
        title: '翻译 ${p.basename(f)} → ${_target.name}'
            '${mixed == null ? '' : '（含 _mixed）'}'
            '${_polish ? '（润色）' : ''}',
        params: {
          TaskParams.subtitlePath: f,
          TaskParams.outputPath: translated,
          TaskParams.targetLang: _target.code,
          if (mixed != null) TaskParams.mixedPath: mixed,
          if (_polish) TaskParams.polishMode: '1',
        },
      );
    }
    q.start();
    if (!mounted) return;
    // v2.2：留在翻译页看实时进度（直播面板），不再自动跳队列
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已加入队列（${_files.length} 个文件），实时进度见下方「翻译进度」')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = SettingsProvider.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('AI 字幕翻译')),
      body: FileDropZone(
        acceptedExtensions: AppConstants.subtitleExtensions,
        onFilesDropped: _handleDroppedFiles,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── API 配置状态 ──
            SectionCard(
              title: '翻译服务',
              icon: Icons.smart_toy_outlined,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        settings.aiReady
                            ? Icons.check_circle
                            : Icons.error_outline,
                        size: 18,
                        color: settings.aiReady ? Colors.green : scheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          settings.aiReady
                              ? '已配置：${settings.aiModel} @ ${settings.aiBaseUrl}'
                              : '未配置：需要 API Key / BaseURL / 模型',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const SettingsScreen()),
                        ),
                        child: const Text('去设置'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '隐私提示：翻译会把字幕文本发送到所配置的 API 服务商，'
                    '请在合规前提下使用。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: '字幕文件（${_files.length}）',
              trailing: TextButton(
                onPressed: _pickFiles,
                child: const Text('选择字幕'),
              ),
              child: _files.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: StepGuide(steps: [
                        '点击右上「选择字幕」，或把字幕拖进页面（SRT/ASS/SSA/VTT）',
                        '在下方选择目标语言与 AI 服务',
                        '首次使用请先到「设置 → AI 服务」填入 API Key',
                      ]),
                    )
                  : Column(
                      children: [
                        for (final f in _files)
                          FileTile(
                            title: p.basename(f),
                            subtitle: p.dirname(f),
                            icon: Icons.subtitles_outlined,
                            onRemove: () => setState(() => _files.remove(f)),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            OutputSettingsCard(
              initialDir: _outputDir,
              onDirChanged: (dir) => setState(() => _outputDir = dir),
              showTemplate: false,
              defaultDirLabel: '默认：与各源文件同目录',
              onTemplateChanged: (_) {},
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '输出文件名：源文件主名_${_target.code}'
                '${_files.isEmpty ? '' : p.extension(_files.first)}'
                '（同名已存在时自动改为 _1、_2…）'
                '${_mergeMixed ? '；合并文件：源文件主名_mixed（原文 + 换行 + 译文）' : ''}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: '翻译设置',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('目标语言', style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final lang in TranslateLanguage.presets)
                        ChoiceChip(
                          label: Text(lang.name),
                          selected: _target.code == lang.code,
                          onSelected: (_) => setState(() => _target = lang),
                        ),
                    ],
                  ),
                  const Divider(height: 24),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('同时输出双语合并字幕（_mixed）'),
                    subtitle: const Text(
                        '每条字幕：原文 + 换行 + 译文，时间轴不变；'
                        '另存为 源文件主名_mixed',
                        style: TextStyle(fontSize: 12)),
                    value: _mergeMixed,
                    onChanged: (v) => setState(() => _mergeMixed = v),
                  ),
                  // 润色模式（v1.2）：翻译完成后追加二阶段润色调用
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('译文润色模式'),
                    subtitle: const Text(
                        '翻译后二阶段调用：仅优化标点/断句/口语表达，不改语义；'
                        '耗时约增加一倍',
                        style: TextStyle(fontSize: 12)),
                    value: _polish,
                    onChanged: (v) => setState(() => _polish = v),
                  ),
                  const SizedBox(height: 4),
                  // 术语表（v1.2）：人名 / 专名锁定，翻译时注入 prompt
                  OutlinedButton.icon(
                    onPressed: _openGlossaryDialog,
                    icon: const Icon(Icons.menu_book, size: 18),
                    label: Text(
                        '术语表 / 人名表（${SettingsProvider.instance.glossary.length}）'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '只翻译字幕内容，时间戳与样式不动；按批次调用 '
                    'chat/completions（约 30 条/批），失败自动重试 2 次；'
                    '任务可在队列中取消。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.translate),
              label: Text('开始翻译（${_files.length} 个文件）'),
            ),
            if (_liveTasks.isNotEmpty) ...[
              const SizedBox(height: 12),
              _livePanel(scheme),
            ],
          ],
        ),
      ),
    );
  }

  /// 直播面板（v2.2）：进行中翻译任务的实时思考流与事件行。
  Widget _livePanel(ColorScheme scheme) {
    return SectionCard(
      title: '翻译进度',
      icon: Icons.monitor_heart_outlined,
      trailing: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TaskQueueScreen()),
        ),
        child: const Text('查看队列'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final t in _liveTasks) ...[
            Row(
              children: [
                Icon(
                  t.status == TaskStatus.running
                      ? Icons.sync
                      : Icons.schedule,
                  size: 16,
                  color: t.status == TaskStatus.running
                      ? scheme.primary
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Text(
                  t.statusLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                // 像 Whisper 一样可回看：打开完整直播日志
                IconButton(
                  tooltip: '直播详情',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _openLiveDetail(t),
                  icon: const Icon(Icons.receipt_long_outlined, size: 16),
                ),
              ],
            ),
            if (t.status == TaskStatus.running) ...[
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: t.progress <= 0 ? null : t.progress,
                minHeight: 3,
              ),
            ],
            if (t.liveThinking.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '思考：${_tailOf(t.liveThinking, 400)}',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (t.liveTranslating.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '译文：${_tailOf(TranslationService.parseLiveTranscript(t.liveTranslating), 400)}',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (t.usageTotalTokens > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  _usageLine(t),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final line in _tailOfList(t.liveLines, 6))
              Text(
                line,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            const Divider(height: 16),
          ],
        ],
      ),
    );
  }

  /// 完整直播日志（像 Whisper 实时输出一样可回看）：
  /// 全部事件行 + 完整思考流 / 流式译文 / token 用量；
  /// 任务运行中时自动跟随滚动到最新。
  Future<void> _openLiveDetail(QueueTask task) {
    return showDialog<void>(
      context: context,
      builder: (_) => _LiveDetailDialog(task: task),
    );
  }

  /// 取字符串尾部（直播思考流只显示最新片段）。
  static String _tailOf(String s, int max) =>
      s.length <= max ? s : s.substring(s.length - max);

  /// token 用量摘要行（v2.2.1）：消耗 + 输入/输出拆分（v2.2.2 移除计费）。
  static String _usageLine(QueueTask t) =>
      '消耗：${_fmtInt(t.usageTotalTokens)} token'
      '（入 ${_fmtInt(t.usagePromptTokens)} / 出 ${_fmtInt(t.usageCompletionTokens)}）';

  /// 千位分隔（1500 → 1,500）。
  static String _fmtInt(int v) =>
      v.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');

  /// 取列表尾部 n 条（直播事件行只显示最近若干条）。
  static List<String> _tailOfList(List<String> list, int n) =>
      list.length <= n ? list : list.sublist(list.length - n);

  /// 术语表编辑对话框：原文 / 译文两列，译文留空 = 保留原文不译。
  Future<void> _openGlossaryDialog() async {
    final terms = List.of(SettingsProvider.instance.glossary);
    var dirty = false;
    await showDialog<void>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx, setDState) => AlertDialog(
          title: Text('术语表 / 人名表（${terms.length}/$kGlossaryMaxTerms）'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '锁定人名与专名的译法，解决前后不一致。译文留空 = 保留原文不译。'
                  '随每批翻译注入提示词。翻译时自动合并字幕目录下的 '
                  '.glossary.json 旁车（同词条旁车优先）。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => _importGlossary(setDState, terms),
                      icon: const Icon(Icons.file_upload_outlined, size: 16),
                      label: const Text('导入旁车'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => _exportGlossary(terms),
                      icon: const Icon(Icons.file_download_outlined, size: 16),
                      label: const Text('导出旁车'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (var i = 0; i < terms.length; i++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: TextEditingController(
                                        text: terms[i].source)
                                      ..selection = TextSelection.collapsed(
                                          offset: terms[i].source.length),
                                    decoration: const InputDecoration(
                                        isDense: true, labelText: '原文'),
                                    onChanged: (v) {
                                      terms[i] = GlossaryTerm(
                                          source: v,
                                          translation: terms[i].translation);
                                      dirty = true;
                                    },
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: TextEditingController(
                                        text: terms[i].translation)
                                      ..selection = TextSelection.collapsed(
                                          offset:
                                              terms[i].translation.length),
                                    decoration: const InputDecoration(
                                        isDense: true, labelText: '译文（空=不译）'),
                                    onChanged: (v) {
                                      terms[i] = GlossaryTerm(
                                          source: terms[i].source,
                                          translation: v);
                                      dirty = true;
                                    },
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline,
                                      size: 20),
                                  onPressed: () {
                                    setDState(() => terms.removeAt(i));
                                    dirty = true;
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dctx).pop(),
              child: const Text('取消'),
            ),
            OutlinedButton(
              onPressed: terms.length >= kGlossaryMaxTerms
                  ? null
                  : () => setDState(() => terms.add(const GlossaryTerm(
                      source: '', translation: ''))),
              child: const Text('添加条目'),
            ),
            FilledButton(
              onPressed: () async {
                final cleaned = terms
                    .where((t) => t.source.trim().isNotEmpty)
                    .map((t) => GlossaryTerm(
                        source: t.source.trim(),
                        translation: t.translation.trim()))
                    .toList();
                await SettingsProvider.instance.setGlossary(cleaned);
                if (dctx.mounted) Navigator.of(dctx).pop();
                if (mounted) setState(() {});
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    // 对话框内编辑未保存也要刷新按钮计数
    if (dirty && mounted) setState(() {});
  }

  /// 从旁车 JSON 文件导入词库：导入词条覆盖同 source 现有条目，
  /// 超出 [kGlossaryMaxTerms] 时截断（用户仍可在保存前手动调整）。
  Future<void> _importGlossary(
      void Function(VoidCallback fn) setDState, List<GlossaryTerm> terms) async {
    try {
      final picked = await FileService.instance.pickJsonFile();
      if (picked.isEmpty) return;
      final imported = GlossaryStore.loadFile(picked.first.path ?? '');
      if (imported.isEmpty) {
        if (mounted) showErrorSnack(context, '未读取到有效词条');
        return;
      }
      final bySource = {for (final t in terms) t.source: t};
      for (final t in imported) {
        bySource[t.source] = t;
      }
      final merged = bySource.values.take(kGlossaryMaxTerms).toList();
      setDState(() {
        terms
          ..clear()
          ..addAll(merged);
      });
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  /// 把当前对话框词条导出为目录旁车 `.glossary.json`（覆盖式）。
  Future<void> _exportGlossary(List<GlossaryTerm> terms) async {
    try {
      final dir = await FileService.instance.pickDirectory();
      if (dir == null || dir.isEmpty) return;
      final cleaned = terms
          .where((t) => t.source.trim().isNotEmpty)
          .map((t) => GlossaryTerm(
              source: t.source.trim(), translation: t.translation.trim()))
          .toList();
      await GlossaryStore.save(dir, cleaned);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导出 ${cleaned.length} 条到 $dir')),
        );
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }
}

/// 直播详情对话框（像 Whisper 实时输出面板）：完整直播日志可滚动回看，
/// 任务运行中自动跟随滚动到最新，结束后内容保留。
class _LiveDetailDialog extends StatefulWidget {
  const _LiveDetailDialog({required this.task});

  final QueueTask task;

  @override
  State<_LiveDetailDialog> createState() => _LiveDetailDialogState();
}

class _LiveDetailDialogState extends State<_LiveDetailDialog> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = widget.task;
    final running = t.status == TaskStatus.running;
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('直播详情')),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: (running ? scheme.primary : Colors.green)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              running ? '翻译中' : '已结束',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: running ? scheme.primary : Colors.green,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: 520,
        child: AnimatedBuilder(
          animation: QueueService.instance,
          builder: (context, _) {
            if (running) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scroll.hasClients) {
                  _scroll.jumpTo(_scroll.position.maxScrollExtent);
                }
              });
            }
            return SingleChildScrollView(
              controller: _scroll,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.title,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const Divider(height: 20),
                  if (t.liveThinking.trim().isNotEmpty) ...[
                    _label('思考', scheme),
                    Text(
                      t.liveThinking,
                      style: _mono(scheme),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (t.liveTranslating.trim().isNotEmpty) ...[
                    _label('译文（当前批次）', scheme),
                    Text(
                      TranslationService.parseLiveTranscript(t.liveTranslating),
                      style: _mono(scheme),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (t.usageTotalTokens > 0) ...[
                    _label('token 用量', scheme),
                    Text(
                      _usageLineOf(t),
                      style: _mono(scheme),
                    ),
                    const SizedBox(height: 10),
                  ],
                  _label('事件（全部 ${t.liveLines.length} 条）', scheme),
                  for (final line in t.liveLines)
                    Text(line, style: _mono(scheme)),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  static Widget _label(String text, ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: scheme.primary,
          ),
        ),
      );

  static TextStyle _mono(ColorScheme scheme) => TextStyle(
        fontFamily: 'Consolas',
        fontSize: 12,
        height: 1.5,
        color: scheme.onSurfaceVariant,
      );

  static String _usageLineOf(QueueTask t) =>
      '消耗：${t.usageTotalTokens} token'
      '（入 ${t.usagePromptTokens} / 出 ${t.usageCompletionTokens}）';
}
