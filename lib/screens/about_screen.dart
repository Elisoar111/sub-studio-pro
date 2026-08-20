import 'package:flutter/material.dart';

import '../core/constants.dart';

/// 关于页：项目定位、核心功能、技术栈与格式支持的完整介绍。
///
/// 排版原则（工具型产品界面）：不用卡片堆砌，用留白、分组标题、
/// 分隔线与行式列表组织层级；产品名是全页最响的文字。
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  // ───────────────────────── 功能条目数据 ─────────────────────────

  static const _subtitleGroup = [
    (
      Icons.library_books_outlined,
      '字幕库',
      '集中导入与管理字幕：按时间轴排序、内容预览，'
          'SRT / ASS / SSA / VTT / SUB 互转，'
          'GBK / BIG5 编码自动检测并转 UTF-8',
    ),
    (
      Icons.local_fire_department_outlined,
      '字幕烧录',
      'FFmpeg + libass 硬字幕压制：完整保留 ASS 样式与特效，'
          '或按预设统一观感（白字黑边 / 经典黄字 / 大字描边）',
    ),
    (
      Icons.translate,
      'AI 翻译',
      '接入任意 OpenAI 兼容 API（OpenAI / DeepSeek / 中转）：'
          '只翻译文本，时间轴与样式标签原样不动，'
          '输出「源文件名_语言码」（如 demo_en.srt），'
          '可选双语内容合并「源文件名_mixed」',
    ),
    (
      Icons.mic_none,
      'Whisper 字幕',
      '本地 openai-whisper 批量转写视频 / 音频为字幕：'
          '转写结果实时输出、可随时回看，模型可预下载管理，'
          '输出「源文件名_模型名」',
    ),
    (
      Icons.swap_vert_circle_outlined,
      '轨道处理',
      'MKVToolNix 工具链（交互对齐 gMKVExtractGUI v2.15）：'
          '提取 MKV 的视频 / 音频 / 字幕 / 章节 / 字体附件，'
          '反向把字幕、音轨、字体封装为标准 MKV，轨道可勾选删减',
    ),
  ];

  static const _videoGroup = [
    (
      Icons.compress,
      '转码压缩',
      'FFmpeg 转封装 / 转码：分辨率、码率、CRF、x264 预设、'
          '帧率、音轨编码全部可调，一键压缩'
    ),
    (
      Icons.play_circle_outline,
      '视频预览',
      '内置播放器：播放列表、音轨 / 字幕轨切换、'
          '字幕样式实时调整、倍速播放',
    ),
  ];

  static const _taskGroup = [
    (
      Icons.queue,
      '任务队列',
      '所有功能任务串行执行：实时进度与日志、可取消、失败可重试',
    ),
    (
      Icons.history,
      '历史记录',
      '自动保存每次任务的完整参数与产物路径，'
          '可回溯重跑、在文件资源管理器中定位',
    ),
  ];

  static const _stack = [
    ('Flutter', 'Windows 桌面应用框架；Material 3 + 动态种子色主题（亮 / 暗 / 跟随系统）'),
    ('FFmpeg', '字幕烧录（libass 渲染 ASS 特效）与视频转码压缩'),
    ('MKVToolNix', '轨道提取（mkvextract）与封装（mkvmerge）；支持导入应用内便携使用'),
    ('openai-whisper', '本地语音识别转写（Python CLI，模型缓存在本机，不联网上传）'),
    ('Hive', '任务历史与本机配置存储；API Key 仅保存在本机'),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        children: [
          // 入场：整页内容一次淡入 + 轻微上移，建立层级即可
          TweenAnimationBuilder<double>(
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
                _brandHeader(scheme, text),
                const SizedBox(height: 28),
                _intro(text, scheme),
                const SizedBox(height: 36),
                _sectionTitle(context, '核心功能', '从字幕获取到成片压制的一条流水线'),
                _groupHeader(context, '字幕工作流'),
                ..._featureRows(_subtitleGroup, scheme),
                _groupHeader(context, '视频处理'),
                ..._featureRows(_videoGroup, scheme),
                _groupHeader(context, '任务与记录'),
                ..._featureRows(_taskGroup, scheme),
                const SizedBox(height: 36),
                _sectionTitle(context, '技术栈', '外部工具均可自定义路径，支持便携导入'),
                ..._stackRows(scheme),
                const SizedBox(height: 36),
                _sectionTitle(context, '格式支持', '覆盖字幕组日常交付的主流容器与编码'),
                _formatChips(scheme),
                const SizedBox(height: 40),
                Divider(color: scheme.outlineVariant.withValues(alpha: 0.6)),
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
        ],
      ),
    );
  }

  // ───────────────────────── 品牌区（全页视觉锚点） ─────────────────────────

  Widget _brandHeader(ColorScheme scheme, TextTheme text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [scheme.primary, scheme.tertiary],
            ),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: 0.35),
                blurRadius: 18,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: const Icon(Icons.subtitles, size: 30, color: Colors.white),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppConstants.appName,
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '字幕工作流一体化桌面工具',
                style: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            'v${AppConstants.appVersion}',
            style: text.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: scheme.onPrimaryContainer,
              fontFamily: 'Consolas',
            ),
          ),
        ),
      ],
    );
  }

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

  // ───────────────────────── 分区标题 / 小组标题 ─────────────────────────

  Widget _sectionTitle(BuildContext context, String title, String desc) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
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
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _groupHeader(BuildContext context, String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.primary,
                ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────── 功能行（图标 + 名称 + 说明） ─────────────────────────

  List<Widget> _featureRows(
    List<(IconData, String, String)> features,
    ColorScheme scheme,
  ) {
    return [
      for (final (icon, title, desc) in features)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                margin: const EdgeInsets.only(top: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, size: 17, color: scheme.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      desc,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.55,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
    ];
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
            padding: EdgeInsets.only(top: g == 0 ? 12 : 10, bottom: 6),
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
                    color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
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
