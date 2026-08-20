import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/utils/filename_template.dart';
import '../models/queue_task.dart';
import '../models/subtitle.dart';
import '../models/task_params.dart';
import '../providers/app_providers.dart';
import '../services/file_service.dart';
import '../services/queue_service.dart';
import '../widgets/common.dart';
import '../widgets/file_drop_zone.dart';
import '../widgets/output_settings_card.dart';
import 'task_queue_screen.dart';

/// 字幕格式转换页：单个或批量 SRT ↔ ASS ↔ SSA ↔ VTT ↔ SUB，
/// 支持输出编码（UTF-8 / GBK / BIG5 / 自动）、BOM、MicroDVD 帧率。
class ConvertScreen extends StatefulWidget {
  /// 待转换的字幕文件（空列表 = 在页面内选择）
  final List<PickedFile> files;

  const ConvertScreen({super.key, required this.files});

  @override
  State<ConvertScreen> createState() => _ConvertScreenState();
}

class _ConvertScreenState extends State<ConvertScreen> {
  late final List<PickedFile> _files = List.of(widget.files);

  SubtitleFormat _target = SubtitleFormat.srt;
  String _encoding = 'utf-8';
  bool _includeBom = false;
  final TextEditingController _fpsCtrl = TextEditingController(text: '25');
  String? _outputDir;

  /// 文件名模板（空 = 全局默认 / 内置默认）
  String _template = '';

