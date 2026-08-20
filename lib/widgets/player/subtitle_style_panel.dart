import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import '../../widgets/subtitle_overlay.dart';

/// 播放器侧栏：字幕与样式。
/// - 外部字幕文件列表（加载 / 切换 / 移除）
/// - 内嵌字幕轨切换
/// - 时间轴同步偏移（±500ms 微调）
/// - 字幕样式实时调整（字号 / 描边 / 阴影 / 位置 / 透明度 / 颜色 / 加粗）
class SubtitleStylePanel extends StatelessWidget {
  /// 外部字幕文件路径列表
  final List<String> files;

  /// 每个字幕文件的条数（path → cue 数）
  final Map<String, int> cueCounts;

  /// 当前激活的外部字幕下标；-1 = 未使用外部字幕（内嵌轨或无字幕）
  final int activeFileIndex;
  final ValueChanged<int?> onSelectFile;
  final void Function(int index) onRemoveFile;
  final VoidCallback onLoad;

  /// 内嵌字幕轨（已过滤 no/auto）
  final List<SubtitleTrack> embeddedTracks;

  /// 当前选中的内嵌字幕轨 id；外部字幕激活时传 ''，未选任何字幕时传 'none'
  final String activeEmbeddedId;
  final ValueChanged<String?> onSelectEmbedded;

  /// 手动关闭全部字幕（外部 + 内嵌）
  final VoidCallback onCloseSubtitles;

  final Duration offset;
  final void Function(int milliseconds) onNudgeOffset;
  final VoidCallback onResetOffset;

  final SubtitleOverlayStyle style;
  final ValueChanged<SubtitleOverlayStyle> onStyleChanged;

  final bool visible;
  final ValueChanged<bool> onVisibleChanged;

  const SubtitleStylePanel({
    super.key,
    required this.files,
    required this.cueCounts,
    required this.activeFileIndex,
    required this.onSelectFile,
    required this.onRemoveFile,
    required this.onLoad,
    required this.embeddedTracks,
    required this.activeEmbeddedId,
    required this.onSelectEmbedded,
    required this.onCloseSubtitles,
    required this.offset,
    required this.onNudgeOffset,
    required this.onResetOffset,
    required this.style,
    required this.onStyleChanged,
    required this.visible,
    required this.onVisibleChanged,
  });

