import 'package:flutter/material.dart';

import '../core/utils/filename_template.dart';
import '../services/file_service.dart';
import 'common.dart';

/// 输出设置卡片：自定义输出目录 + 文件名模板（带实时预览）。
///
/// 供 字幕转换 / 烧录 / 转码 等功能页复用；
/// 目录与模板的解析优先级：任务级覆盖 > 全局默认（设置页）> 应用内置默认。
/// 提取页命名固定走 gMKVExtractGUI 规则（[showTemplate] = false 隐藏模板区）。
class OutputSettingsCard extends StatefulWidget {
  /// 卡片内目录未自定义时的说明（已含全局默认路径时直接显示该路径）
  final String defaultDirLabel;

  /// 初始输出目录（null = 未自定义）
  final String? initialDir;

  /// 目录变化回调（null = 恢复默认）
  final ValueChanged<String?> onDirChanged;

  /// 是否显示文件名模板编辑区（默认 true）
  final bool showTemplate;

  /// 模板编辑区是否可折叠（默认 false）。
  /// 纵向空间紧张的页面（如轨道处理页内的封装页签）设为 true：
  /// 默认折叠为单行摘要，需要改模板时展开，避免短窗口下
  /// 固定内容超出可视高度导致整页底部溢出。
  final bool collapsibleTemplate;

  /// 初始文件名模板（空串 = 使用回退模板）
  final String initialTemplate;

  /// 模板为空时的回退（通常为功能内置默认或全局默认）
  final String templateFallback;

  /// 模板变化回调（回退时传空串）
  final ValueChanged<String> onTemplateChanged;

  /// 预览用：源文件名 / 输出扩展名 / 序号 / 容器
  final String? previewSourceName;
  final String? previewExtension;
  final int? previewIndex;
  final String? previewContainer;

  const OutputSettingsCard({
    super.key,
    required this.defaultDirLabel,
    required this.onDirChanged,
    required this.onTemplateChanged,
    this.showTemplate = true,
    this.collapsibleTemplate = false,
    this.initialDir,
    this.initialTemplate = '',
    this.templateFallback = FilenameTemplate.convertDefault,
    this.previewSourceName,
    this.previewExtension,
    this.previewIndex,
    this.previewContainer,
  });

  @override
  State<OutputSettingsCard> createState() => OutputSettingsCardState();
}

class OutputSettingsCardState extends State<OutputSettingsCard> {
  late final TextEditingController _tplCtrl =
      TextEditingController(text: widget.initialTemplate);

  /// 模板编辑区展开态（可折叠模式下默认收起）
  bool _templateOpen = false;

  @override
  void dispose() {
    _tplCtrl.dispose();
    super.dispose();
  }

  String get effectiveTemplate =>
      _tplCtrl.text.trim().isEmpty ? widget.templateFallback : _tplCtrl.text;

  /// 模板编辑区是否展开（不可折叠时恒为展开）
  bool get templateOpen => !widget.collapsibleTemplate || _templateOpen;

  Future<void> _pickDir() async {
    final dir = await FileService.instance.pickDirectory();
    if (dir != null && mounted) {
      setState(() {});
      widget.onDirChanged(dir);
    }
  }

  void _resetDir() {
    setState(() {});
    widget.onDirChanged(null);
  }

  void _insertVariable(String v) {
    final sel = _tplCtrl.selection;
    final text = _tplCtrl.text;
    if (!sel.isValid || sel.baseOffset < 0) {
      _tplCtrl.text = '$text$v';
    } else {
      _tplCtrl.text = text.replaceRange(
        sel.start,
        sel.end,
        v,
      );
    }
    widget.onTemplateChanged(_tplCtrl.text);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = FilenameTemplate.render(
      effectiveTemplate,
      sourceName: widget.previewSourceName ?? '示例视频',
      extension: widget.previewExtension ?? 'mp4',
      index: widget.previewIndex,
      container: widget.previewContainer,
    );
    return SectionCard(
      title: '输出设置',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 输出目录 ──
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.initialDir ?? widget.defaultDirLabel,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: widget.initialDir == null
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                        fontWeight: widget.initialDir == null
                            ? FontWeight.w400
                            : FontWeight.w500,
                      ),
                ),
              ),
              TextButton.icon(
                onPressed: _pickDir,
                icon: const Icon(Icons.drive_file_move_outline, size: 16),
                label: const Text('选择…'),
              ),
              if (widget.initialDir != null)
                Tooltip(
                  message: '恢复默认目录',
                  child: IconButton(
                    icon: const Icon(Icons.restart_alt, size: 18),
                    onPressed: _resetDir,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          // ── 文件名模板 ──
          if (widget.showTemplate && !templateOpen)
            _collapsedTemplateRow(scheme, preview)
          else if (widget.showTemplate) ...[
            TextField(
              controller: _tplCtrl,
              onChanged: (v) {
                widget.onTemplateChanged(v);
                setState(() {});
              },
              decoration: InputDecoration(
                labelText: '文件名模板',
                hintText: '留空 = ${widget.templateFallback}',
                suffixIcon: _tplCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        tooltip: '清空（使用默认模板）',
                        onPressed: () {
                          _tplCtrl.clear();
                          widget.onTemplateChanged('');
                          setState(() {});
                        },
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in FilenameTemplate.variables.keys)
                  ActionChip(
                    label: Text(v, style: const TextStyle(fontSize: 11)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _insertVariable(v),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '预览：$preview',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'Consolas',
                    ),
              ),
            ),
            if (widget.collapsibleTemplate)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => setState(() => _templateOpen = false),
                  icon: const Icon(Icons.expand_less, size: 16),
                  label: const Text('收起模板'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 折叠态模板行：当前渲染结果 + 展开入口（单行，省出编辑区高度）。
  Widget _collapsedTemplateRow(ColorScheme scheme, String preview) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _templateOpen = true),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.drive_file_rename_outline,
                size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '模板 $preview',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFamily: 'Consolas',
                    ),
              ),
            ),
            const SizedBox(width: 8),
            Text('编辑',
                style: TextStyle(fontSize: 11.5, color: scheme.primary)),
            Icon(Icons.expand_more, size: 16, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}
