import 'package:flutter/material.dart';

import '../models/subtitle.dart';

/// 字幕叠加层实时样式：播放时可动态修改，立即生效。
class SubtitleOverlayStyle {
  /// 字号（逻辑像素）
  final double fontSize;

  /// 字幕颜色
  final Color color;

  /// 描边宽度（0 = 无描边）
  final double outlineWidth;

  /// 描边颜色
  final Color outlineColor;

  /// 阴影深度（0 = 无阴影）
  final double shadowDepth;

  /// 距底部高度占播放区高度的比例（0.02 ~ 0.45）
  final double bottomFraction;

  /// 整体不透明度（0.2 ~ 1.0）
  final double opacity;

  /// 加粗
  final bool bold;

  const SubtitleOverlayStyle({
    this.fontSize = 26,
    this.color = Colors.white,
    this.outlineWidth = 2,
    this.outlineColor = Colors.black,
    this.shadowDepth = 1.5,
    this.bottomFraction = 0.06,
    this.opacity = 1.0,
    this.bold = false,
  });

  SubtitleOverlayStyle copyWith({
    double? fontSize,
    Color? color,
    double? outlineWidth,
    Color? outlineColor,
    double? shadowDepth,
    double? bottomFraction,
    double? opacity,
    bool? bold,
  }) =>
      SubtitleOverlayStyle(
        fontSize: fontSize ?? this.fontSize,
        color: color ?? this.color,
        outlineWidth: outlineWidth ?? this.outlineWidth,
        outlineColor: outlineColor ?? this.outlineColor,
        shadowDepth: shadowDepth ?? this.shadowDepth,
        bottomFraction: bottomFraction ?? this.bottomFraction,
        opacity: opacity ?? this.opacity,
        bold: bold ?? this.bold,
      );
}

/// 字幕叠加层：根据当前播放位置渲染字幕文本（二分查找，O(log n)）。
///
/// 纯展示组件，不依赖具体播放器——由父组件传入 [position] 实时刷新。
/// [offset] 为时间轴整体偏移（正值 = 字幕提前），在查找 cue 前应用。
/// [style] 非空时覆盖 ASS 文档样式（实时调整用）；否则按文档样式近似渲染。
/// 完整 ASS 特效（卡拉OK、淡入淡出等）以烧录后的 libass 渲染为准。
class SubtitleOverlay extends StatelessWidget {
  final Duration position;

  /// 时间轴偏移（正值 = 字幕提前显示）
  final Duration offset;

  final SubtitleDocument? document;
  final bool visible;
  final SubtitleOverlayStyle? style;

  const SubtitleOverlay({
    super.key,
    required this.position,
    this.offset = Duration.zero,
    this.document,
    this.visible = true,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final doc = document;
    if (!visible || doc == null || doc.isEmpty) return const SizedBox.shrink();

    final cue = doc.cueAt(position + offset); // 二分查找（含偏移）
    if (cue == null) return const SizedBox.shrink();
    final text = cue.plainText;
    if (text.isEmpty) return const SizedBox.shrink();

    final docStyle = doc.style;
    final s = style ??
        SubtitleOverlayStyle(
          fontSize: (docStyle?.fontSize ?? 24).clamp(14, 48),
          color: docStyle?.color ?? Colors.white,
          bold: docStyle?.bold == true,
        );

    final scale = style == null && docStyle != null
        ? (docStyle.fontSize / 24).clamp(0.7, 1.8)
        : 1.0;

    final baseStyle = TextStyle(
      color: s.color,
      fontSize: s.fontSize * scale,
      fontWeight: s.bold ? FontWeight.bold : FontWeight.w500,
      fontStyle: docStyle?.italic == true && style == null
          ? FontStyle.italic
          : FontStyle.normal,
      height: 1.35,
    );

    final body = Stack(
      alignment: Alignment.center,
      children: [
        if (s.outlineWidth > 0)
          Text(
            text,
            textAlign: TextAlign.center,
            style: baseStyle.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = s.outlineWidth * 2
                ..strokeCap = StrokeCap.round
                ..strokeJoin = StrokeJoin.round
                ..color = s.outlineColor,
            ),
          ),
        if (s.shadowDepth > 0)
          Text(
            text,
            textAlign: TextAlign.center,
            style: baseStyle.copyWith(
              shadows: [
                Shadow(
                  blurRadius: 4 * s.shadowDepth,
                  color: Colors.black,
                  offset: Offset(0, s.shadowDepth),
                ),
                Shadow(
                  blurRadius: 10 * s.shadowDepth,
                  color: Colors.black87,
                ),
              ],
            ),
          ),
        Text(text, textAlign: TextAlign.center, style: baseStyle),
      ],
    );

    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) => Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              0,
              24,
              (constraints.maxHeight * s.bottomFraction)
                  .clamp(8.0, double.infinity) +
                  MediaQuery.paddingOf(context).bottom,
            ),
            child: Opacity(
              opacity: s.opacity.clamp(0.0, 1.0),
              child: body,
            ),
          ),
        ),
      ),
    );
  }
}
