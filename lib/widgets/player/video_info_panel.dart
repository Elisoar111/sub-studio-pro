import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/time_format.dart';
import '../../models/video_info.dart';
import '../common.dart';

/// 播放器侧栏：FFprobe 视频元数据（格式 / 时长 / 大小 / 码率 / 各轨道）。
class VideoInfoPanel extends StatelessWidget {
  final String? path;
  final VideoInfo? info;
  final bool probing;

  const VideoInfoPanel({
    super.key,
    required this.path,
    required this.info,
    required this.probing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (probing) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('FFprobe 探测中…', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
      );
    }
    final info = this.info;
    if (info == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '无法获取视频信息（FFprobe 不可用或文件损坏）',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(p.basename(path ?? ''),
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(path ?? '',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        const Divider(height: 24),
        InfoRow(label: '格式', value: info.formatName ?? '未知'),
        InfoRow(label: '时长', value: formatClock(info.duration)),
        InfoRow(label: '大小', value: formatBytes(info.sizeBytes ?? 0)),
        InfoRow(
          label: '总码率',
          value: info.bitrate == null
              ? '未知'
              : '${(info.bitrate! / 1000).round()} kbps',
        ),
        const Divider(height: 20),
        for (final s in info.videoStreams)
          InfoRow(
            label: '视频轨 #${s.index}',
            value: '${s.codec} · ${s.resolutionLabel}'
                '${s.fps != null ? ' · ${s.fps!.toStringAsFixed(2)} fps' : ''}',
          ),
        for (final s in info.audioStreams)
          InfoRow(
            label: '音频轨 #${s.index}',
            value: '${s.codec}'
                '${s.channels != null ? ' · ${s.channels} 声道' : ''}'
                '${s.language != null && s.language!.isNotEmpty ? ' · ${s.language}' : ''}',
          ),
        for (final s in info.subtitleStreams)
          InfoRow(label: '字幕轨 #${s.index}', value: s.label),
      ],
    );
  }
}
