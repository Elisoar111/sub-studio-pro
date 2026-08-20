import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/utils/gmkv_extract_namer.dart';
import '../core/utils/time_format.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../services/file_service.dart';
import '../services/mkvtoolnix/mkvtoolnix_service.dart';
import '../services/queue_service.dart';
import '../widgets/common.dart';
import '../widgets/file_drop_zone.dart';
import 'task_queue_screen.dart';

/// 轨道提取页（对齐 gMKVExtractGUI v2.15 核心能力，纯 MKVToolNix 工具链）：
/// - mkvmerge -J 解析全部轨道：视频 / 音频 / 字幕 / 附件（字体）、
///   章节 / 标签伪轨道，列表展示类型、Track ID、编码、语言、标题
/// - 提取一律 mkvextract 流拷贝不重编码：
///   文本字幕按源格式 UTF-8 输出；PGS→.sup、VobSub→.sub/.idx 可直接提取；
///   附件按容器内原始文件名落盘；章节/标签导出 XML
/// - 非 MKV/WebM 输入先由 mkvmerge 无损转封为临时 MKV 再提取
/// - 输出文件名固定按 gMKVExtractGUI v2.15 默认规则（GmkvExtractNamer，
///   无模板）：`{名}_track{序号}_[{语言}].{扩展}`，音频另带
///   `_DELAY {相对视频轨延迟}ms`；章节 / 标签为 `_chapters.xml` / `_tags.xml`
///
/// 布局复刻 gMKVExtractGUI 主窗体（frmMain 固定五区，轨道列表为弹性中心）：
/// 输入文件 → 输出目录（锁定开关）→ 轨道信息（segment 概要 + 勾选列表）
/// → 底部操作栏；轨道行沿用 gMKVTrack.ToString 的方括号格式。
class ExtractScreen extends StatefulWidget {
  /// 嵌入轨道处理合并页时不带 AppBar（由外层提供标题与页签）
  final bool embedded;

  const ExtractScreen({super.key, this.embedded = false});

  @override
  State<ExtractScreen> createState() => _ExtractScreenState();
}

/// 选中轨道的运行时表示（视频键 + mkvmerge -J 轨道信息）。
class _SelectedTrack {
  final String videoPath;

  /// mkvmerge 轨道/附件 ID；伪轨道：章节 = -1，标签 = -2
  final int trackId;

  /// mkvmerge -J `track_number`（1-based 全局序号，gMKV 命名用）
  final int number;

  /// video/audio/subtitle/attachment/chapters/tags
  final String type;

  /// 该轨在同类型中的序号（非 MKV 转封后重定位 ID 用）
  final int typeOrdinal;

  final String codec;
  final String codecId;
  final String language;
  final String title;
  final String filename; // 附件容器内文件名
  final bool forced;
  final int? channels;
  final int? samplingRate;
  final int? pixelWidth;
  final int? pixelHeight;

  /// mkvmerge -J `minimum_timestamp`（纳秒，音频 DELAY 命名用）
  final int? minTimestampNs;

  const _SelectedTrack({
    required this.videoPath,
    required this.trackId,
    required this.type,
    required this.typeOrdinal,
    required this.codec,
    this.number = 0,
    this.codecId = '',
    this.language = '',
    this.title = '',
    this.filename = '',
    this.forced = false,
    this.channels,
    this.samplingRate,
    this.pixelWidth,
    this.pixelHeight,
    this.minTimestampNs,
  });
}

class _ExtractScreenState extends State<ExtractScreen> {
  final List<String> _videos = [];

  /// 全部视频的 mkvmerge -J 分析结果（gMKVExtractGUI 同款工具链）
  final Map<String, MkvFileInfo> _mkvInfo = {};

  /// mkvmerge 无法解析的文件（格式不支持 / 损坏）
  final Set<String> _unreadable = {};

  /// 进行中的探测数（并发探测时布尔会提前熄灭，计数才能正确门控 _start）
  int _pendingProbes = 0;

