import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/utils/filename_template.dart';
import '../core/utils/subtitle_matcher.dart';
import '../core/utils/time_format.dart';
import '../models/mux_track.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../providers/app_providers.dart';
import '../services/file_service.dart';
import '../services/mkvtoolnix/mkvtoolnix_service.dart';
import '../services/queue_service.dart';
import '../widgets/common.dart';
import '../widgets/file_drop_zone.dart';
import '../widgets/output_settings_card.dart';
import 'task_queue_screen.dart';

/// 封装轨道页（对齐 MKVToolNix 核心能力，唯一后端 mkvmerge）：
/// - 全类型轨道：字幕（SRT/ASS/SSA/VTT）、音频（AAC/MP3/FLAC/DTS…）、
///   附件（TTF/OTF 字体）
/// - 逐轨元数据：语言（ISO 639-2）、标题、默认轨（flag-default）、
///   强制轨（flag-forced）
/// - 输出固定 MKV；视频/源音轨/新增轨道全部流拷贝不重编码；
///   可保留原内嵌字幕轨（追加式合并）
/// - 批量：视频 ↔ 轨道文件按文件名自动配对，未匹配项手动指派
///
/// 布局参照 MKVToolNix GUI 封装器（Multiplexer）：顶部输入文件条，
/// 中央为单一轨道表格（行内编辑语言 / 名称 / 默认 / 强制，列结构同
/// MKVToolNix 的 Tracks 表），底部输出与操作栏。
class MuxScreen extends StatefulWidget {
  /// 嵌入轨道处理合并页时不带 AppBar（由外层提供标题与页签）
  final bool embedded;

  const MuxScreen({super.key, this.embedded = false});

  @override
  State<MuxScreen> createState() => _MuxScreenState();
}

/// 常用语言（ISO 639-2，MKVToolNix 语言下拉的常用子集）。
const _languages = [
  ('chi', '中文'),
  ('eng', '英语'),
  ('jpn', '日语'),
  ('kor', '韩语'),
  ('deu', '德语'),
  ('fra', '法语'),
  ('spa', '西班牙语'),
  ('ita', '意大利语'),
  ('por', '葡萄牙语'),
  ('rus', '俄语'),
  ('tha', '泰语'),
  ('vie', '越南语'),
  ('may', '马来语'),
  ('ind', '印尼语'),
  ('ara', '阿拉伯语'),
  ('hin', '印地语'),
  ('und', '未指定'),
];

String _langLabel(String code) {
  for (final (c, label) in _languages) {
    if (c == code) return label;
  }
  return code;
}

/// 单个视频的源轨道选择（音轨/字幕逐条、章节/标签开关、属性覆盖）。
class _SourceSel {
  /// 保留的源音轨 ID（mkvmerge -J）
  final Set<int> audio = {};

  /// 保留的源字幕轨 ID
  final Set<int> subs = {};

  /// 保留的源附件 ID（-J 附件 ID 从 1 起；探测时默认全选）
  final Set<int> fonts = {};

  /// 是否保留源章节
  bool chapters = true;

  /// 是否保留源标签（global/track tags）
  bool tags = true;

  /// 源轨道属性覆盖（track id → 覆盖值，null 字段跟随源）
  final Map<int, SourceTrackEdit> edits = {};
}

class _MuxScreenState extends State<MuxScreen> {
  final List<String> _videos = [];

  /// mkvmerge -J 分析结果（时长 / 分辨率 / 原轨道数展示）
  final Map<String, MkvFileInfo> _mkvInfo = {};
  final Set<String> _unreadable = {};

  /// 视频路径 → 待封装轨道列表（顺序即封装顺序）
  final Map<String, List<MuxTrack>> _tracks = {};

  /// 未配对到视频的轨道池（手动指派）
  final List<MuxTrack> _pool = [];

  /// 已取消「包含」勾选的轨道路径（仅 UI 排除，任务构建时过滤）
  final Set<String> _disabled = {};

  /// 每视频的源轨道选择（音轨/字幕逐条 + 章节开关）
  final Map<String, _SourceSel> _sourceSel = {};

  /// 折叠的视频分组
  final Set<String> _collapsed = {};

  /// 展开附件大类（字体/章节/标签）的视频（默认全部折叠）
  final Set<String> _globalsOpen = {};

  /// 附件大类内再展开字体明细的视频（默认全部折叠）
  final Set<String> _fontsOpen = {};

  /// 进行中的探测数（并发探测时布尔会提前熄灭）
  int _pendingProbes = 0;

  String? _outputDir;
  String _template = '';

  @override
  void initState() {
    super.initState();
    _template = SettingsProvider.instance.filenameTemplate;
  }

  bool get _mkvReady => MkvToolNixService.instance.isAvailable;

  /// 输出目录：锁定目录 > 源文件所在目录 > 应用文档目录兜底。
  Future<String> _resolveOutDir(String videoPath) async {
    final task = _outputDir;
    if (task != null) return task;
    final dir = p.dirname(videoPath);
    if (dir.isNotEmpty) return dir;
    return FileService.instance.outputDirFor(AppConstants.dirMux);
  }

  /// 就绪视频（至少一条启用外部轨道，或勾选了任一源轨道/章节）。
  Iterable<String> get _ready => _videos.where((v) {
        if ((_tracks[v] ?? const []).any((t) => !_disabled.contains(t.path))) {
          return true;
        }
        final sel = _sourceSel[v];
        if (sel == null) return false; // 未探测成功，无从选择源轨道
        return sel.audio.isNotEmpty || sel.subs.isNotEmpty || sel.chapters;
      });

  // ───────────────────────── 选择 / 配对 ─────────────────────────

  void _handleDroppedFiles(List<String> paths) {
    final newPaths = paths.where((path) => !_videos.contains(path)).toList();
    if (newPaths.isEmpty) return;
    setState(() {
      for (final path in newPaths) {
        _videos.add(path);
        _tracks[path] = [];
      }
    });
    for (final path in newPaths) {
      _probe(path);
    }
    _autoMatch();
  }

