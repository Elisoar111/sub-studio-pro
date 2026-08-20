import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/logger.dart';
import '../core/utils/reveal_file.dart';
import '../models/queue_task.dart';
import '../providers/app_providers.dart';
import '../services/queue_service.dart';
import '../widgets/common.dart';
import '../widgets/progress_panel.dart';
import 'result_screen.dart';

/// 任务队列页：总体进度 + 每个任务的实时进度 / 速度 / 剩余时间，
/// 支持单个取消、失败重试、打开结果、移除。
class TaskQueueScreen extends StatelessWidget {
  const TaskQueueScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('任务队列'),
        actions: [
          Consumer(
            builder: (context, ref, _) {
              final q = ref.watch(queueProvider);
              final hasPending = q.hasPending;
              return TextButton(
                onPressed: hasPending && !q.isRunning ? q.start : null,
                child: const Text('开始'),
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              final q = QueueService.instance;
              if (v == 'clearFinished') q.clearFinished();
              if (v == 'clearAll') q.clearAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'clearFinished', child: Text('清空已完成')),
              PopupMenuItem(value: 'clearAll', child: Text('清空全部')),
            ],
          ),
        ],
      ),
      body: Consumer(
        builder: (context, ref, _) {
          final q = ref.watch(queueProvider);
          final tasks = q.tasks;
          if (tasks.isEmpty) {
            return const EmptyState(
              icon: Icons.inbox_outlined,
              message: '任务队列为空',
              steps: [
                '在 烧录 / 轨道处理 / 转码 / 翻译 等页面添加任务',
                '点击对应页面的 开始 按钮进入队列执行',
                'Ctrl+Q 可随时回到本页查看进度',
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ProgressPanel(tasks: tasks, onCancelAll: q.cancelAll),
              const SizedBox(height: 12),
              for (final task in tasks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _TaskCard(
                    task: task,
                    onCancel: () => q.cancelTask(task.id),
                    onRetry: () => q.retryTask(task.id),
                    onOpen: () {
                      final out = task.outputPath;
                      if (out != null && File(out).existsSync()) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ResultScreen(
                              outputPath: out,
                              title: task.title,
                            ),
                          ),
                        );
                      }
                    },
                    onReveal: () {
                      final out = task.outputPath;
                      if (out != null) revealInFileManager(out);
                    },
                    onRemove: () => q.removeTask(task.id),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _TaskCard extends StatefulWidget {
  final QueueTask task;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onOpen;
  final VoidCallback onReveal;
  final VoidCallback onRemove;

  const _TaskCard({
    required this.task,
    required this.onCancel,
    required this.onRetry,
    required this.onOpen,
    required this.onReveal,
    required this.onRemove,
  });

  @override
  State<_TaskCard> createState() => _TaskCardState();
}

class _TaskCardState extends State<_TaskCard> {
  bool _expanded = false;

  QueueTask get task => widget.task;
  VoidCallback get onCancel => widget.onCancel;
  VoidCallback get onRetry => widget.onRetry;
  VoidCallback get onOpen => widget.onOpen;
  VoidCallback get onReveal => widget.onReveal;
  VoidCallback get onRemove => widget.onRemove;

  /// 排障报告：任务元信息 + 完整错误 + 该任务的执行日志会话。
  String _buildReport() {
    final b = StringBuffer()
      ..writeln('任务：${task.title}')
      ..writeln('类型：${task.type.label}')
      ..writeln('状态：${task.statusLabel}')
      ..writeln('开始：${task.startedAt ?? '-'}')
      ..writeln('结束：${task.finishedAt ?? '-'}')
      ..writeln('错误：${task.error ?? '-'}')
      ..writeln('参数：');
    for (final e in task.params.entries) {
      b.writeln('  ${e.key} = ${e.value}');
    }
    final logs = Logger.instance.linesForTag('ffmpeg#${task.id.substring(0, 6)}');
    if (logs.isNotEmpty) {
      b.writeln('执行日志（${logs.length} 行）：');
      b.writeln(logs.join('\n'));
    }
    return b.toString();
  }

  Future<void> _copyReport() async {
    await Clipboard.setData(ClipboardData(text: _buildReport()));
  }

  /// 展开态详情面板：完整参数 + 该任务的执行日志会话（等宽字体，限高滚动）。
  List<Widget> _buildExpandedDetail(ColorScheme scheme) {
    final logs =
        Logger.instance.linesForTag('ffmpeg#${task.id.substring(0, 6)}');
    return [
      const Divider(height: 12),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '任务参数',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                task.params.isEmpty
                    ? '（无）'
                    : task.params.entries
                        .map((e) => '${e.key} = ${e.value}')
                        .join('\n'),
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'Consolas', height: 1.4),
              ),
              const SizedBox(height: 8),
              Text(
                '执行日志',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                logs.isEmpty ? '（本任务无会话日志）' : logs.join('\n'),
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'Consolas', height: 1.4),
              ),
            ],
          ),
        ),
      ),
    ];
  }

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

    final actions = <Widget>[
      if (task.status == TaskStatus.running)
        IconButton(
          tooltip: '取消',
          icon: const Icon(Icons.stop_circle_outlined),
          onPressed: onCancel,
        ),
      if (task.status == TaskStatus.failed)
        IconButton(
          tooltip: '重试',
          icon: const Icon(Icons.refresh),
          onPressed: onRetry,
        ),
      if (task.status == TaskStatus.completed && task.outputPath != null)
        IconButton(
          tooltip: '打开结果',
          icon: const Icon(Icons.open_in_new),
          onPressed: onOpen,
        ),
      if (task.status == TaskStatus.completed && task.outputPath != null)
        IconButton(
          tooltip: '在文件资源管理器中显示',
          icon: const Icon(Icons.folder_open),
          onPressed: onReveal,
        ),
      IconButton(
        tooltip: '移除',
        icon: const Icon(Icons.delete_outline, size: 20),
        onPressed: onRemove,
      ),
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          task.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
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
                      ' · 已处理 ${task.time.inSeconds}s',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                  if (task.status == TaskStatus.failed &&
                      task.error != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      task.error!,
                      maxLines: _expanded ? null : 3,
                      overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                    // 工单排障：展开完整日志 + 一键复制
                    Row(
                      children: [
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 30),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: () =>
                              setState(() => _expanded = !_expanded),
                          icon: Icon(
                            _expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 16,
                          ),
                          label: Text(_expanded ? '收起' : '详情'),
                        ),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 30),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: _copyReport,
                          icon: const Icon(Icons.copy, size: 14),
                          label: const Text('复制'),
                        ),
                      ],
                    ),
                    if (_expanded) ..._buildExpandedDetail(scheme),
                  ],
                  if (task.outputPath != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      task.outputPath!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontSize: 11,
                          ),
                    ),
                  ],
                ],
              ),
            ),
            if (actions.isNotEmpty)
              Row(mainAxisSize: MainAxisSize.min, children: actions),
          ],
        ),
      ),
    );
  }
}