  static const _colorPresets = [
    ('白', Colors.white),
    ('黄', Color(0xFFFFFF00)),
    ('青', Color(0xFF00E5FF)),
    ('绿', Color(0xFF76FF03)),
    ('粉', Color(0xFFFF80AB)),
    ('橙', Color(0xFFFFAB40)),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 外部字幕文件
        Row(
          children: [
            Expanded(
              child: Text('字幕文件（${files.length}）',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            TextButton.icon(
              onPressed: onLoad,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('加载'),
            ),
          ],
        ),
        if (files.isEmpty)
          Text('支持 SRT / ASS / SSA / VTT，可同时加载多个',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant)),
        RadioGroup<int>(
          groupValue: activeFileIndex,
          onChanged: onSelectFile,
          child: Column(
            children: [
              for (final (i, f) in files.indexed)
                RadioListTile<int>(
                  value: i,
                  dense: true,
                  title: Text(p.basename(f),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${cueCounts[f] ?? 0} 条',
                      style: const TextStyle(fontSize: 11)),
                  secondary: IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    tooltip: '移除',
                    onPressed: () => onRemoveFile(i),
                  ),
                ),
            ],
          ),
        ),
        // 内嵌字幕轨
        if (embeddedTracks.isNotEmpty) ...[
          const Divider(height: 24),
          Text('内嵌字幕轨（${embeddedTracks.length}）',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          RadioGroup<String>(
            groupValue: activeEmbeddedId,
            onChanged: (id) {
              if (id == 'none') {
                onCloseSubtitles();
              } else {
                onSelectEmbedded(id);
              }
            },
            child: Column(
              children: [
                RadioListTile<String>(
                  value: 'none',
                  dense: true,
                  title: Text('关闭字幕',
                      style: TextStyle(
                          fontSize: 13, color: scheme.onSurfaceVariant)),
                ),
                for (final t in embeddedTracks)
                  RadioListTile<String>(
                    value: t.id,
                    dense: true,
                    title: Text(
                      '${t.title ?? '字幕轨 ${t.id}'}'
                      '${t.language != null && t.language!.isNotEmpty ? ' · ${t.language}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
        const Divider(height: 24),
        // 同步偏移
        Text('字幕同步偏移',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Row(
          children: [
            OutlinedButton(
              onPressed: () => onNudgeOffset(-500),
              child: const Text('-500ms'),
            ),
            Expanded(
              child: Center(
                child: Text(
                  offset == Duration.zero
                      ? '0ms'
                      : '${offset.inMilliseconds > 0 ? '+' : ''}${offset.inMilliseconds}ms',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: offset == Duration.zero
                        ? scheme.onSurfaceVariant
                        : scheme.primary,
                  ),
                ),
              ),
            ),
            OutlinedButton(
              onPressed: () => onNudgeOffset(500),
              child: const Text('+500ms'),
            ),
            const SizedBox(width: 4),
            if (offset != Duration.zero)
              IconButton(
                tooltip: '复位',
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: onResetOffset,
              ),
          ],
        ),
        Text('正值 = 字幕提前；正值过大说明字幕轴偏晚。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant)),
        const Divider(height: 24),
        // 样式实时调整
        Text('字幕样式（实时生效）',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        _StyleSliderRow(
          label: '字号',
          value: style.fontSize,
          min: 14,
          max: 56,
          display: style.fontSize.round().toString(),
          onChanged: (v) => onStyleChanged(style.copyWith(fontSize: v)),
        ),
        _StyleSliderRow(
          label: '描边',
          value: style.outlineWidth,
          min: 0,
          max: 4,
          display: style.outlineWidth.toStringAsFixed(1),
          onChanged: (v) => onStyleChanged(style.copyWith(outlineWidth: v)),
        ),
        _StyleSliderRow(
          label: '阴影',
          value: style.shadowDepth,
          min: 0,
          max: 4,
          display: style.shadowDepth.toStringAsFixed(1),
          onChanged: (v) => onStyleChanged(style.copyWith(shadowDepth: v)),
        ),
        _StyleSliderRow(
          label: '位置',
          value: style.bottomFraction,
          min: 0.02,
          max: 0.45,
          display: '${(style.bottomFraction * 100).toStringAsFixed(0)}%',
          onChanged: (v) => onStyleChanged(style.copyWith(bottomFraction: v)),
        ),
        _StyleSliderRow(
          label: '不透明度',
          value: style.opacity,
          min: 0.2,
          max: 1.0,
          display: style.opacity.toStringAsFixed(2),
          onChanged: (v) => onStyleChanged(style.copyWith(opacity: v)),
        ),
        const SizedBox(height: 8),
        Text('字幕颜色',
            style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                )),
        const SizedBox(height: 6),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final (_, color) in _colorPresets)
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onStyleChanged(style.copyWith(color: color)),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: style.color.toARGB32() == color.toARGB32()
                          ? scheme.onSurface
                          : scheme.outlineVariant,
                      width:
                          style.color.toARGB32() == color.toARGB32() ? 3 : 1.5,
                    ),
                  ),
                ),
              ),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('加粗', style: TextStyle(fontSize: 13)),
          value: style.bold,
          onChanged: (v) => onStyleChanged(style.copyWith(bold: v)),
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('显示字幕', style: TextStyle(fontSize: 13)),
          value: visible,
          onChanged: onVisibleChanged,
        ),
      ],
    );
  }
}

class _StyleSliderRow extends StatelessWidget {
  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  const _StyleSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(display,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
        ),
      ],
    );
  }
}