  /// 输出目录标签：优先全局默认目录
  String _dirLabel = '默认（应用文档目录/convert）';

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _template = SettingsProvider.instance.filenameTemplate;
    final global = SettingsProvider.instance.defaultOutputDir;
    if (global.isNotEmpty) _dirLabel = global;
  }

  @override
  void dispose() {
    _fpsCtrl.dispose();
    super.dispose();
  }

  // ───────────────────────── 选择 ─────────────────────────

  void _handleDroppedFiles(List<String> paths) {
    final accepted = <PickedFile>[];
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      final extNoDot = ext.isEmpty ? '' : ext.substring(1);
      if (AppConstants.subtitleExtensions.contains(extNoDot)) {
        final f = FileService.pickedFromFile(path);
        final key = f.path ?? 'web:${f.name}';
        if (!_files.any((x) => (x.path ?? 'web:${x.name}') == key)) {
          accepted.add(f);
        }
      }
    }
    if (accepted.isEmpty) return;
    setState(() => _files.addAll(accepted));
  }

  // ───────────────────────── 操作 ─────────────────────────

  Future<void> _pickMore() async {
    try {
      await FileService.instance.ensureStoragePermissions();
      final picked = await FileService.instance.pickSubtitles();
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final key = f.path ?? 'web:${f.name}';
          if (!_files.any((x) => (x.path ?? 'web:${x.name}') == key)) {
            _files.add(f);
          }
        }
      });
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  /// 输出文件名（模板渲染 + 去重）。
  String _outName(String srcName, int index, String dir, Set<String> used) {
    var name = FilenameTemplate.render(
      _template,
      sourceName: srcName,
      extension: _target.extension,
      index: index,
    );
    var i = 2;
    while (used.contains(name.toLowerCase()) ||
        File(p.join(dir, name)).existsSync()) {
      final dot = name.lastIndexOf('.');
      name = dot > 0
          ? '${name.substring(0, dot)}_$i${name.substring(dot)}'
          : '${name}_$i';
      i++;
    }
    return name;
  }

  /// 解析输出目录：任务级 > 全局默认 > 应用子目录。
  Future<String> _resolveOutDir() async {
    final task = _outputDir;
    if (task != null) return task;
    final global = SettingsProvider.instance.defaultOutputDir;
    if (global.isNotEmpty) return global;
    return FileService.instance.outputDirFor(AppConstants.dirConvert);
  }

  Future<void> _start() async {
    if (_files.isEmpty) {
      showErrorSnack(context, '请先选择字幕文件');
      return;
    }
    setState(() => _busy = true);
    try {
      // 入队批量转换任务（纯 Dart 转换，走 Isolate，不占 FFmpeg）
      final q = QueueService.instance;
      final outDir = await _resolveOutDir();
      var ok = 0;
      final used = <String>{};
      for (final f in _files) {
        if (f.path == null) continue;
        final name = _outName(f.name, ok + 1, outDir, used);
        used.add(name.toLowerCase());
        final out = p.join(outDir, name);
        q.addTask(
          type: TaskType.subtitleConvert,
          title: '转换 ${f.name} → ${_target.displayName}',
          params: {
            TaskParams.subtitlePath: f.path!,
            TaskParams.outputPath: out,
            TaskParams.targetFormat: _target.name,
            TaskParams.encoding: _encoding,
            TaskParams.includeBom: _includeBom.toString(),
            TaskParams.microDvdFps: _fpsCtrl.text,
          },
        );
        ok++;
      }
      if (ok == 0) {
        if (mounted) showErrorSnack(context, '没有可转换的文件');
        return;
      }
      q.start();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const TaskQueueScreen()),
      );
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('字幕格式转换'),
      ),
      body: FileDropZone(
        acceptedExtensions: AppConstants.subtitleExtensions,
        onFilesDropped: _handleDroppedFiles,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          SectionCard(
            title: '待转换文件（${_files.length}）',
            trailing: TextButton(
              onPressed: _pickMore,
              child: const Text('添加'),
            ),
            child: _files.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: StepGuide(steps: [
                      '点击右上「选择字幕」，或把字幕文件拖进页面',
                      '支持 SRT / ASS / SSA / VTT，可批量',
                    ]),
                  )
                : Column(
                    children: [
                      for (final f in _files)
                        FileTile(
                          title: f.name,
                          icon: Icons.subtitles_outlined,
                          onRemove: () =>
                              setState(() => _files.remove(f)),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '转换设置',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('目标格式', style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                SegmentedButton<SubtitleFormat>(
                  segments: const [
                    ButtonSegment(value: SubtitleFormat.srt, label: Text('SRT')),
                    ButtonSegment(value: SubtitleFormat.ass, label: Text('ASS')),
                    ButtonSegment(value: SubtitleFormat.ssa, label: Text('SSA')),
                    ButtonSegment(value: SubtitleFormat.vtt, label: Text('VTT')),
                    ButtonSegment(value: SubtitleFormat.sub, label: Text('SUB')),
                  ],
                  selected: {_target},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setState(() => _target = s.first),
                ),
                if (_target == SubtitleFormat.sub) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _fpsCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'MicroDVD 帧率 (fps)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                LabeledDropdown<String>(
                  label: '输出编码',
                  value: _encoding,
                  items: const [
                    DropdownMenuItem(value: 'utf-8', child: Text('UTF-8')),
                    DropdownMenuItem(value: 'gbk', child: Text('GBK（中文老字幕常见）')),
                    DropdownMenuItem(value: 'big5', child: Text('BIG5（繁体）')),
                    DropdownMenuItem(value: 'auto', child: Text('自动（沿用源文件编码）')),
                  ],
                  onChanged: (v) => setState(() {
                    if (v != null) _encoding = v;
                  }),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('UTF-8 时写入 BOM（部分播放器兼容需要）',
                      style: TextStyle(fontSize: 13)),
                  value: _includeBom,
                  onChanged: (v) => setState(() => _includeBom = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutputSettingsCard(
            initialDir: _outputDir,
            onDirChanged: (dir) => setState(() => _outputDir = dir),
            initialTemplate: _template,
            templateFallback: FilenameTemplate.convertDefault,
            onTemplateChanged: (tpl) => _template = tpl,
            defaultDirLabel: _dirLabel,
            previewSourceName:
                _files.isNotEmpty ? _files.first.name : null,
            previewExtension: _target.extension,
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _start,
            icon: const Icon(Icons.play_arrow),
            label: Text('开始转换 (${_files.length})'),
          ),
          ],
        ),
      ),
    );
  }
}
