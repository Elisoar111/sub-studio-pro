import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../common.dart';

/// 播放器侧栏：播放列表（添加 / 清空 / 点击跳转 / 逐项移除）。
class PlaylistPanel extends StatelessWidget {
  final List<String> playlist;
  final int currentIndex;

  final VoidCallback onAdd;
  final VoidCallback onClear;
  final void Function(int index) onJump;
  final void Function(int index) onRemove;

  const PlaylistPanel({
    super.key,
    required this.playlist,
    required this.currentIndex,
    required this.onAdd,
    required this.onClear,
    required this.onJump,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加视频'),
              ),
              const Spacer(),
              if (playlist.isNotEmpty)
                TextButton(
                  onPressed: onClear,
                  child: const Text('清空'),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: playlist.isEmpty
              ? const EmptyState(
                  icon: Icons.queue_music,
                  message: '播放列表为空，点击「添加视频」',
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: playlist.length,
                  itemBuilder: (context, i) {
                    final current = i == currentIndex;
                    final scheme = Theme.of(context).colorScheme;
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        current ? Icons.play_arrow : Icons.videocam_outlined,
                        size: 20,
                        color: current ? scheme.primary : scheme.outline,
                      ),
                      title: Text(
                        p.basename(playlist[i]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: current ? scheme.primary : null,
                          fontWeight:
                              current ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      subtitle: Text(
                        p.dirname(playlist[i]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        tooltip: '移除',
                        onPressed: () => onRemove(i),
                      ),
                      onTap: () => onJump(i),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
