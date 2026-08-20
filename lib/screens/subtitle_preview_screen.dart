import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../core/utils/time_format.dart';
import '../models/subtitle.dart';
import '../services/file_service.dart';
import '../services/subtitle/subtitle_parser.dart';
import '../widgets/common.dart';
import 'convert_screen.dart';
import 'player_screen.dart';

/// 字幕内容预览：解析后展示全部时间轴条目（懒加载列表），
/// 可跳转 格式转换 / 分享导出 / 播放器叠加预览。
class SubtitlePreviewScreen extends StatefulWidget {
  final PickedFile file;

  const SubtitlePreviewScreen({super.key, required this.file});

  @override
  State<SubtitlePreviewScreen> createState() => _SubtitlePreviewScreenState();
}

class _SubtitlePreviewScreenState extends State<SubtitlePreviewScreen> {
  late Future<SubtitleDocument> _future;

  String get _ext =>
      p.extension(widget.file.name).replaceFirst('.', '').toLowerCase();

  @override
  void initState() {
    super.initState();
    _future = _parse();
  }

  Future<SubtitleDocument> _parse() {
    final f = widget.file;
    if (f.isWebFile) {
      return Future.sync(
          () => SubtitleParser.parseBytes(f.bytes!, ext: _ext));
    }
    return SubtitleParser.parseFile(f.path!, forcedEncoding: null);
  }

  void _retry() => setState(() => _future = _parse());

  // ───────────────────────── 操作 ─────────────────────────

  Future<void> _share() async {
    final f = widget.file;
    final path = f.path;
    if (path == null) return; // Windows 桌面恒有磁盘路径
    // Windows 桌面：share_plus 文件分享能力有限，降级为「另存为」
    if (Platform.isWindows || Platform.isLinux) {
      try {
        await FileService.instance
            .copyToUserLocation(path, suggestedName: f.name);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已保存到所选位置')),
          );
        }
      } catch (e) {
        if (mounted) showErrorSnack(context, e);
      }
      return;
    }
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)]),
      );
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  Future<void> _previewWithVideo() async {
    try {
      final videos = await FileService.instance.pickVideos(multi: false);
      if (videos.isEmpty || !mounted) return;
      final video = videos.first;
      if (video.path == null) {
        if (mounted) {
          showErrorSnack(context, 'Web 端暂不支持本地视频播放');
        }
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            videoPath: video.path,
            subtitlePath: widget.file.path,
          ),
        ),
      );
    } catch (e) {
      if (mounted) showErrorSnack(context, e);
    }
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final f = widget.file;
    return Scaffold(
      appBar: AppBar(
        title: Text(f.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '分享 / 导出',
            icon: const Icon(Icons.share),
            onPressed: _share,
          ),
        ],
      ),
      body: FutureBuilder<SubtitleDocument>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return EmptyState(
              icon: Icons.error_outline,
              message: '解析失败：${snapshot.error}',
              action: FilledButton.icon(
                onPressed: _retry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            );
          }
          final doc = snapshot.data!;
          return Column(
            children: [
              _header(doc),
              const Divider(height: 1),
              Expanded(
                child: doc.isEmpty
                    ? const EmptyState(
                        icon: Icons.notes,
                        message: '该字幕文件没有可解析的时间轴条目')
                    : ListView.builder(
                        itemCount: doc.count,
                        itemBuilder: (context, i) {
                          final cue = doc.cues[i];
                          return ListTile(
                            dense: true,
                            leading: SizedBox(
                              width: 96,
                              child: Text(
                                '${formatFullTimestamp(cue.start)}\n'
                                '${formatFullTimestamp(cue.end)}',
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.grey),
                              ),
                            ),
                            title: Text(
                              cue.plainText,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _header(SubtitleDocument doc) {
    final f = widget.file;
    return Card(
      margin: const EdgeInsets.all(12),
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
                  label: Text(doc.sourceEncoding ?? 'utf-8',
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
            const SizedBox(height: 10),
            Text(
              '${formatBytes(f.size)} · ${f.path ?? '内存文件'}',
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ConvertScreen(files: [f]),
                      ),
                    );
                  },
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('格式转换'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _previewWithVideo,
                  icon: const Icon(Icons.play_circle_outline, size: 18),
                  label: const Text('用播放器预览'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