  /// 选中的轨道（key = videoPath|trackId）
  final Map<String, _SelectedTrack> _selected = {};

  /// 轨道列表当前展示的文件（gMKV 为单文件工作流，此处是其多数文件扩展：
  /// 多个文件通过顶部文件条切换，勾选状态跨文件保留）
  String? _activeVideo;

  /// 锁定的输出目录（gMKV chkLockOutputDirectory 语义）：
  /// null = 未锁定，各视频输出到其所在目录；非 null = 全部输出到该目录
  String? _outputDir;

  bool get _mkvReady => MkvToolNixService.instance.isAvailable;

  /// 当前展示的文件（自愈：失效时回退到首个）
  String? get _active {
    if (_activeVideo != null && _videos.contains(_activeVideo)) {
      return _activeVideo;
    }
    return _videos.isEmpty ? null : _videos.first;
  }

  /// 输出目录：锁定目录 > 各视频所在目录 > 应用文档目录兜底。
  Future<String> _resolveOutDir(String videoPath) async {
    final task = _outputDir;
    if (task != null) return task;
    final dir = p.dirname(videoPath);
    if (dir.isNotEmpty) return dir;
    return FileService.instance.outputDirFor(AppConstants.dirExtract);
  }

  void _handleDroppedFiles(List<String> paths) {
    final newPaths = paths
        .where((path) => !_videos.contains(path))
        .toList();
    if (newPaths.isEmpty) return;
    setState(() {
      _videos.addAll(newPaths);
      _activeVideo ??= newPaths.first;
    });
    for (final path in newPaths) {
      _probe(path);
    }
  }

