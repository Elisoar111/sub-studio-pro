import 'package:flutter/material.dart';

import '../core/utils/time_format.dart';
import '../models/queue_task.dart';

/// 任务进度面板：
/// - 总进度（所有任务平均）
/// - 每个任务的进度条 + 状态 + 速度 / 预计剩余
/// - 全部取消按钮
class ProgressPanel extends StatelessWidget {
  final List<QueueTask> tasks;
  final VoidCallback? onCancelAll;
  final bool showCancelAll;

  const ProgressPanel({
    super.key,
    required this.tasks,
    this.onCancelAll,
    this.showCancelAll = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (tasks.isEmpty) return const SizedBox.shrink();

    final active = tasks.where((t) => t.status == TaskStatus.running).toList();
    final overall = tasks.isEmpty
        ? 0.0
        : tasks.fold<double>(0, (sum, t) => sum + t.progress) / tasks.length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('处理进度',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                if (showCancelAll && active.isNotEmpty)
                  TextButton.icon(
                    onPressed: onCancelAll,
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('全部取消'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: overall,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 6),
            Text(
              '总体 ${(overall * 100).toStringAsFixed(0)}%'
              '（完成 ${tasks.where((t) => t.status == TaskStatus.completed).length}/${tasks.length}）',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            ...tasks.map((t) => _TaskTile(task: t)),
          ],
        ),
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  final QueueTask task;

  const _TaskTile({required this.task});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (task.status) {
      TaskStatus.pending => (Icons.schedule, scheme.outline),
      TaskStatus.running => (Icons.directions_run, scheme.primary),
      TaskStatus.completed => (Icons.check_circle, Colors.green.shade600),
      TaskStatus.failed => (Icons.error, scheme.error),
      TaskStatus.cancelled => (Icons.cancel, scheme.outline),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
              ),
              Text(task.statusLabel,
                  style: TextStyle(fontSize: 12, color: color)),
            ],
          ),
          if (task.status == TaskStatus.running) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: task.progress > 0 ? task.progress : null,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            const SizedBox(height: 4),
            Text(
              '${(task.progress * 100).toStringAsFixed(0)}%'
              '${task.speed > 0 ? ' · ${task.speed.toStringAsFixed(2)}x' : ''}'
              ' · ${formatEta(task.progress, task.speed)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
          if (task.status == TaskStatus.failed && task.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(task.error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: scheme.error)),
            ),
        ],
      ),
    );
  }
}
