import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../core/utils/reveal_file.dart';
import '../core/utils/time_format.dart';
import '../models/subtitle.dart';
import '../services/file_service.dart';
import '../services/subtitle/subtitle_parser.dart';
import '../widgets/common.dart';
import 'player_screen.dart';

/// 处理结果页：视频 / 字幕成品的预览与后续操作
/// （分享、重命名、另存为、删除）。Windows 上「分享」降级为「另存为」。
/// 视频播放统一走新播放器（PlayerScreen，完整控制条 / 播放列表 /
/// 字幕样式 / 音轨切换）。
class ResultScreen extends StatefulWidget {
  final String outputPath;
  final String? title;

  const ResultScreen({super.key, required this.outputPath, this.title});

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  SubtitleDocument? _subtitle;
  String? _subtitleError;

  String get _ext =>
      p.extension(widget.outputPath).replaceFirst('.', '').toLowerCase();

  bool get _isVideo => AppConstants.videoExtensions.contains(_ext);

  bool get _isSubtitle => AppConstants.subtitleExtensions.contains(_ext);

  @override
  void initState() {
    super.initState();
    if (_isSubtitle) {
      _initSubtitle();
    }
  }

  Future<void> _initSubtitle() async {
    try {
      final doc = await SubtitleParser.parseFile(widget.outputPath);
      if (mounted) setState(() => _subtitle = doc);
    } catch (e) {
      if (mounted) setState(() => _subtitleError = '$e');
    }
  }

  // ───────────────────────── 操作 ─────────────────────────

  void _openInPlayer() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(videoPath: widget.outputPath),
      ),
    );
  }

  Future<void> _reveal() async {
    await revealInFileManager(widget.outputPath);
  }

  Future<void> _share() async {
    // Windows 上 share_plus 的文件分享能力有限，降级为「另存为」
    if (Platform.isWindows || Platform.isLinux) {
      await _saveAs();
      return;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(widget.outputPath)]),
      );
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _rename() async {
    final dir = p.dirname(widget.outputPath);
    final oldBase = p.basenameWithoutExtension(widget.outputPath);
    final nameCtrl = TextEditingController(text: oldBase);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '文件名（不含扩展名）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(nameCtrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == oldBase) return;
    try {
      final target = p.join(dir, '$newName.$_ext');
      await File(widget.outputPath).rename(target);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ResultScreen(
              outputPath: target,
              title: widget.title,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _saveAs() async {
    try {
      await FileService.instance.copyToUserLocation(widget.outputPath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存到所选位置')),
        );
      }
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除文件'),
        content: const Text('确定删除该文件吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await File(widget.outputPath).delete();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final path = widget.outputPath;
    final size = _fileSize(path);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title ?? p.basename(path),
            overflow: TextOverflow.ellipsis),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_isVideo) _buildVideoPreview(),
          if (_isSubtitle) _buildSubtitlePreview(),
          const SizedBox(height: 12),
          SectionCard(
            title: '文件信息',
            child: Column(
              children: [
                InfoRow(label: '名称', value: p.basename(path)),
                InfoRow(label: '类型', value: '${_ext.toUpperCase()} 文件'),
                InfoRow(label: '大小', value: formatBytes(size)),
                InfoRow(label: '位置', value: p.dirname(path)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _reveal,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('打开所在文件夹'),
              ),
              FilledButton.tonalIcon(
                onPressed: _share,
                icon: const Icon(Icons.share, size: 18),
                label: const Text('分享'),
              ),
              FilledButton.tonalIcon(
                onPressed: _rename,
                icon: const Icon(Icons.drive_file_rename_outline, size: 18),
                label: const Text('重命名'),
              ),
              FilledButton.tonalIcon(
                onPressed: _saveAs,
                icon: const Icon(Icons.save_alt, size: 18),
                label: const Text('另存为'),
              ),
              FilledButton.tonalIcon(
                onPressed: _delete,
                icon: const Icon(Icons.delete_outline, size: 18),
                label: const Text('删除'),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildVideoPreview() {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _openInPlayer,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.play_circle_fill,
                    size: 44, color: scheme.primary),
              ),
              const SizedBox(height: 10),
              Text(p.basename(widget.outputPath),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('用播放器打开 · 支持音轨/字幕切换与样式调整',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      )),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubtitlePreview() {
    final doc = _subtitle;
    if (_subtitleError != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text('字幕预览不可用：$_subtitleError',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.error, fontSize: 13)),
        ),
      );
    }
    if (doc == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(
                  label: Text(doc.format.displayName,
                      style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 6),
                Chip(
                  label: Text('${doc.count} 条',
                      style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const Divider(height: 20),
            ...doc.cues.take(5).map(
                  (cue) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      '${formatFullTimestamp(cue.start)} → '
                      '${formatFullTimestamp(cue.end)}\n${cue.plainText}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  int _fileSize(String path) {
    try {
      final f = File(path);
      return f.existsSync() ? f.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }
}
