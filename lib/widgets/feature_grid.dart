import 'package:flutter/material.dart';

/// ── 首页功能网格 ──
/// 按字幕组工作流分区（字幕工作流 / 视频处理 / 任务与记录），
/// 响应式卡片网格：手机 2 列、平板 3 列、桌面 4 列。

/// 一个功能入口。
class FeatureEntry {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  /// 右上角角标（如任务队列的待处理数量），null 时不显示。
  final int? badge;

  /// 右上角自定义角标组件（优先于 [badge]，可响应状态变化）。
  final Widget? badgeWidget;

  const FeatureEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.onTap,
    this.badge,
    this.badgeWidget,
  });
}

/// 带标题的工作流分区。
class WorkflowSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<FeatureEntry> features;

  const WorkflowSection({
    super.key,
    required this.title,
    required this.icon,
    required this.features,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
          child: Row(
            children: [
              Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final cols = width >= 900 ? 4 : (width >= 600 ? 3 : 2);
            const spacing = 12.0;
            final cardW = (width - spacing * (cols - 1)) / cols;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final f in features)
                  SizedBox(width: cardW, child: FeatureCard(entry: f)),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 单张功能卡片。
class FeatureCard extends StatelessWidget {
  final FeatureEntry entry;

  const FeatureCard({super.key, required this.entry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: entry.color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(entry.icon, color: entry.color, size: 24),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    entry.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    entry.subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.3,
                        ),
                  ),
                ],
              ),
              if (entry.badgeWidget != null)
                Positioned(
                  top: 0,
                  right: 0,
                  child: entry.badgeWidget!,
                )
              else if (entry.badge != null && entry.badge! > 0)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.error,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${entry.badge}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
