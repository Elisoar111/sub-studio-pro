import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/utils/filename_template.dart';
import '../core/utils/subtitle_matcher.dart';
import '../core/utils/time_format.dart';
import '../models/encode_options.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../models/video_info.dart';
import '../providers/app_providers.dart';
import '../services/concurrent_probe_pool.dart';
import '../services/file_service.dart';
import '../services/ffmpeg/ffmpeg_service.dart';
import '../services/queue_service.dart';
import '../widgets/common.dart';
import '../widgets/file_drop_zone.dart';
import '../widgets/encode_settings_panel.dart';
import '../widgets/output_settings_card.dart';
import 'task_queue_screen.dart';

/// 字幕烧录页：外部字幕 / 内嵌字幕轨两种模式，批量烧录。
class BurnScreen extends StatefulWidget {
  final List<PickedFile> initialVideos;
  final List<PickedFile> initialSubtitles;

  const BurnScreen({
    super.key,
    this.initialVideos = const [],
    this.initialSubtitles = const [],
  });

  @override
  State<BurnScreen> createState() => _BurnScreenState();
}

class _BurnScreenState extends State<BurnScreen> {
  final List<PickedFile> _videos = [];
  final List<PickedFile> _subtitles = [];
  final Map<String, VideoInfo> _info = {};

  /// 每个视频选中的字幕轨（存「字幕流序号」= subtitleStreams 列表下标，
  /// 对应 FFmpeg 的 `-map 0:s:N` 的 N）。
  final Map<String, int> _trackSel = {};

  bool _embeddedMode = false;
  String _stylePreset = '默认白字黑边';
  String? _fontsDir;

  /// 进行中的探测数（并发探测时布尔会提前熄灭，计数才能正确门控 _start）
  int _pendingProbes = 0;

  /// 自定义输出目录（null = 全局默认 / 应用目录）
  String? _outputDir;

  /// 文件名模板（空 = 全局默认 / 内置默认）
  String _template = '';

  String _dirLabel = '默认（应用文档目录/burn）';

  final _encodeKey = GlobalKey<EncodeSettingsPanelState>();

  String _keyOf(PickedFile f) => f.path ?? 'web:${f.name}';

  @override
  void initState() {
    super.initState();
    _template = SettingsProvider.instance.filenameTemplate;
    final global = SettingsProvider.instance.defaultOutputDir;
    if (global.isNotEmpty) _dirLabel = global;
    _videos.addAll(widget.initialVideos);
    _subtitles.addAll(widget.initialSubtitles);
    _probeBatch(_videos.whereType<PickedFile>().toList());
  }

  /// 并发探测一批文件（limit=3），结果直接写 _info / _trackSel。
  void _probeBatch(List<PickedFile> files) {
    if (files.isEmpty) return;
    final toProbe = files.where((f) => f.path != null && !_info.containsKey(_keyOf(f))).toList();
    if (toProbe.isEmpty) return;
    setState(() => _pendingProbes += toProbe.length);
    ConcurrentProbePool(limit: 3).run(
      toProbe,
      (f) async => FfmpegService.instance.probeVideo(f.path!),
      (f, info) {
        if (!mounted) return;
        setState(() {
          _info[_keyOf(f)] = info;
          _trackSel[_keyOf(f)] ??= 0;
        });
      },
      onError: (f, e) {
        if (!mounted) return;
        setState(() {
          _info[_keyOf(f)] = VideoInfo.unknown(f.path!);
          showErrorSnack(context, '探测 ${f.name} 失败：$e');
        });
      },
    ).whenComplete(() {
      if (mounted) setState(() => _pendingProbes = 0);
    });
  }

  /// 解析输出目录：任务级 > 全局默认 > 应用子目录。
  Future<String> _resolveOutDir() async {
    final task = _outputDir;
    if (task != null) return task;
    final global = SettingsProvider.instance.defaultOutputDir;
    if (global.isNotEmpty) return global;
    return FileService.instance.outputDirFor(AppConstants.dirBurn);
  }