  Future<void> _pickVideos() async {
    try {
      await FileService.instance.ensureStoragePermissions();
      final picked = await FileService.instance.pickVideos();
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final path = f.path;
          if (path != null && !_videos.contains(path)) _videos.add(path);
        }
        _activeVideo ??= picked.first.path;
      });
      for (final f in picked) {
        _probe(f.path);
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _pickOutputDir() async {
    try {
      final dir = await FileService.instance.pickDirectory();
      if (dir == null || !mounted) return;
      setState(() => _outputDir = dir);
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
      // 分析一律走 mkvmerge -J：轨道 ID / 附件文件名 / 章节标签全量权威
      final fi = await MkvToolNixService.instance.probe(path);
      if (!mounted) return;
      setState(() {
        if (fi != null) {
          _mkvInfo[path] = fi;
        } else {
          _unreadable.add(path);
        }
      });
    } finally {
      if (mounted) setState(() => _pendingProbes--);
    }
  }

  void _removeVideo(String v) {
    setState(() {
      _videos.remove(v);
      _mkvInfo.remove(v);
      _unreadable.remove(v);
      _selected.removeWhere((k, _) => k.startsWith('$v|'));
      if (_activeVideo == v) _activeVideo = null;
    });
  }

  // ───────────────────────── 轨道选择 ─────────────────────────

  List<_SelectedTrack> _allTracksOf(String video) {
    final info = _mkvInfo[video];
    if (info == null) return const [];
    final out = <_SelectedTrack>[];
    var vi = 0, ai = 0, si = 0, ati = 0;
    for (final t in info.tracks.where((t) => t.type == 'video')) {
      out.add(_SelectedTrack(
        videoPath: video,
        trackId: t.id,
        number: t.number,
        type: 'video',
        typeOrdinal: vi++,
        codec: t.codec,
        codecId: t.codecId,
        forced: t.forcedTrack,
        pixelWidth: t.pixelWidth,
        pixelHeight: t.pixelHeight,
        minTimestampNs: t.minTimestampNs,
      ));
    }
    for (final t in info.tracks.where((t) => t.type == 'audio')) {
      out.add(_SelectedTrack(
        videoPath: video,
        trackId: t.id,
        number: t.number,
        type: 'audio',
        typeOrdinal: ai++,
        codec: t.codec,
        codecId: t.codecId,
        language: t.language,
        title: t.trackName,
        forced: t.forcedTrack,
        channels: t.channels,
        samplingRate: t.samplingRate,
        minTimestampNs: t.minTimestampNs,
      ));
    }
    for (final t in info.tracks.where((t) => t.type == 'subtitle')) {
      out.add(_SelectedTrack(
        videoPath: video,
        trackId: t.id,
        number: t.number,
        type: 'subtitle',
        typeOrdinal: si++,
        codec: t.codec,
        codecId: t.codecId,
        language: t.language,
        title: t.trackName,
        forced: t.forcedTrack,
        minTimestampNs: t.minTimestampNs,
      ));
    }
    for (final a in info.attachments) {
      out.add(_SelectedTrack(
        videoPath: video,
        trackId: a.id,
        type: 'attachment',
        typeOrdinal: ati++,
        codec: a.contentType,
        filename: a.fileName,
      ));
    }
    if (info.hasChapters) {
      out.add(_SelectedTrack(
        videoPath: video,
        trackId: -1,
        type: 'chapters',
        typeOrdinal: 0,
        codec: 'xml',
        title: '章节',
      ));
    }
    if (info.hasTags) {
      out.add(_SelectedTrack(
        videoPath: video,
        trackId: -2,
        type: 'tags',
        typeOrdinal: 0,
        codec: 'xml',
        title: '标签',
      ));
    }
    return out;
  }

  String _keyOf(_SelectedTrack t) => '${t.videoPath}|${t.trackId}';

  void _toggle(_SelectedTrack t) {
    setState(() {
      final k = _keyOf(t);
      if (_selected.containsKey(k)) {
        _selected.remove(k);
      } else {
        _selected[k] = t;
      }
    });
  }

  /// gMKV 右键菜单语义：选择动作作用于当前展示的文件（ chkLstInputFileTracks）。
  void _selectByType(String type) {
    final v = _active;
    if (v == null) return;
    setState(() {
      for (final t in _allTracksOf(v)) {
        if (t.type == type) _selected[_keyOf(t)] = t;
      }
    });
  }

  void _selectAllTracks() {
    final v = _active;
    if (v == null) return;
    setState(() {
      for (final t in _allTracksOf(v)) {
        _selected[_keyOf(t)] = t;
      }
    });
  }

  /// 某类型在当前文件中的（已选/总数），gMKV 菜单同款计数显示。
  (int, int) _countsOf(String type) {
    final v = _active;
    if (v == null) return (0, 0);
    final tracks = _allTracksOf(v).where((t) => t.type == type);
    var sel = 0, total = 0;
    for (final t in tracks) {
      total++;
      if (_selected.containsKey(_keyOf(t))) sel++;
    }
    return (sel, total);
  }

  // ───────────────────────── 输出文件名 ─────────────────────────

  /// 每个视频首条视频轨的 minimum_timestamp（音频 DELAY 命名基准）。
  int? _videoMinTsOf(String video) {
    final info = _mkvInfo[video];
    if (info == null) return null;
    for (final t in info.tracks) {
      if (t.type == 'video') return t.minTimestampNs;
    }
    return null;
  }

  /// 音轨相对视频轨的有效延迟（ms）。
  int _delayOf(_SelectedTrack t) => GmkvExtractNamer.effectiveDelayMs(
        trackMinTsNs: t.minTimestampNs,
        videoMinTsNs: _videoMinTsOf(t.videoPath),
      );

  /// 渲染输出文件名：gMKVExtractGUI v2.15 默认规则（GmkvExtractNamer）。
  String _renderName(_SelectedTrack t) {
    switch (t.type) {
      case 'attachment':
        return GmkvExtractNamer.attachmentFilename(t.filename, id: t.trackId);
      case 'chapters':
        return GmkvExtractNamer.chaptersFilename(t.videoPath);
      case 'tags':
        return GmkvExtractNamer.tagsFilename(t.videoPath);
      default:
        return GmkvExtractNamer.trackFilename(
          sourcePath: t.videoPath,
          trackNumber: t.number,
          language: t.language,
          codecId: t.codecId,
          kind: t.type,
          effectiveDelayMs: t.type == 'audio' ? _delayOf(t) : 0,
        );
    }
  }

  // ───────────────────────── 任务构建 ─────────────────────────

  Future<void> _start() async {
    if (!_mkvReady) {
      showErrorSnack(context, '未检测到 MKVToolNix：请在「设置 → MKVToolNix」'
          '配置安装目录或导入工具');
      return;
    }
    if (_selected.isEmpty) {
      showErrorSnack(context, '请先勾选要提取的轨道');
      return;
    }
    if (_pendingProbes > 0) {
      showErrorSnack(context, '正在解析轨道信息，请稍候');
      return;
    }
    final q = QueueService.instance;
    final used = <String>{};
    for (final t in _selected.values) {
      final outDir = await _resolveOutDir(t.videoPath);
      var name = _renderName(t);
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
      final typeLabel = _typeLabel(t.type);
      q.addTask(
        type: TaskType.extract,
        title: '提取 ${p.basename(t.videoPath)} '
            '$typeLabel${t.trackId >= 0 ? '轨#${t.trackId}' : ''}',
        params: {
          TaskParams.videoPath: t.videoPath,
          TaskParams.trackType: t.type,
          TaskParams.streamIndex: '${t.trackId}',
          TaskParams.typeOrdinal: '${t.typeOrdinal}',
          TaskParams.outputPath: p.join(outDir, name),
          TaskParams.totalDurationMs:
              '${_mkvInfo[t.videoPath]?.duration.inMilliseconds ?? 0}',
        },
      );
    }
    q.start();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TaskQueueScreen()),
    );
  }

  static String _typeLabel(String type) => switch (type) {
        'video' => '视频',
        'audio' => '音频',
        'subtitle' => '字幕',
        'attachment' => '附件',
        'chapters' => '章节',
        'tags' => '标签',
        _ => type,
      };

  static IconData _typeIcon(String type) => switch (type) {
        'video' => Icons.videocam_outlined,
        'audio' => Icons.graphic_eq,
        'subtitle' => Icons.subtitles_outlined,
        'attachment' => Icons.font_download_outlined,
        'chapters' => Icons.bookmark_outlined,
        'tags' => Icons.label_outlined,
        _ => Icons.description_outlined,
      };

  /// 类型主色（Material 400 阶，明暗主题均可读）。
  static Color _typeColor(String type) => switch (type) {
        'video' => const Color(0xFF42A5F5),
        'audio' => const Color(0xFF26A69A),
        'subtitle' => const Color(0xFFFFA000),
        'attachment' => const Color(0xFFAB47BC),
        'chapters' => const Color(0xFF5C6BC0),
        'tags' => const Color(0xFF78909C),
        _ => const Color(0xFF78909C),
      };

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 监听可用性：设置页配置/导入 MKVToolNix 后立即刷新（本页位于
    // IndexedStack 中，路由返回不会触发重建）
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
                  _outputZone(scheme),
                  const SizedBox(height: 10),
                  Expanded(child: _tracksZone(scheme, mkvReady)),
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
            appBar: AppBar(title: const Text('轨道提取')),
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

  // ── 区 1：输入文件（gMKV grpInputFile，多文件以文件条扩展） ──

  Widget _inputZone(ColorScheme scheme, bool mkvReady) {
    return _Zone(
      label: '输入文件',
      icon: Icons.movie_filter_outlined,
      trailing: TextButton.icon(
        onPressed: mkvReady ? _pickVideos : null,
        icon: const Icon(Icons.add, size: 16),
        label: const Text('选择视频'),
      ),
      child: _videos.isEmpty
          ? Text(
              '选择视频后自动解析全部轨道（视频 / 音频 / 字幕 / 附件字体 / 章节 / 标签），'
              '全部流拷贝不重编码',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            )
          : Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in _videos) _fileChip(v),
              ],
            ),
    );
  }

  Widget _fileChip(String v) {
    final scheme = Theme.of(context).colorScheme;
    final active = _active == v;
    final unreadable = _unreadable.contains(v);
    final parsed = _mkvInfo.containsKey(v);
    return InputChip(
      selected: active,
      onSelected: (_) => setState(() => _activeVideo = v),
      onDeleted: () => _removeVideo(v),
      deleteButtonTooltipMessage: '移除该文件',
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

  // ── 区 2：输出目录（gMKV grpOutputDirectory + chkLockOutputDirectory） ──

  Widget _outputZone(ColorScheme scheme) {
    final locked = _outputDir != null;
    return _Zone(
      label: '输出目录',
      icon: Icons.folder_outlined,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: locked
                ? () => setState(() => _outputDir = null)
                : _pickOutputDir,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: Checkbox(
                      value: locked,
                      onChanged: (v) =>
                          v == true ? _pickOutputDir() : setState(() => _outputDir = null),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('锁定到该目录',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          OutlinedButton(
            onPressed: _pickOutputDir,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('浏览…'),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            locked ? Icons.lock_outline : Icons.lock_open,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              locked
                  ? _outputDir!
                  : '未锁定 — 每个视频输出到其所在目录（gMKVExtractGUI 默认行为）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: locked ? null : scheme.onSurfaceVariant,
                    fontFamily: 'Consolas',
                  ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 区 3：轨道信息（gMKV grpInputFileInfo，弹性中心） ──

  Widget _tracksZone(ColorScheme scheme, bool mkvReady) {
    final v = _active;
    final info = v == null ? null : _mkvInfo[v];
    final tracks = v == null ? const <_SelectedTrack>[] : _allTracksOf(v);
    return _Zone(
      label: '轨道信息（${tracks.length} 轨道 · 已选 ${_selected.length}）',
      icon: Icons.format_list_bulleted,
      expand: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '命名与提取规则',
            icon: Icon(Icons.info_outline,
                size: 18, color: scheme.onSurfaceVariant),
            onPressed: () => _showRulesDialog(scheme),
          ),
          PopupMenuButton<String>(
            tooltip: '批量选择',
            icon: Icon(Icons.checklist, size: 18, color: scheme.onSurfaceVariant),
            enabled: v != null && tracks.isNotEmpty,
            onSelected: (op) => switch (op) {
              'all' => _selectAllTracks(),
              'none' => setState(_selected.clear),
              _ => _selectByType(op),
            },
            itemBuilder: (_) => _selectionMenuItems(),
          ),
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => setState(_selected.clear),
            child: const Text('清空选择'),
          ),
        ],
      ),
      child: Column(
        children: [
          // Flexible 松弛：极小窗口槽位不足时收缩而非溢出
          if (v != null) Flexible(child: _segmentStrip(scheme, v, info)),
          Expanded(child: _trackListBody(scheme, v, info, tracks)),
        ],
      ),
    );
  }

  List<PopupMenuEntry<String>> _selectionMenuItems() {
    PopupMenuItem<String> item(String op, IconData icon, Color color,
        String label, (int, int) counts) {
      final (sel, total) = counts;
      return PopupMenuItem(
        value: op,
        enabled: total > 0,
        child: Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(label)),
            Text('$sel/$total',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      );
    }

    final activeTracks = _active == null
        ? const <_SelectedTrack>[]
        : _allTracksOf(_active!);
    final selInActive =
        activeTracks.where((t) => _selected.containsKey(_keyOf(t))).length;
    return [
      item('all', Icons.select_all, Theme.of(context).colorScheme.primary,
          '全部轨道', (selInActive, activeTracks.length)),
      const PopupMenuDivider(),
      item('video', Icons.videocam_outlined, _typeColor('video'), '视频轨',
          _countsOf('video')),
      item('audio', Icons.graphic_eq, _typeColor('audio'), '音频轨',
          _countsOf('audio')),
      item('subtitle', Icons.subtitles_outlined, _typeColor('subtitle'),
          '字幕轨', _countsOf('subtitle')),
      item('chapters', Icons.bookmark_outlined, _typeColor('chapters'), '章节',
          _countsOf('chapters')),
      item('attachment', Icons.font_download_outlined, _typeColor('attachment'),
          '附件轨', _countsOf('attachment')),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(
        value: 'none',
        child: Row(
          children: [
            Icon(Icons.deselect, size: 16),
            SizedBox(width: 10),
            Expanded(child: Text('取消全选')),
          ],
        ),
      ),
    ];
  }

  /// gMKV txtSegmentInfo：文件级概要单行条。
  Widget _segmentStrip(ColorScheme scheme, String v, MkvFileInfo? info) {
    final unreadable = _unreadable.contains(v);
    String text;
    if (unreadable) {
      text = '无法解析：mkvmerge 不支持该格式或文件已损坏';
    } else if (info == null) {
      text = '正在解析轨道信息…';
    } else {
      final video = info.tracks.where((t) => t.type == 'video').length;
      final audio = info.tracks.where((t) => t.type == 'audio').length;
      final sub = info.tracks.where((t) => t.type == 'subtitle').length;
      final parts = [
        'MKV',
        if (info.duration > Duration.zero) '时长 ${formatClock(info.duration)}',
        if (video > 0) '视频 $video',
        if (audio > 0) '音频 $audio',
        if (sub > 0) '字幕 $sub',
        if (info.attachments.isNotEmpty) '附件 ${info.attachments.length}',
        if (info.hasChapters) '章节',
        if (info.hasTags) '标签',
      ];
      text = parts.join(' · ');
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: unreadable
            ? scheme.errorContainer.withValues(alpha: 0.35)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: unreadable ? scheme.onErrorContainer : null,
              fontFamily: 'Consolas',
            ),
      ),
    );
  }

  Widget _trackListBody(
    ColorScheme scheme,
    String? v,
    MkvFileInfo? info,
    List<_SelectedTrack> tracks,
  ) {
    if (v == null) {
      return EmptyState(
        icon: Icons.movie_filter_outlined,
        message: '选择视频后自动解析全部轨道\n勾选需要的轨道批量提取，全部流拷贝不重编码',
        action: FilledButton.tonalIcon(
          onPressed: _mkvReady ? _pickVideos : null,
          icon: const Icon(Icons.add),
          label: const Text('选择视频'),
        ),
      );
    }
    if (_unreadable.contains(v)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined,
                size: 40, color: scheme.error.withValues(alpha: 0.7)),
            const SizedBox(height: 8),
            Text('mkvmerge 无法解析该文件（格式不支持或已损坏）',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (info == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(height: 10),
            Text('正在解析轨道…',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    if (tracks.isEmpty) {
      return Center(
        child: Text('该文件没有可提取的轨道',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
      );
    }
    return Scrollbar(
      child: ListView.builder(
        itemCount: tracks.length,
        itemBuilder: (_, i) => _trackRow(scheme, tracks[i]),
      ),
    );
  }

  /// 单条轨道行：gMKVTrack.ToString 方括号格式（等宽字体），
  /// 勾选后右侧实时显示按 gMKV 规则生成的输出文件名。
  Widget _trackRow(ColorScheme scheme, _SelectedTrack t) {
    final checked = _selected.containsKey(_keyOf(t));
    final color = _typeColor(t.type);
    return InkWell(
      onTap: () => _toggle(t),
      child: Container(
        color: checked ? scheme.primary.withValues(alpha: 0.07) : null,
        padding: const EdgeInsets.only(left: 6, right: 10),
        constraints: const BoxConstraints(minHeight: 34),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              height: 34,
              child: Checkbox(
                value: checked,
                onChanged: (_) => _toggle(t),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            Icon(_typeIcon(t.type), size: 16, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _trackDisplay(t),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 12.5,
                  height: 1.25,
                ),
              ),
            ),
            if (checked) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  _renderName(t),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 12.5,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// gMKVTrack.ToString() 复刻：
  /// `Track {N} [TID {id}][类型][CodecID][名称][语言][FORCED][附加信息][延迟]`
  String _trackDisplay(_SelectedTrack t) {
    switch (t.type) {
      case 'attachment':
        final b = StringBuffer('附件 [ID ${t.trackId}][${t.filename}]');
        if (t.codec.isNotEmpty) b.write('[${t.codec}]');
        return b.toString();
      case 'chapters':
        return '章节 [导出 XML]';
      case 'tags':
        return '标签 [导出 XML]';
      default:
        final b = StringBuffer(
            'Track ${t.number} [TID ${t.trackId}][${_typeLabel(t.type)}][${t.codecId}]');
        if (t.title.isNotEmpty) b.write('[${t.title}]');
        if (t.language.isNotEmpty) b.write('[${t.language}]');
        if (t.forced) b.write('[FORCED]');
        final extra = _extraInfoOf(t);
        if (extra != null) b.write('[$extra]');
        if (t.type == 'audio') {
          final d = _delayOf(t);
          b.write('[延迟 $d ms]');
        }
        return b.toString();
    }
  }

  String? _extraInfoOf(_SelectedTrack t) {
    if (t.type == 'video' &&
        t.pixelWidth != null &&
        t.pixelHeight != null) {
      return '${t.pixelWidth}x${t.pixelHeight}';
    }
    if (t.type == 'audio') {
      final ch = t.channels == null ? '' : '${t.channels}ch';
      final hz =
          t.samplingRate == null ? '' : '${t.samplingRate! ~/ 1000}kHz';
      final s = [ch, hz].where((e) => e.isNotEmpty).join(' ');
      return s.isEmpty ? null : s;
    }
    return null;
  }

  void _showRulesDialog(ColorScheme scheme) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('命名与提取规则'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in const [
              '全部轨道流拷贝不重编码（mkvextract，gMKVExtractGUI v2.15 同款工具链）',
              '输出文件名按 gMKVExtractGUI 默认规则：{名}_track{序号}_[{语言}].{扩展}',
              '音轨另带 _DELAY {相对视频轨延迟}ms；章节 / 标签为 _chapters.xml / _tags.xml',
              '文本字幕按源格式输出（MKV 内部即 UTF-8）；PGS→.sup、VobSub→.sub/.idx',
              '视频轨输出为裸基本流（AVC→.avc、HEVC→.hevc、VP8/9→.ivf、AV1→.av1）',
              '附件（字体）按容器内原始文件名落盘',
              '非 MKV/WebM 输入会先无损转封为临时 MKV 再提取，完成后自动清理',
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
                    Expanded(child: Text(line, style: const TextStyle(fontSize: 13))),
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

  // ── 区 4：操作栏（gMKV grpActions + 状态条） ──

  Widget _actionBar(ColorScheme scheme, bool mkvReady) {
    final locked = _outputDir != null;
    final status = _selected.isEmpty
        ? '勾选上方轨道，输出文件名将实时显示在所选行'
        : '已选 ${_selected.length} 条轨道 → ${locked ? _outputDir : '各视频所在目录'}';
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
            onPressed:
                !mkvReady || _selected.isEmpty || _pendingProbes > 0
                    ? null
                    : _start,
            icon: const Icon(Icons.file_download_outlined),
            label: Text('开始提取（${_selected.length} 条轨道）'),
          ),
        ],
      ),
    );
  }
}

/// 紧凑分区容器（gMKV GroupBox 的 Material 对应物）。
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