  Future<void> _pickVideos() async {
    try {
      await FileService.instance.ensureStoragePermissions();
      final picked = await FileService.instance.pickVideos(multi: true);
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final path = f.path;
          if (path == null || _videos.contains(path)) continue;
          _videos.add(path);
          _tracks[path] = [];
        }
      });
      for (final f in picked) {
        _probe(f.path);
      }
      _autoMatch();
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _probe(String? path) async {
    if (path == null || _mkvInfo.containsKey(path) || _unreadable.contains(path)) {
      return;
    }
    setState(() => _pendingProbes++);
    try {
      final info = await MkvToolNixService.instance.probe(path);
      if (!mounted) return;
      setState(() {
        if (info != null) {
          _mkvInfo[path] = info;
          // 源轨道默认：音轨全保留、内嵌字幕不保留、章节保留
          // （与旧版 audioMode=all / keepSubs=false 行为一致）
          final sel = _SourceSel();
          for (final t in info.tracks) {
            if (t.type == 'audio') sel.audio.add(t.id);
          }
          // 源附件默认全保留（mkvmerge 默认行为一致，字体常为字幕渲染必需）
          sel.fonts.addAll(info.attachments.map((a) => a.id));
          _sourceSel[path] = sel;
        } else {
          _unreadable.add(path);
        }
      });
    } finally {
      if (mounted) setState(() => _pendingProbes--);
    }
  }

  Future<void> _pickTracks(MuxTrackType type) async {
    try {
      final picked = switch (type) {
        MuxTrackType.subtitle =>
          await FileService.instance.pickSubtitles(multi: true),
        MuxTrackType.audio => await FileService.instance.pickAudios(multi: true),
        MuxTrackType.attachment =>
          await FileService.instance.pickAttachments(multi: true),
      };
      if (picked.isEmpty || !mounted) return;
      setState(() {
        final known = _pool.map((t) => t.path).toSet()
          ..addAll(_tracks.values.expand((list) => list.map((t) => t.path)));
        for (final f in picked) {
          final path = f.path;
          // 同一路径重复添加会产生重复 ValueKey（ReorderableListView 崩溃）
          if (path == null || known.contains(path)) continue;
          known.add(path);
          _pool.add(MuxTrack(
            type: type,
            path: path,
            language: type == MuxTrackType.attachment ? '' : 'chi',
            title: '',
          ));
        }
      });
      _autoMatch();
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  /// 自动配对：池中文件按文件名匹配到「尚无同类型轨道」的视频。
  void _autoMatch() {
    if (_pool.isEmpty || _videos.isEmpty) return;
    final remaining = <MuxTrack>[];
    var matched = false;
    for (final t in List.of(_pool)) {
      String? best;
      var bestScore = -1;
      for (final v in _videos) {
        // 每视频每类型至多自动配一条，其余留给手动
        if (_tracks[v]!.any((x) => x.type == t.type)) continue;
        final score = subtitleMatchScore(v, t.path);
        if (score > bestScore) {
          bestScore = score;
          best = v;
        }
      }
      if (best != null && bestScore > 0) {
        _tracks[best]!.add(t);
        matched = true;
      } else {
        remaining.add(t);
      }
    }
    if (matched) setState(() => _pool..clear()..addAll(remaining));
  }

  /// 手动把池中某轨道指派给视频。
  void _assignPoolTrack(MuxTrack t, String video) {
    setState(() {
      _pool.remove(t);
      _tracks[video]!.add(t);
    });
  }

  /// 移除视频：已指派轨道退回池中（不静默丢弃），并清除其包含态勾选。
  void _removeVideo(String v) {
    setState(() {
      final known = _pool.map((t) => t.path).toSet();
      for (final t in _tracks[v] ?? const <MuxTrack>[]) {
        if (!known.contains(t.path)) _pool.add(t);
        _disabled.remove(t.path);
      }
      _videos.remove(v);
      _tracks.remove(v);
      _mkvInfo.remove(v);
      _unreadable.remove(v);
      _collapsed.remove(v);
      _globalsOpen.remove(v);
      _sourceSel.remove(v);
    });
  }

  // ───────────────────────── 任务构建 ─────────────────────────

  /// 当前生效模板（空 = muxDefault，与输出卡片提示一致）。
  String get _effectiveTemplate =>
      _template.isEmpty ? FilenameTemplate.muxDefault : _template;

  Future<void> _start() async {
    if (!_mkvReady) {
      showErrorSnack(context, '未检测到 MKVToolNix：请在「设置 → MKVToolNix」'
          '配置安装目录或导入工具');
      return;
    }
    final ready = _ready.toList(growable: false);
    if (ready.isEmpty) {
      showErrorSnack(context, '请先选择视频并至少为其中一个指定轨道');
      return;
    }
    final q = QueueService.instance;
    // 本批次已用输出名（防两个同basename视频在任务创建期撞名：
    // 任务按队列顺序执行，创建时文件都不存在，执行后互相覆盖）
    final used = <String>{};
    for (final v in ready) {
      // 未锁定目录时各视频输出到其所在目录
      final outDir = await _resolveOutDir(v);
      // 已取消包含的轨道不进入封装
      final tracks = _tracks[v]!
          .where((t) => !_disabled.contains(t.path))
          .toList(growable: false);
      var name = FilenameTemplate.render(
        _effectiveTemplate,
        sourceName: p.basename(v),
        extension: 'mkv',
        container: 'mkv',
      );
      // 输出不能与源文件同名同目录（mkvmerge 拒绝读写同一文件）
      if (p.equals(p.join(outDir, name), v)) {
        name = FilenameTemplate.render(
          '${_effectiveTemplate}_muxed',
          sourceName: p.basename(v),
          extension: 'mkv',
          container: 'mkv',
        );
      }
      var i = 2;
      while (used.contains(p.join(outDir, name).toLowerCase()) ||
          File(p.join(outDir, name)).existsSync()) {
        final dot = name.lastIndexOf('.');
        name = dot > 0
            ? '${name.substring(0, dot)}_$i${name.substring(dot)}'
            : '${name}_$i';
        i++;
      }
      used.add(p.join(outDir, name).toLowerCase());
      final out = p.join(outDir, name);
      final sub = tracks.where((t) => t.type == MuxTrackType.subtitle).length;
      final aud = tracks.where((t) => t.type == MuxTrackType.audio).length;
      final att = tracks.where((t) => t.type == MuxTrackType.attachment).length;
      final sel = _sourceSel[v];
      final srcAudio = sel?.audio.length ?? 0;
      final srcSub = sel?.subs.length ?? 0;
      final summary = [
        if (srcAudio > 0) '源音轨 $srcAudio',
        if (srcSub > 0) '源字幕 $srcSub',
        if (sub > 0) '$sub 字幕',
        if (aud > 0) '$aud 音频',
        if (att > 0) '$att 附件',
        if (sel != null && sel.chapters &&
            (_mkvInfo[v]?.hasChapters ?? false)) '章节',
      ].join(' + ');
      q.addTask(
        type: TaskType.mux,
        title: '封装 ${p.basename(v)}（$summary → MKV）',
        params: {
          TaskParams.videoPath: v,
          TaskParams.tracksJson: MuxTrack.encodeList(tracks),
          TaskParams.container: 'mkv',
          // 探测成功的视频写入逐轨选择；失败的缺省（旧参数语义兜底）
          if (sel != null)
            TaskParams.sourceSel: jsonEncode({
              'audio': sel.audio.toList()..sort(),
              'subs': sel.subs.toList()..sort(),
              'fonts': sel.fonts.toList()..sort(),
              'chapters': sel.chapters,
              'tags': sel.tags,
              if (sel.edits.isNotEmpty)
                'edits': [
                  // 只对保留的轨道发覆盖参数（被排除轨的选项无意义，
                  // mkvmerge 可能对其输出警告）
                  for (final e in sel.edits.values)
                    if (sel.audio.contains(e.id) || sel.subs.contains(e.id))
                      e.toJson(),
                ],
            }),
          TaskParams.outputPath: out,
          TaskParams.totalDurationMs:
              '${_mkvInfo[v]?.duration.inMilliseconds ?? 0}',
        },
      );
    }
    q.start();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TaskQueueScreen()),
    );
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 监听可用性通知：本页常驻 IndexedStack（轨道处理页签），设置页配置
    // MKVToolNix 后返回时不会自动重建，须靠 notifier 触发刷新
    final body = ValueListenableBuilder<bool>(
      valueListenable: MkvToolNixService.instance.availability,
      builder: (context, mkvReady, _) => Column(
        children: [
          if (!mkvReady) _unavailableBanner(scheme),
          if (_pendingProbes > 0) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  _inputZone(scheme, mkvReady),
                  const SizedBox(height: 10),
                  Expanded(child: _tracksZone(scheme, mkvReady)),
                  const SizedBox(height: 10),
                  OutputSettingsCard(
                    initialDir: _outputDir,
                    onDirChanged: (dir) => setState(() => _outputDir = dir),
                    initialTemplate: _template,
                    templateFallback: FilenameTemplate.muxDefault,
                    onTemplateChanged: (tpl) => _template = tpl,
                    // 本页嵌在轨道处理页签内，纵向空间紧张：
                    // 模板区默认折叠，防短窗口下固定内容溢出
                    collapsibleTemplate: true,
                    defaultDirLabel:
                        '未锁定 — 每个视频输出到其源文件所在目录',
                    previewSourceName:
                        _videos.isNotEmpty ? p.basename(_videos.first) : null,
                    previewExtension: 'mkv',
                    previewContainer: 'mkv',
                  ),
                ],
              ),
            ),
          ),
          _actionBar(scheme, mkvReady),
        ],
      ),
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('封装轨道（Mux）')),
            body: FileDropZone(
              acceptedExtensions: AppConstants.videoExtensions,
              onFilesDropped: _handleDroppedFiles,
              child: body,
            ),
          );
  }

  Widget _unavailableBanner(ColorScheme scheme) {
    final err = MkvToolNixService.instance.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      color: scheme.errorContainer.withValues(alpha: 0.5),
      child: Row(
        children: [
          Icon(Icons.extension_off, color: scheme.error, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              err ?? '未检测到 MKVToolNix',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }

  // ── 区 1：输入文件（MKVToolNix 顶部工具栏的添加输入文件） ──

  Widget _inputZone(ColorScheme scheme, bool mkvReady) {
    return _Zone(
      label: '输入文件（${_videos.length} 视频 · ${_pool.length} 未指派轨道）',
      icon: Icons.movie_filter_outlined,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<MuxTrackType>(
            tooltip: '添加轨道文件',
            icon: const Icon(Icons.playlist_add, size: 18),
            onSelected: _pickTracks,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: MuxTrackType.subtitle,
                child: Row(children: [
                  Icon(Icons.subtitles_outlined, size: 16),
                  SizedBox(width: 10),
                  Text('字幕文件…'),
                ]),
              ),
              const PopupMenuItem(
                value: MuxTrackType.audio,
                child: Row(children: [
                  Icon(Icons.graphic_eq, size: 16),
                  SizedBox(width: 10),
                  Text('音频文件…'),
                ]),
              ),
              const PopupMenuItem(
                value: MuxTrackType.attachment,
                child: Row(children: [
                  Icon(Icons.font_download_outlined, size: 16),
                  SizedBox(width: 10),
                  Text('字体附件…'),
                ]),
              ),
            ],
          ),
          TextButton.icon(
            onPressed: mkvReady ? _pickVideos : null,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加视频'),
          ),
        ],
      ),
      child: _videos.isEmpty
          ? Text(
              '添加视频与字幕 / 音频 / 字体文件；同名（忽略扩展名）的轨道自动配对，'
              '视频与源音轨流拷贝不重编码',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            )
          : Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final v in _videos) _fileChip(v)],
            ),
    );
  }

  Widget _fileChip(String v) {
    final scheme = Theme.of(context).colorScheme;
    final unreadable = _unreadable.contains(v);
    final parsed = _mkvInfo.containsKey(v);
    return InputChip(
      onDeleted: () => _removeVideo(v),
      deleteButtonTooltipMessage: '移除该视频（已指派轨道退回未指派池）',
      avatar: Icon(
        unreadable
            ? Icons.error_outline
            : parsed
                ? Icons.check_circle_outline
                : Icons.hourglass_empty,
        size: 16,
        color: unreadable
            ? scheme.error
            : parsed
                ? _typeColor('video')
                : scheme.outline,
      ),
      label: Text(p.basename(v)),
      tooltip: v,
      visualDensity: VisualDensity.compact,
    );
  }

  // ── 区 2：轨道表格（MKVToolNix「Tracks, chapters and tags」） ──

  Widget _tracksZone(ColorScheme scheme, bool mkvReady) {
    return _Zone(
      label: '轨道',
      icon: Icons.format_list_bulleted,
      expand: true,
      trailing: IconButton(
        tooltip: '封装说明',
        icon: Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
        onPressed: () => _showRulesDialog(scheme),
      ),
      child: _videos.isEmpty
          ? (_pool.isEmpty
              ? EmptyState(
                  icon: Icons.merge_type_outlined,
                  message: '添加视频后在此配置轨道\n语言 / 名称 / 默认 / 强制逐轨可调，拖动调整顺序',
                  action: FilledButton.tonalIcon(
                    onPressed: mkvReady ? _pickVideos : null,
                    icon: const Icon(Icons.add),
                    label: const Text('添加视频'),
                  ),
                )
              // 已有轨道文件但还没视频：空态提示 + 池列表一并滚动，防溢出
              : ListView(
                  children: [
                    const SizedBox(height: 20),
                    EmptyState(
                      icon: Icons.merge_type_outlined,
                      message: '添加视频后在此配置轨道\n语言 / 名称 / 默认 / 强制逐轨可调，拖动调整顺序',
                      action: FilledButton.tonalIcon(
                        onPressed: mkvReady ? _pickVideos : null,
                        icon: const Icon(Icons.add),
                        label: const Text('添加视频'),
                      ),
                    ),
                    _poolGroup(scheme),
                    const SizedBox(height: 12),
                  ],
                ))
          : Scrollbar(
              child: ListView.builder(
                itemCount: _videos.length + (_pool.isEmpty ? 0 : 1),
                itemBuilder: (_, i) => i < _videos.length
                    ? _videoGroup(_videos[i])
                    : _poolGroup(scheme),
              ),
            ),
    );
  }

  /// 单个视频分组：组头（文件名 + meta + 输出预览）+ 源轨道摘要 + 外部轨列表。
  Widget _videoGroup(String v) {
    final scheme = Theme.of(context).colorScheme;
    final info = _mkvInfo[v];
    final tracks = _tracks[v] ?? const <MuxTrack>[];
    final expanded = !_collapsed.contains(v);
    final meta = _unreadable.contains(v)
        ? '无法解析'
        : info == null
            ? '解析中…'
            : _metaOf(info);
    final outName = FilenameTemplate.render(
      _effectiveTemplate,
      sourceName: p.basename(v),
      extension: 'mkv',
      container: 'mkv',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 组头
        InkWell(
          onTap: () => setState(() {
            expanded ? _collapsed.add(v) : _collapsed.remove(v);
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Icon(
                  expanded ? Icons.expand_more : Icons.chevron_right,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                Icon(Icons.videocam_outlined,
                    size: 16, color: _typeColor('video')),
                const SizedBox(width: 8),
                Expanded(
                  flex: 5,
                  child: Text(
                    p.basename(v),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  flex: 3,
                  child: Text(
                    meta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  flex: 3,
                  child: Text(
                    '→ $outName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.primary, fontFamily: 'Consolas'),
                  ),
                ),
                const SizedBox(width: 4),
                if (expanded && _pool.isNotEmpty)
                  IconButton(
                    tooltip: '从未指派池添加轨道',
                    icon: const Icon(Icons.playlist_add_check, size: 16),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _addFromPoolMenu(v),
                  ),
                IconButton(
                  tooltip: '移除视频（轨道退回池）',
                  icon: const Icon(Icons.close, size: 15),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _removeVideo(v),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...[
          _sourceTracks(v),
          if (tracks.isNotEmpty)
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              itemCount: tracks.length,
              onReorderItem: (oldI, newI) {
                setState(() {
                  _tracks[v]!.insert(newI, _tracks[v]!.removeAt(oldI));
                });
              },
              itemBuilder: (_, i) => _trackRow(v, tracks[i], i,
                  key: ValueKey(tracks[i].path)),
            ),
        ],
      ],
    );
  }

  /// 源轨道列表（MKVToolNix 源文件轨道逐条勾选）：
  /// 视频轨只读（始终保留），音轨/字幕逐条勾选，章节/标签开关，
  /// 每条轨道可查看完整属性（MKVToolNix track properties）。
  Widget _sourceTracks(String v) {
    final scheme = Theme.of(context).colorScheme;
    final info = _mkvInfo[v];
    final sel = _sourceSel[v];
    if (info == null || sel == null) {
      // 解析中 / 无法解析：不渲染源轨道区
      return const SizedBox.shrink();
    }
    final labelStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant, fontSize: 11.5);
    return Padding(
      padding: const EdgeInsets.only(left: 26, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('源轨道', style: labelStyle),
          const SizedBox(height: 2),
          for (final t in info.tracks.where((t) => t.type == 'video'))
            _sourceRow(
              track: t,
              sel: sel,
              dim: true,
              checked: null,
            ),
          for (final t in info.tracks.where((t) => t.type == 'audio'))
            _sourceRow(
              track: t,
              sel: sel,
              checked: sel.audio.contains(t.id),
              onChanged: (on) => setState(() {
                on ? sel.audio.add(t.id) : sel.audio.remove(t.id);
              }),
            ),
          for (final t in info.tracks.where((t) => t.type == 'subtitle'))
            _sourceRow(
              track: t,
              sel: sel,
              checked: sel.subs.contains(t.id),
              onChanged: (on) => setState(() {
                on ? sel.subs.add(t.id) : sel.subs.remove(t.id);
              }),
            ),
          _globalItemsSection(v, info, sel, labelStyle),
        ],
      ),
    );
  }

  /// 附件大类（字体 / 章节 / 标签统一收纳）：默认折叠为一行摘要，
  /// 点击展开子项；字体子组可再展开逐个显示源附件（只读明细，
  /// 源附件不带入封装——新字体经「添加轨道文件 → 附件」添加）。
  /// 摘要实时反映各开关状态（字体×N · 章节✓ · 标签✗）。
  Widget _globalItemsSection(
    String v,
    MkvFileInfo info,
    _SourceSel sel,
    TextStyle? labelStyle,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final open = _globalsOpen.contains(v);
    final fontsOpen = _fontsOpen.contains(v);
    final fontsKept = info.attachments
        .where((a) => sel.fonts.contains(a.id))
        .length;
    final summary = [
      if (info.attachments.isNotEmpty)
        '字体$fontsKept/${info.attachments.length}',
      if (info.hasChapters) '章节${sel.chapters ? '✓' : '✗'}',
      if (info.hasTags) '标签${sel.tags ? '✓' : '✗'}',
    ].join(' · ');
    if (summary.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 附件大类折叠头
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => setState(() {
            open ? _globalsOpen.remove(v) : _globalsOpen.add(v);
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox(width: 32),
                Icon(
                  open ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Icon(Icons.attach_file,
                    size: 14, color: _typeColor('attachment')),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '附件（$summary）',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (open) ...[
          // 字体子组：可再展开，逐个列出源附件
          if (info.attachments.isNotEmpty) ...[
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => setState(() {
                fontsOpen ? _fontsOpen.remove(v) : _fontsOpen.add(v);
              }),
              child: Padding(
                padding: const EdgeInsets.only(left: 14, top: 1, bottom: 1),
                child: Row(
                  children: [
                    Icon(
                      fontsOpen ? Icons.expand_more : Icons.chevron_right,
                      size: 15,
                      color: scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.font_download_outlined,
                        size: 13, color: _typeColor('attachment')),
                    const SizedBox(width: 6),
                    Text(
                        '字体 $fontsKept/${info.attachments.length}'
                        '${fontsKept == 0 ? '（全部排除）' : ''}',
                        style: const TextStyle(fontSize: 11.5)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '勾选保留源字体，新字体另经上方「添加轨道文件」添加',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle?.copyWith(fontSize: 10.5) ??
                            const TextStyle(fontSize: 10.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (fontsOpen)
              for (final a in info.attachments) _fontRow(a, sel),
          ],
          if (info.hasChapters)
            _globalRow(
              icon: Icons.bookmark_outlined,
              color: _typeColor('chapters'),
              text: '章节',
              checked: sel.chapters,
              onChanged: (on) => setState(() => sel.chapters = on),
            ),
          if (info.hasTags)
            _globalRow(
              icon: Icons.label_outline,
              color: _typeColor('chapters'),
              text: '标签（轨道/全局 tags）',
              checked: sel.tags,
              onChanged: (on) => setState(() => sel.tags = on),
            ),
        ],
      ],
    );
  }

  /// 源附件（字体）明细行：勾选保留该附件（勾上 → 产物含此源字体）。
  /// 行格式 gMKV 等宽风格 AID · 类型 · 文件名。
  Widget _fontRow(MkvAttachmentInfo a, _SourceSel sel) {
    final scheme = Theme.of(context).colorScheme;
    final checked = sel.fonts.contains(a.id);
    return Padding(
      padding: const EdgeInsets.only(left: 34),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            height: 26,
            child: Checkbox(
              value: checked,
              onChanged: (on) => setState(() {
                on ?? false ? sel.fonts.add(a.id) : sel.fonts.remove(a.id);
              }),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.font_download,
              size: 12, color: _typeColor('attachment')),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'AID ${a.id} · ${a.codecKind.toUpperCase()} · ${a.fileName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontSize: 11.5,
                color: checked
                    ? null
                    : scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 26),
            child: Text(
              checked ? '保留' : '排除',
              style: TextStyle(
                  fontSize: 10.5, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  /// 源轨道行（MKVToolNix 风格）：
  /// 类型徽章 + TID/编码/语言/规格属性串（含覆盖值）+ 标志徽章 +
  /// 属性编辑弹窗入口。
  Widget _sourceRow({
    required MkvTrackInfo track,
    required _SourceSel sel,
    bool dim = false,
    bool? checked,
    ValueChanged<bool>? onChanged,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final edit = sel.edits[track.id];
    final flags = <String>[
      if (edit?.isDefault ?? track.defaultTrack) '默认',
      if (track.type != 'video' && (edit?.isForced ?? track.forcedTrack))
        '强制',
      if (!(edit?.enabled ?? track.enabled)) '已禁用',
      if (edit?.delayMs != null && edit!.delayMs != 0)
        '${edit.delayMs! > 0 ? '+' : ''}${edit.delayMs}ms',
    ];
    final edited = edit != null &&
        (edit.language != null ||
            edit.name != null ||
            edit.isDefault != null ||
            edit.isForced != null ||
            edit.enabled != null ||
            (edit.delayMs != null && edit.delayMs != 0));
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged(!checked!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              height: 30,
              child: checked == null
                  ? null
                  : Checkbox(
                      value: checked,
                      onChanged: (_) => onChanged!(!checked),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
            ),
            _typeBadge(track.type),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _trackTag(track, edit),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11.5,
                  color: dim ? scheme.onSurfaceVariant : null,
                ),
              ),
            ),
            if (edited)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    '已编辑',
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onTertiaryContainer,
                    ),
                  ),
                ),
              ),
            for (final f in flags)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    f,
                    style: TextStyle(
                      fontSize: 10,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
            SizedBox(
              width: 26,
              child: IconButton(
                tooltip: '轨道属性',
                icon: Icon(Icons.tune,
                    size: 14, color: scheme.onSurfaceVariant),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: () => _showSourceTrackProps(track, sel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 章节 / 标签等全局项行。
  Widget _globalRow({
    required IconData icon,
    required Color color,
    required String text,
    required bool checked,
    required ValueChanged<bool> onChanged,
  }) {
    return InkWell(
      onTap: () => onChanged(!checked),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              height: 30,
              child: Checkbox(
                value: checked,
                onChanged: (_) => onChanged(!checked),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 11.5))),
            if (!checked)
              Text('不封装',
                  style: TextStyle(fontSize: 10.5, color: color)),
            const SizedBox(width: 26),
          ],
        ),
      ),
    );
  }

  /// MKVToolNix 风格类型徽章（V/A/S）。
  Widget _typeBadge(String type) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (type) {
      'video' => ('V', _typeColor('video')),
      'audio' => ('A', _typeColor('audio')),
      'subtitle' => ('S', _typeColor('subtitle')),
      _ => ('?', _typeColor('other')),
    };
    return Container(
      width: 20,
      height: 18,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.brightness == Brightness.dark
              ? color.withValues(alpha: 1)
              : color,
        ),
      ),
    );
  }

  /// gMKVTrack 风格的源轨属性串：TID · 编码 · 语言 · 名称 · 规格
  /// （语言/名称显示编辑覆盖值）。
  String _trackTag(MkvTrackInfo t, [SourceTrackEdit? edit]) {
    final b = StringBuffer('TID ${t.id}');
    if (t.codec.isNotEmpty) b.write(' · ${t.codec.toUpperCase()}');
    final lang = edit?.language ?? t.language;
    if (lang.isNotEmpty) b.write(' · ${_langLabel(lang)}');
    final name = edit?.name ?? t.trackName;
    if (name.isNotEmpty) b.write(' · $name');
    final extra = _sourceExtra(t);
    if (extra != null) b.write(' · $extra');
    if (t.type == 'video') b.write(' · 视频轨（始终保留）');
    return b.toString();
  }

  String? _sourceExtra(MkvTrackInfo t) {
    if (t.type == 'video' &&
        t.pixelWidth != null &&
        t.pixelHeight != null) {
      return '${t.pixelWidth}x${t.pixelHeight}';
    }
    if (t.type == 'audio') {
      final ch = t.channels == null ? '' : '${t.channels}ch';
      final hz = t.samplingRate == null ? '' : '${t.samplingRate! ~/ 1000}kHz';
      return [ch, hz].where((e) => e.isNotEmpty).join(' ');
    }
    return null;
  }

  /// 源轨道属性弹窗（可编辑，MKVToolNix 源轨 track options）：
  /// 语言 / 名称 / 默认 / 强制 / 启用 / 延迟；与源值相同的字段不写参数
  /// （跟随源），可一键重置。
  Future<void> _showSourceTrackProps(
      MkvTrackInfo t, _SourceSel sel) async {
    final scheme = Theme.of(context).colorScheme;
    final edit = sel.edits[t.id];
    final nameCtrl = TextEditingController(
      text: edit?.name ?? t.trackName,
    );
    final delayCtrl = TextEditingController(
      text: '${edit?.delayMs ?? 0}',
    );
    // 三态：null = 跟随源（默认），显式 true/false = 覆盖
    bool? isDefault = edit?.isDefault;
    bool? isForced = edit?.isForced;
    bool? enabled = edit?.enabled;
    var lang = edit?.language ?? t.language;
    if (lang.isEmpty) lang = 'und';

    bool changed() => nameCtrl.text.trim() != t.trackName ||
        lang != (t.language.isEmpty ? 'und' : t.language) ||
        isDefault != null ||
        isForced != null ||
        enabled != null ||
        (int.tryParse(delayCtrl.text.trim()) ?? 0) != 0;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('${_typeLabel(t.type)}轨属性 — TID ${t.id}'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${t.codecId.isEmpty ? t.codec.toUpperCase() : t.codecId.toUpperCase()}'
                    '${t.type == 'video' && t.pixelWidth != null ? ' · ${t.pixelWidth}x${t.pixelHeight}' : ''}'
                    '${t.type == 'audio' && t.channels != null ? ' · ${t.channels}ch${t.samplingRate != null ? ' · ${t.samplingRate} Hz' : ''}' : ''}',
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: lang,
                    decoration: const InputDecoration(
                        labelText: '语言', isDense: true),
                    items: [
                      for (final (code, label) in _languages)
                        DropdownMenuItem(
                          value: code,
                          child: Text(
                              code == 'und' ? label : '$label（$code）'),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) setDialog(() => lang = v);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                        labelText: '轨道名称', isDense: true),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: delayCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '延迟（毫秒，--sync）',
                      isDense: true,
                      helperText: '正数延后 / 负数提前；0 = 跟随源',
                      suffixText: 'ms',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('默认轨（flag-default）'),
                    subtitle: Text(
                        '源：${t.defaultTrack ? "默认" : "非默认"}${isDefault == null ? "（跟随源）" : ""}'),
                    value: isDefault ?? t.defaultTrack,
                    onChanged: (v) => setDialog(
                        () => isDefault = v == t.defaultTrack ? null : v),
                  ),
                  if (t.type != 'video')
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('强制轨（flag-forced）'),
                      subtitle: Text(
                          '源：${t.forcedTrack ? "强制" : "非强制"}${isForced == null ? "（跟随源）" : ""}'),
                      value: isForced ?? t.forcedTrack,
                      onChanged: (v) => setDialog(
                          () => isForced = v == t.forcedTrack ? null : v),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('启用（flag-enabled）'),
                    subtitle: Text(
                        '源：${t.enabled ? "启用" : "已禁用"}${enabled == null ? "（跟随源）" : ""}'),
                    value: enabled ?? t.enabled,
                    onChanged: (v) => setDialog(
                        () => enabled = v == t.enabled ? null : v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                nameCtrl.text = t.trackName;
                delayCtrl.text = '0';
                setDialog(() {
                  lang = t.language.isEmpty ? 'und' : t.language;
                  isDefault = null;
                  isForced = null;
                  enabled = null;
                });
              },
              child: const Text('重置'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    final delay = int.tryParse(delayCtrl.text.trim()) ?? 0;
    final effectiveChanged = changed();
    delayCtrl.dispose();
    nameCtrl.dispose();
    if (ok != true) return;
    setState(() {
      if (!effectiveChanged) {
        sel.edits.remove(t.id);
        return;
      }
      sel.edits[t.id] = SourceTrackEdit(
        id: t.id,
        language: lang == (t.language.isEmpty ? 'und' : t.language)
            ? null
            : lang,
        name: nameCtrl.text.trim() == t.trackName ? null : nameCtrl.text.trim(),
        isDefault: isDefault,
        isForced: isForced,
        enabled: enabled,
        delayMs: delay == 0 ? null : delay,
      );
    });
  }

  String _typeLabel(String type) => switch (type) {
        'video' => '视频',
        'audio' => '音频',
        'subtitle' => '字幕',
        _ => '其他',
      };

  /// 语言选择器：按钮显示语言名（primary 色加粗），菜单浮层带背景、
  /// 阴影与舒适行高（42），显示「语言名（code）」全称，清晰可读。
  Widget _langPicker(MuxTrack t) {
    final scheme = Theme.of(context).colorScheme;
    final known = _languages.any((l) => l.$1 == t.language);
    final current = known ? t.language : 'und';
    return PopupMenuButton<String>(
      initialValue: current,
      tooltip: '轨道语言（ISO 639-2）',
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 210, maxWidth: 280),
      color: scheme.surfaceContainerLow,
      elevation: 8,
      onSelected: (code) => setState(() => t.language = code),
      itemBuilder: (_) => [
        for (final (code, label) in _languages)
          PopupMenuItem(
            value: code,
            height: 42,
            child: Text(
              code == 'und' ? label : '$label（$code）',
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _langLabel(current),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ),
            Icon(Icons.arrow_drop_down,
                size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }

  /// 外部轨道行：MKVToolNix 表格行（拖柄 + 含☑ + 类型 + 文件 + 语言▾ +
  /// 名称输入 + 默认☑ + 强制☑ + 移除）。
  Widget _trackRow(String video, MuxTrack t, int index, {Key? key}) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = !_disabled.contains(t.path);
    final isSub = t.type == MuxTrackType.subtitle;
    final isAudio = t.type == MuxTrackType.audio;
    final hasLang = isSub || isAudio;
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: enabled
            ? null
            : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: SizedBox(
              width: 24,
              child: Icon(Icons.drag_indicator,
                  size: 16, color: scheme.outline),
            ),
          ),
          SizedBox(
            width: 36,
            child: Checkbox(
              value: enabled,
              onChanged: (v) => setState(() {
                v == true
                    ? _disabled.remove(t.path)
                    : _disabled.add(t.path);
              }),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          Icon(_typeIcon(t.type), size: 16, color: _typeColorOf(t)),
          const SizedBox(width: 6),
          Expanded(
            flex: 5,
            child: Text(
              '${index + 1}. ${p.basename(t.path)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          SizedBox(
            width: 116,
            child: hasLang ? _langPicker(t) : null,
          ),
          Expanded(
            flex: 4,
            child: TextFormField(
              initialValue: t.title,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                hintText: '（可选）',
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
              onChanged: (s) => t.title = s,
            ),
          ),
          SizedBox(
            width: 46,
            child: hasLang
                ? Tooltip(
                    message: '默认轨（flag-default）',
                    child: Checkbox(
                      value: t.isDefault,
                      onChanged: (v) =>
                          setState(() => t.isDefault = v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  )
                : null,
          ),
          SizedBox(
            width: 46,
            child: isSub
                ? Tooltip(
                    message: '强制轨（flag-forced）',
                    child: Checkbox(
                      value: t.isForced,
                      onChanged: (v) =>
                          setState(() => t.isForced = v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  )
                : null,
          ),
          SizedBox(
            width: 30,
            child: IconButton(
              tooltip: '轨道属性（延迟 / 启用）',
              icon: Icon(Icons.tune, size: 15, color: scheme.onSurfaceVariant),
              visualDensity: VisualDensity.compact,
              onPressed: () => _showTrackProps(t),
            ),
          ),
          SizedBox(
            width: 34,
            child: IconButton(
              tooltip: '移除该轨',
              icon: const Icon(Icons.close, size: 15),
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() {
                _tracks[video]!.remove(t);
                _disabled.remove(t.path);
              }),
            ),
          ),
        ],
      ),
    );
  }

  /// 外部轨道属性弹窗：文件信息（只读）+ 延迟 / 启用编辑
  /// （MKVToolNix track options：--sync / --track-enabled）。
  Future<void> _showTrackProps(MuxTrack t) async {
    final scheme = Theme.of(context).colorScheme;
    final delayCtrl = TextEditingController(text: '${t.delayMs}');
    var enabled = t.enabled;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('${t.type.label}轨道属性'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 92,
                        child: Text('文件',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant)),
                      ),
                      Expanded(
                        child: Text(
                          p.basename(t.path),
                          style: const TextStyle(
                              fontSize: 12.5, fontFamily: 'Consolas'),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 92,
                        child: Text('格式',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: scheme.onSurfaceVariant)),
                      ),
                      Text(
                        p.extension(t.path).replaceFirst('.', '').toUpperCase(),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 20),
                TextField(
                  controller: delayCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '延迟（毫秒，--sync）',
                    hintText: '0',
                    helperText: '正数延后 / 负数提前；0 = 不调整',
                    isDense: true,
                    suffixText: 'ms',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('启用（flag-enabled）'),
                  subtitle:
                      const Text('禁用轨保留在容器中但播放器默认跳过'),
                  value: enabled,
                  onChanged: (v) => setDialog(() => enabled = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    delayCtrl.dispose();
    if (ok != true) return;
    final parsed = int.tryParse(delayCtrl.text.trim()) ?? 0;
    setState(() {
      t.delayMs = parsed;
      t.enabled = enabled;
    });
  }

  /// 未指派轨道组（表格底部）。
  Widget _poolGroup(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '未指派轨道（${_pool.length}）— 选择目标视频',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          for (final t in _pool)
            Row(
              children: [
                const SizedBox(width: 24 + 36),
                Icon(_typeIcon(t.type), size: 16, color: _typeColorOf(t)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p.basename(t.path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, fontStyle: FontStyle.italic),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '指派给视频',
                  icon: Icon(Icons.assignment_add,
                      size: 17, color: scheme.primary),
                  enabled: _videos.isNotEmpty,
                  onSelected: (v) => _assignPoolTrack(t, v),
                  itemBuilder: (_) => [
                    for (final v in _videos)
                      PopupMenuItem(
                        value: v,
                        child: Text(p.basename(v),
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                  ],
                ),
                IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.close, size: 15),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _pool.remove(t)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  void _addFromPoolMenu(String video) {
    if (_pool.isEmpty) {
      showErrorSnack(context, '未指派池为空，请先添加字幕 / 音频 / 附件文件');
      return;
    }
    final selected = showModalBottomSheet<MuxTrack>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('选择要指派的轨道'),
            ),
            for (final t in _pool)
              ListTile(
                dense: true,
                leading: Icon(_typeIcon(t.type), size: 20),
                title: Text(p.basename(t.path),
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text(t.type.label,
                    style: const TextStyle(fontSize: 11)),
                onTap: () => Navigator.of(context).pop(t),
              ),
          ],
        ),
      ),
    );
    selected.then((t) {
      if (t != null) _assignPoolTrack(t, video);
    });
  }

  // ── 区 3：操作栏（MKVToolNix 顶部「开始混流」+ 作业选项区） ──

  Widget _actionBar(ColorScheme scheme, bool mkvReady) {
    final ready = _ready.length;
    final status = _videos.isEmpty
        ? '添加视频与轨道后开始封装'
        : ready == 0
            ? '尚无就绪任务：至少为一个视频指派启用的轨道'
            : '$ready 个任务就绪 → MKV（视频与保留音轨流拷贝，不重编码）';
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        color: scheme.surface,
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(200, 44),
            ),
            onPressed: mkvReady && ready > 0 ? _start : null,
            icon: const Icon(Icons.merge_type),
            label: Text('开始封装（$ready 个任务 → MKV）'),
          ),
        ],
      ),
    );
  }

  void _showRulesDialog(ColorScheme scheme) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('封装说明'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in const [
              '唯一后端 mkvmerge：视频 / 源音轨 / 新增轨道全部流拷贝，不重编码',
              '源轨道逐条勾选：音轨 / 内嵌字幕可选保留，源章节可开关',
              '新增轨道逐轨可调：语言（ISO 639-2）、轨道名称、默认轨、'
                  '强制轨（字幕）',
              'ASS 字幕样式 / 特效完整保留；字体附件按原始文件名写入',
              '输出固定 MKV 容器；默认输出到源文件所在目录，可锁定统一目录',
              '同名轨道自动配对，其余在未指派池手动指派',
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.done, size: 12, color: scheme.primary),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(line, style: const TextStyle(fontSize: 13))),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  String _metaOf(MkvFileInfo info) {
    final video = info.tracks.where((t) => t.type == 'video').toList();
    final audio = info.tracks.where((t) => t.type == 'audio').length;
    final sub = info.tracks.where((t) => t.type == 'subtitle').length;
    final res = video.isEmpty
        ? null
        : video.first.pixelWidth != null && video.first.pixelHeight != null
            ? '${video.first.pixelWidth}x${video.first.pixelHeight}'
            : null;
    final parts = [
      if (res != null) res,
      if (info.duration > Duration.zero) formatClock(info.duration),
      if (audio > 0) '音轨 $audio',
      if (sub > 0) '字幕 $sub',
    ];
    return parts.isEmpty ? '已解析' : parts.join(' · ');
  }

  static IconData _typeIcon(MuxTrackType type) => switch (type) {
        MuxTrackType.subtitle => Icons.subtitles_outlined,
        MuxTrackType.audio => Icons.graphic_eq,
        MuxTrackType.attachment => Icons.font_download_outlined,
      };

  Color _typeColorOf(MuxTrack t) => switch (t.type) {
        MuxTrackType.subtitle => _typeColor('subtitle'),
        MuxTrackType.audio => _typeColor('audio'),
        MuxTrackType.attachment => _typeColor('attachment'),
      };

  /// 类型主色（与提取页一致：Material 400 阶，明暗主题均可读）。
  static Color _typeColor(String type) => switch (type) {
        'video' => const Color(0xFF42A5F5),
        'audio' => const Color(0xFF26A69A),
        'subtitle' => const Color(0xFFFFA000),
        'attachment' => const Color(0xFFAB47BC),
        _ => const Color(0xFF78909C),
      };
}

/// 紧凑分区容器（与提取页同款，gMKV/MKVToolNix GroupBox 的 Material 对应物）。
class _Zone extends StatelessWidget {
  final String label;
  final Widget child;
  final Widget? trailing;
  final IconData? icon;
  final bool expand;

  const _Zone({
    required this.label,
    required this.child,
    this.trailing,
    this.icon,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 8),
            if (expand) Expanded(child: child) else child,
          ],
        ),
      ),
    );
  }
}
