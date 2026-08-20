import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/utils/reveal_file.dart';
import '../models/history_entry.dart';
import '../models/queue_task.dart';
import '../providers/app_providers.dart';
import '../widgets/common.dart';

/// 操作历史页：自动记录每次 转换 / 烧录 / 提取 / 转码 的参数与结果，
/// 支持按类型过滤、查看详情、删除、清空。
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  IconData _iconFor(TaskType type) => switch (type) {
        TaskType.subtitleConvert => Icons.swap_horiz,
        TaskType.burn => Icons.theaters,
        TaskType.extract => Icons.file_download_outlined,
        TaskType.transcode => Icons.compress,
        TaskType.mux => Icons.merge_type,
        TaskType.subtitleTranslate => Icons.translate,
        TaskType.whisper => Icons.mic_none,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('历史记录'),
        actions: [
          IconButton(
            tooltip: '清空历史',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _confirmClear(context),
          ),
        ],
      ),
      body: Consumer(
        builder: (context, ref, _) {
          final provider = ref.watch(historyProvider);
          final entries = provider.entries;
          if (entries.isEmpty) {
            return const EmptyState(
              icon: Icons.history,
              message: '暂无历史记录',
              steps: [
                '到任意功能页完成一次 转换 / 烧录 / 提取 / 转码',
                '任务结束后记录会自动出现在这里',
              ],
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, i) {
              final e = entries[i];
              return _HistoryTile(
                entry: e,
                icon: _iconFor(e.type),
                onDelete: () => provider.remove(e.id),
                onTap: () => _showDetail(context, e),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定删除全部历史记录吗？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await HistoryProvider.instance.clear();
    }
  }

  void _showDetail(BuildContext context, HistoryEntry e) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (context, scrollController) => ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(e.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${e.type.label} · ${e.timestamp.toLocal().toString().substring(0, 19)}'
              ' · ${e.success ? "成功" : "失败"}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 24),
            for (final input in e.inputs)
              InfoRow(label: '输入', value: input),
            if (e.output != null) ...[
              InfoRow(label: '输出', value: e.output!),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: () => revealInFileManager(e.output!),
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('在文件资源管理器中显示'),
                ),
              ),
            ],
            const Divider(height: 24),
            for (final entry in e.params.entries)
              if (entry.value.isNotEmpty)
                InfoRow(label: entry.key, value: entry.value),
          ],
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final HistoryEntry entry;
  final IconData icon;
  final VoidCallback onDelete;
  final VoidCallback onTap;

  const _HistoryTile({
    required this.entry,
    required this.icon,
    required this.onDelete,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final inputNames = entry.inputs.map(p.basename).join('、');
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: Icon(icon, size: 20),
      ),
      title: Text(entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(
        '${entry.timestamp.toLocal().toString().substring(0, 19)}'
        '${inputNames.isEmpty ? '' : ' · $inputNames'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!entry.success)
            Icon(Icons.error_outline, size: 16, color: scheme.error),
          IconButton(
            tooltip: '删除',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}
