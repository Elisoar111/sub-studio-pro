import 'package:flutter/material.dart';

/// 通用 UI 小组件：分区卡片 / 信息行 / 空状态 / 文件块 / 下拉行。

/// 带标题的分区卡片
class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;
  final IconData? icon;

  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(icon,
                        size: 16, color: scheme.onPrimaryContainer),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          )),
                ),
                if (trailing != null) trailing!,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// 键值信息行
class InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData? icon;

  const InfoRow({super.key, required this.label, required this.value, this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: scheme.primary),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 88,
            child: Text(label,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    )),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// 空状态「下一步」指引：编号步骤列表，可独立使用或经 [EmptyState.steps] 嵌入。
class StepGuide extends StatelessWidget {
  final List<String> steps;

  const StepGuide({super.key, required this.steps});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('下一步',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1,
                )),
        const SizedBox(height: 6),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${i + 1}  ',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    )),
                Flexible(
                  child: Text(steps[i],
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      )),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 空状态占位
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final Widget? action;

  /// 「下一步」编号指引（可选）：指向文件选择 / 设置等下一步操作
  final List<String>? steps;

  const EmptyState({
    super.key,
    required this.icon,
    required this.message,
    this.action,
    this.steps,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: scheme.outline),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  )),
          if (steps != null && steps!.isNotEmpty) ...[
            const SizedBox(height: 16),
            StepGuide(steps: steps!),
          ],
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    );
    return LayoutBuilder(builder: (context, constraints) {
      // 高度受限时改为「可滚动 + 视口内居中」：放得下与原版视觉一致，
      // 放不下（短窗口）时滚动而非 RenderFlex 底部溢出
      if (!constraints.maxHeight.isFinite) return Center(child: content);
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: content),
        ),
      );
    });
  }
}

/// 文件块（名称 + 副标题 + 可选删除按钮）
class FileTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onRemove;
  final Widget? trailing;

  const FileTile({
    super.key,
    required this.title,
    this.subtitle,
    this.icon = Icons.insert_drive_file_outlined,
    this.onRemove,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: Icon(icon, size: 20),
      ),
      title: Text(title,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12)),
      trailing: trailing ??
          (onRemove == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onRemove,
                )),
    );
  }
}

/// 标签下拉选择行
class LabeledDropdown<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const LabeledDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Expanded(
          flex: 4,
          child: DropdownButtonFormField<T>(
            initialValue: value,
            items: items,
            onChanged: onChanged,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(),
            ),
          ),
        ),
      ],
    );
  }
}

/// 统一错误提示
void showErrorSnack(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('操作失败：$error'),
      backgroundColor: Theme.of(context).colorScheme.error,
    ),
  );
}