  // ───────────────────────── 选择 ─────────────────────────

  void _handleDroppedFiles(List<String> paths) {
    final videos = <PickedFile>[];
    final subtitles = <PickedFile>[];
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      final extNoDot = ext.isEmpty ? '' : ext.substring(1);
      if (AppConstants.videoExtensions.contains(extNoDot)) {
        final f = FileService.pickedFromFile(path);
        if (!_videos.any((x) => _keyOf(x) == _keyOf(f))) videos.add(f);
      } else if (AppConstants.subtitleExtensions.contains(extNoDot)) {
        final f = FileService.pickedFromFile(path);
        if (!_subtitles.any((x) => _keyOf(x) == _keyOf(f))) subtitles.add(f);
      }
    }
    if (videos.isEmpty && subtitles.isEmpty) return;
    setState(() {
      _videos.addAll(videos);
      _subtitles.addAll(subtitles);
    });
    _probeBatch(videos);
  }

  Future<void> _pickVideos() async {
    try {
      await FileService.instance.ensureStoragePermissions();
      final picked = await FileService.instance.pickVideos();
      if (picked.isEmpty || !mounted) return;
      final newVideos = picked
          .where((f) => !_videos.any((x) => _keyOf(x) == _keyOf(f)))
          .toList();
      setState(() {
        _videos.addAll(newVideos);
      });
      _probeBatch(newVideos);
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _pickSubtitles() async {
    try {
      final picked = await FileService.instance.pickSubtitles();
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final k = _keyOf(f);
          if (!_subtitles.any((x) => _keyOf(x) == k)) _subtitles.add(f);
        }
      });
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _pickFontsDir() async {
    final dir = await FileService.instance.pickDirectory();
    if (dir != null && mounted) {
      setState(() => _fontsDir = dir);
    }
  }

  // ───────────────────────── 任务构建 ─────────────────────────

  String _uniqueOutPath(
      String outDir, String videoPath, String container, Set<String> used) {
    var name = FilenameTemplate.render(
      _template,
      sourceName: p.basename(videoPath),
      extension: container,
      container: container,
    );
    var i = 2;
    while (used.contains(name.toLowerCase()) ||
        File(p.join(outDir, name)).existsSync()) {
      final dot = name.lastIndexOf('.');
      name = dot > 0
          ? '${name.substring(0, dot)}_$i${name.substring(dot)}'
          : '${name}_$i';
      i++;
    }
    return name;
  }

  Future<void> _start() async {
    final q = QueueService.instance;
    if (_videos.isEmpty) {
      showErrorSnack(context, '请先选择视频文件');
      return;
    }
    if (_pendingProbes > 0) {
      showErrorSnack(context, '正在探测视频信息，请稍候再开始');
      return;
    }
    final encode =
        _encodeKey.currentState?.options ?? const VideoEncodeOptions();
    final useAss = kBurnStylePresets[_stylePreset] == null;
    final forceStyle = kBurnStylePresets[_stylePreset];
    final outDir = await _resolveOutDir();
    final used = <String>{};
    var count = 0;

    if (_embeddedMode) {
      // ── 模式 2：内嵌字幕轨烧录 ──
      for (final v in _videos) {
        final key = _keyOf(v);
        final info = _info[key];
        final streams = info?.subtitleStreams ?? const <SubtitleStreamInfo>[];
        if (streams.isEmpty || v.path == null) continue;
        final ordinal = _trackSel[key] ?? 0;
        final name =
            _uniqueOutPath(outDir, v.path!, encode.container, used);
        used.add(name.toLowerCase());
        final out = p.join(outDir, name);
        q.addTask(
          type: TaskType.burn,
          title: '烧录 ${p.basename(v.path!)}（内嵌轨）',
          params: {
            ...encode.toParams(),
            TaskParams.videoPath: v.path!,
            TaskParams.trackIndex: '$ordinal',
            TaskParams.outputPath: out,
            TaskParams.useAssFilter: useAss.toString(),
            if (forceStyle != null) TaskParams.forceStyle: forceStyle,
            if (_fontsDir != null) TaskParams.fontsDir: _fontsDir!,
            TaskParams.totalDurationMs:
                '${info?.duration.inMilliseconds ?? 0}',
          },
        );
        count++;
      }
    } else {
      // ── 模式 1：外部字幕文件烧录（自动匹配）──
      final videos =
          _videos.map((f) => f.path).whereType<String>().toList();
      final subs =
          _subtitles.map((f) => f.path).whereType<String>().toList();
      final match = matchSubtitlePairs(videos, subs);
      for (final (video, subtitle) in match.pairs) {
        final name = _uniqueOutPath(outDir, video, encode.container, used);
        used.add(name.toLowerCase());
        final out = p.join(outDir, name);
        q.addTask(
          type: TaskType.burn,
          title: '烧录 ${p.basename(video)}',
          params: {
            ...encode.toParams(),
            TaskParams.videoPath: video,
            TaskParams.subtitlePath: subtitle,
            TaskParams.outputPath: out,
            TaskParams.useAssFilter: useAss.toString(),
            if (forceStyle != null) TaskParams.forceStyle: forceStyle,
            if (_fontsDir != null) TaskParams.fontsDir: _fontsDir!,
            TaskParams.totalDurationMs:
                '${_info[video]?.duration.inMilliseconds ?? 0}',
          },
        );
        count++;
      }
      if (match.unmatchedVideos.isNotEmpty ||
          match.unmatchedSubtitles.isNotEmpty) {
        final warn = <String>[
          if (match.unmatchedVideos.isNotEmpty)
            '未匹配到字幕的视频：${match.unmatchedVideos.map(p.basename).join('、')}',
          if (match.unmatchedSubtitles.isNotEmpty)
            '未匹配到视频的字幕：${match.unmatchedSubtitles.map(p.basename).join('、')}',
        ].join('；');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(warn)),
          );
        }
      }
    }

    if (count == 0) {
      if (mounted) {
        showErrorSnack(
            context, _embeddedMode ? '所选视频没有内嵌字幕轨' : '没有可烧录的配对');
      }
      return;
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
    final pairCount = _embeddedMode
        ? _videos
            .where((v) => (_info[_keyOf(v)]?.subtitleStreams ?? const []).isNotEmpty)
            .length
        : matchSubtitlePairs(
                _videos.map((f) => f.path).whereType<String>().toList(),
                _subtitles.map((f) => f.path).whereType<String>().toList())
            .pairs
            .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('字幕烧录'),
      ),
      body: FileDropZone(
        acceptedExtensions: const [
          ...AppConstants.videoExtensions,
          ...AppConstants.subtitleExtensions,
        ],
        onFilesDropped: _handleDroppedFiles,
        child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_pendingProbes > 0) ...[
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
          ],
          SectionCard(
            title: '烧录模式',
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('外部字幕文件'),
                  icon: Icon(Icons.upload_file, size: 18),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('内嵌字幕轨'),
                  icon: Icon(Icons.video_library, size: 18),
                ),
              ],
              selected: {_embeddedMode},
              showSelectedIcon: false,
              onSelectionChanged: (s) =>
                  setState(() => _embeddedMode = s.first),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '视频文件（${_videos.length}）',
            trailing: TextButton(
              onPressed: _pickVideos,
              child: const Text('选择视频'),
            ),
            child: _videos.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: StepGuide(steps: [
                      '点击右上「选择视频」，或直接把视频拖进页面',
                      '支持 mp4/mov/mkv/avi/flv/webm，可多选批量',
                      '添加后自动探测时长与分辨率',
                    ]),
                  )
                : Column(
                    children: [
                      for (final v in _videos)
                        _videoTile(v),
                    ],
                  ),
          ),
          if (!_embeddedMode) ...[
            const SizedBox(height: 12),
            SectionCard(
              title: '字幕文件（${_subtitles.length}）',
              trailing: TextButton(
                onPressed: _pickSubtitles,
                child: const Text('选择字幕'),
              ),
              child: _subtitles.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: StepGuide(steps: [
                        '点击右上「选择字幕」（SRT/ASS/SSA）',
                        '或切到「内嵌字幕」直接烧录视频里的字幕轨',
                      ]),
                    )
                  : Column(
                      children: [
                        for (final s in _subtitles)
                          FileTile(
                            title: s.name,
                            icon: Icons.subtitles_outlined,
                            onRemove: () =>
                                setState(() => _subtitles.remove(s)),
                          ),
                      ],
                    ),
            ),
          ],
          const SizedBox(height: 12),
          OutputSettingsCard(
            initialDir: _outputDir,
            onDirChanged: (dir) => setState(() => _outputDir = dir),
            initialTemplate: _template,
            templateFallback: FilenameTemplate.burnDefault,
            onTemplateChanged: (tpl) => _template = tpl,
            defaultDirLabel: _dirLabel,
            previewSourceName:
                _videos.isNotEmpty ? _videos.first.name : null,
            previewExtension: _encodeKey.currentState?.options.container,
            previewContainer: _encodeKey.currentState?.options.container,
          ),
          const SizedBox(height: 12),
          EncodeSettingsPanel(key: _encodeKey, onChanged: (_) {}),
          const SizedBox(height: 12),
          SectionCard(
            title: '字幕样式',
            child: Column(
              children: [
                LabeledDropdown<String>(
                  label: '样式',
                  value: _stylePreset,
                  items: [
                    for (final e in kBurnStylePresets.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.key)),
                  ],
                  onChanged: (v) => setState(() {
                    if (v != null) _stylePreset = v;
                  }),
                ),
                const SizedBox(height: 8),
                Text(
                  '「保留 ASS 原样式」使用 ass 滤镜（完整保留特效）；'
                  '其他样式使用 subtitles 滤镜强制统一样式。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _fontsDir == null
                            ? '字体目录：未指定（用系统字体）'
                            : '字体目录：$_fontsDir',
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: _pickFontsDir,
                      child: const Text('选择字体…'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pendingProbes > 0 ? null : _start,
            icon: const Icon(Icons.local_fire_department),
            label: Text(_embeddedMode
                ? '开始烧录内嵌字幕 ($pairCount)'
                : '开始烧录 ($pairCount)'),
          ),
        ],
        ),
      ),
    );
  }

  Widget _videoTile(PickedFile v) {
    final key = _keyOf(v);
    final info = _info[key];
    final streams = info?.subtitleStreams ?? const <SubtitleStreamInfo>[];
    final first = info?.firstVideo;
    final subtitle = info == null
        ? (v.isWebFile ? '内存文件(Web)，无法探测' : '探测中…')
        : '${first?.resolutionLabel ?? '未知分辨率'} · '
            '${formatClock(info.duration)} · '
            '${formatBytes(info.sizeBytes ?? 0)}'
            '${streams.isNotEmpty ? ' · 内嵌字幕 ${streams.length} 条' : ''}';

    return Column(
      children: [
        FileTile(
          title: v.name,
          subtitle: subtitle,
          icon: Icons.videocam_outlined,
          onRemove: () => setState(() {
            _videos.remove(v);
            _info.remove(key);
            _trackSel.remove(key);
          }),
        ),
        if (_embeddedMode && streams.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (i, s) in streams.indexed)
                  ChoiceChip(
                    label: Text(
                      '轨#${s.index} ${s.codec}'
                      '${s.language != null && s.language!.isNotEmpty ? ' · ${s.language}' : ''}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: (_trackSel[key] ?? 0) == i,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) =>
                        setState(() => _trackSel[key] = i),
                  ),
              ],
            ),
          ),
        ],
      );
  }
}
