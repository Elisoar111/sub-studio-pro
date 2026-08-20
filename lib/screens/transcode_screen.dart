import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/constants.dart';
import '../core/utils/filename_template.dart';
import '../models/encode_options.dart';
import '../models/queue_task.dart';
import '../models/task_params.dart';
import '../providers/app_providers.dart';
import '../services/file_service.dart';
import '../services/queue_service.dart';
import '../widgets/common.dart';
import '../widgets/encode_settings_panel.dart';
import '../widgets/file_drop_zone.dart';
import '../widgets/output_settings_card.dart';
import 'task_queue_screen.dart';

/// 视频转码 / 压缩页：格式转换 + 分辨率 / 码率调整 + 一键压缩。
class TranscodeScreen extends StatefulWidget {
  const TranscodeScreen({super.key});

  @override
  State<TranscodeScreen> createState() => _TranscodeScreenState();
}

class _TranscodeScreenState extends State<TranscodeScreen> {
  final List<PickedFile> _videos = [];
  final _encodeKey = GlobalKey<EncodeSettingsPanelState>();

  /// 自定义输出目录（null = 全局默认 / 应用目录）
  String? _outputDir;

  /// 文件名模板（空 = 全局默认 / 内置默认）
  String _template = '';

  String _dirLabel = '默认（应用文档目录/transcode）';

  @override
  void initState() {
    super.initState();
    _template = SettingsProvider.instance.filenameTemplate;
    final global = SettingsProvider.instance.defaultOutputDir;
    if (global.isNotEmpty) _dirLabel = global;
  }

  /// 解析输出目录：任务级 > 全局默认 > 应用子目录。
  Future<String> _resolveOutDir() async {
    final task = _outputDir;
    if (task != null) return task;
    final global = SettingsProvider.instance.defaultOutputDir;
    if (global.isNotEmpty) return global;
    return FileService.instance.outputDirFor(AppConstants.dirTranscode);
  }

  Future<void> _pickVideos() async {
    try {
      await FileService.instance.ensureStoragePermissions();
      final picked = await FileService.instance.pickVideos();
      if (picked.isEmpty || !mounted) return;
      setState(() {
        for (final f in picked) {
          final k = f.path ?? 'web:${f.name}';
          if (!_videos.any((x) => (x.path ?? 'web:${x.name}') == k)) {
            _videos.add(f);
          }
        }
      });
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  /// 拖拽导入：按扩展名过滤后复用去重逻辑入列。
  void _handleDroppedFiles(List<String> paths) {
    final filtered = paths.where((path) {
      final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      return AppConstants.videoExtensions.contains(ext);
    }).toList();
    if (filtered.isEmpty) return;
    setState(() {
      for (final path in filtered) {
        final f = FileService.pickedFromFile(path);
        final k = f.path ?? 'web:${f.name}';
        if (!_videos.any((x) => (x.path ?? 'web:${x.name}') == k)) {
          _videos.add(f);
        }
      }
    });
  }

  Future<void> _start() async {
    final q = QueueService.instance;
    if (_videos.isEmpty) {
      showErrorSnack(context, '请先选择视频文件');
      return;
    }
    final encode =
        _encodeKey.currentState?.options ?? const VideoEncodeOptions();
    final outDir = await _resolveOutDir();
    final used = <String>{};
    var count = 0;
    for (final v in _videos) {
      if (v.path == null) continue;
      var name = FilenameTemplate.render(
        _template,
        sourceName: p.basename(v.path!),
        extension: encode.container,
        container: encode.container,
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
      used.add(name.toLowerCase());
      final out = p.join(outDir, name);
      q.addTask(
        type: TaskType.transcode,
        title: '转码 ${p.basename(v.path!)} → ${encode.container.toUpperCase()}',
        params: {
          ...encode.toParams(),
          TaskParams.videoPath: v.path!,
          TaskParams.outputPath: out,
        },
      );
      count++;
    }
    if (count == 0) {
      if (mounted) showErrorSnack(context, '没有可转码的文件');
      return;
    }
    q.start();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TaskQueueScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('转码 / 压缩'),
      ),
      body: FileDropZone(
        acceptedExtensions: AppConstants.videoExtensions,
        onFilesDropped: _handleDroppedFiles,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
                        '可批量；压缩方案、CRF 等在下方统一设置',
                      ]),
                    )
                  : Column(
                      children: [
                        for (final v in _videos)
                          FileTile(
                            title: v.name,
                            icon: Icons.videocam_outlined,
                            onRemove: () =>
                                setState(() => _videos.remove(v)),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            OutputSettingsCard(
              initialDir: _outputDir,
              onDirChanged: (dir) => setState(() => _outputDir = dir),
              initialTemplate: _template,
              templateFallback: FilenameTemplate.transcodeDefault,
              onTemplateChanged: (tpl) => _template = tpl,
              defaultDirLabel: _dirLabel,
              previewSourceName:
                  _videos.isNotEmpty ? _videos.first.name : null,
              previewExtension: _encodeKey.currentState?.options.container,
              previewContainer: _encodeKey.currentState?.options.container,
            ),
            const SizedBox(height: 12),
            EncodeSettingsPanel(key: _encodeKey, onChanged: (_) {}),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.compress),
              label: Text('开始转码 (${_videos.length})'),
            ),
          ],
        ),
      ),
    );
  }
}
