import 'package:flutter/material.dart';

import '../core/constants.dart';

/// 关于页（v2.2.1 更新）：纯信息页——品牌横幅 + 定位介绍 + 能力速览 +
/// 技术栈 + 格式支持 + 当前版本更新日志。
/// 检查更新入口位于设置页「维护」分组（版本与更新区块）。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  // ───────────────────────── 数据 ─────────────────────────

  static const _capabilities = [
    (Icons.library_books_outlined, '字幕库', '导入排序预览，格式互转与编码检测'),
    (Icons.local_fire_department_outlined, '字幕烧录', 'libass 硬字幕压制，保留 ASS 特效'),
    (Icons.translate, 'AI 翻译', '多配置档案一键切换，流式直播与用量统计'),
    (Icons.mic_none, 'Whisper 字幕', '本地语音转写，模型预下载管理'),
    (Icons.swap_vert_circle_outlined, '轨道处理', 'MKV 提取与封装，对齐 gMKVExtractGUI'),
    (Icons.compress, '转码压缩', '分辨率、码率、CRF 全参数可调'),
    (Icons.play_circle_outline, '视频预览', '内置播放器，字幕样式实时调整'),
    (Icons.queue, '任务队列', '双车道调度，实时进度可取消'),
    (Icons.history, '历史记录', '参数与产物自动留痕，可回溯定位'),
  ];

  static const _stack = [
    ('Flutter', '桌面应用框架 · Material 3 · 亮 / 暗 / 跟随系统主题'),
    ('FFmpeg', '字幕烧录（libass 渲染 ASS 特效）与视频转码压缩'),
    ('MKVToolNix', '轨道提取（mkvextract）与封装（mkvmerge），支持应用内便携导入'),
    ('Whisper', '本地语音识别转写（openai-whisper / faster-whisper / whisper.cpp 多后端）'),
    ('Hive', '历史与配置的本机存储；API Key 与处理过程均不上传'),
  ];

  /// 更新日志：仅保留最新版本的更新内容（发版时整体替换）。
  static const _changelogTheme = 'AI 优化与直播回看';
  static const _changelogNotes = [
    'JSON 输出模式：降低模型输出非 JSON 的重试失败（省重复请求）',
    '流式译文逐字上屏与 token 用量统计',
    '失败批次自动拆半重试（30→15→8 条）',
    '多配置档案一键切换，主备自动降级',
    '翻译内容缓存：相似台词零成本命中',
    '超时 / 重试 / 并发参数开放设置',
    '直播详情回看：完整翻译日志随时查看（对齐 Whisper）',
    '关于页新增更新日志；移除 token 计费预估',
  ];

  // ───────────────────────── 构建 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeOutCubic,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, 14 * (1 - t)),
                    child: child,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _heroBand(scheme, text),
                    const SizedBox(height: 32),
                    _intro(text, scheme),
                    _sectionTitle(context, '核心能力',
                        '从获取字幕到成片压制的完整流水线'),
                    _capabilityGrid(scheme),
                    const SizedBox(height: 32),
                    _sectionTitle(context, '技术栈',
                        '外部工具均可自定义路径，支持便携导入'),
                    ..._stackRows(scheme),
                    const SizedBox(height: 32),
                    _sectionTitle(context, '格式支持',
                        '覆盖字幕组日常交付的主流容器与编码'),
                    _formatChips(scheme),
                    const SizedBox(height: 32),
                    _sectionTitle(context, '更新日志', '当前版本的主要更新内容'),
                    _changelogCard(scheme, text),
                    const SizedBox(height: 36),
                    Divider(
                        color: scheme.outlineVariant.withValues(alpha: 0.6)),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        '${AppConstants.appName} v${AppConstants.appVersion} · '
                        '为字幕组与个人压片工作流而生',
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── 品牌横幅 ─────────────────────────

  Widget _heroBand(ColorScheme scheme, TextTheme text) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.subtitles, size: 34, color: Colors.white),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppConstants.appName,
                  style: text.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '字幕工作流一体化桌面工具',
                  style: text.bodyLarge
                      ?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'v${AppConstants.appVersion}',
              style: text.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: Colors.white,
                fontFamily: 'Consolas',
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── 定位介绍 ─────────────────────────

  Widget _intro(TextTheme text, ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Subtitle Studio Pro 把「获取字幕 → 翻译 → 转写 → 烧录 → 封装 → 压制」'
          '整条字幕制作链路收进一个 Windows 桌面应用：无需命令行，'
          '无需在多个工具之间来回搬运文件。',
          style: text.bodyMedium?.copyWith(height: 1.7),
        ),
        const SizedBox(height: 10),
        Text(
          '轨道处理基于 MKVToolNix（交互对齐 gMKVExtractGUI），烧录与转码基于 '
          'FFmpeg，语音转写调用本地 Whisper，翻译接入你自己的 OpenAI 兼容 API——'
          '所有外部工具都支持自定义路径或导入应用内便携使用，处理过程全部本地完成。',
          style: text.bodyMedium?.copyWith(
            height: 1.7,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  // ───────────────────────── 分区标题 ─────────────────────────

  Widget _sectionTitle(BuildContext context, String title, String desc) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── 核心能力网格 ─────────────────────────

  Widget _capabilityGrid(ColorScheme scheme) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final twoCol = constraints.maxWidth >= 620;
        final itemWidth =
            twoCol ? (constraints.maxWidth - 14) / 2 : constraints.maxWidth;
        return Wrap(
          spacing: 14,
          runSpacing: 10,
          children: [
            for (final (icon, title, desc) in _capabilities)
              SizedBox(
                width: itemWidth,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      margin: const EdgeInsets.only(top: 1),
                      decoration: BoxDecoration(
                        color: scheme.primaryContainer.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon,
                          size: 16, color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            desc,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }

  // ───────────────────────── 技术栈行 ─────────────────────────

  List<Widget> _stackRows(ColorScheme scheme) {
    return [
      for (var i = 0; i < _stack.length; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              SizedBox(
                width: 150,
                child: Text(
                  _stack[i].$1,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                    color: scheme.primary,
                    fontFamily: 'Consolas',
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  _stack[i].$2,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  // ───────────────────────── 更新日志卡片 ─────────────────────────

  Widget _changelogCard(ColorScheme scheme, TextTheme text) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: scheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'v${AppConstants.appVersion}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'Consolas',
                    color: scheme.onPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _changelogTheme,
                style:
                    text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final note in _changelogNotes)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ───────────────────────── 格式支持标签 ─────────────────────────

  Widget _formatChips(ColorScheme scheme) {
    const groups = [
      ('视频', AppConstants.videoExtensions),
      ('字幕', AppConstants.subtitleExtensions),
      ('音频', AppConstants.audioExtensions),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var g = 0; g < groups.length; g++) ...[
          Padding(
            padding: EdgeInsets.only(top: g == 0 ? 4 : 10, bottom: 6),
            child: Text(
              groups[g].$1,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final ext in groups[g].$2)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color:
                        scheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    ext.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'Consolas',
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
            ],
          ),
        ],
        const Padding(
          padding: EdgeInsets.only(top: 10),
          child: Text(
            '文本编码：UTF-8 / GBK / BIG5 自动检测互转',
            style: TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}
