import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants.dart';
import '../services/tray_service.dart';
import '../services/update/update_service.dart';

/// 关于页（v1.5 重设计）：品牌横幅 + 版本与更新入口 + 能力速览 +
/// 技术栈与格式支持。
///
/// 排版原则：品牌横幅是全页唯一的视觉锚点（渐变底 + 大图标 + 产品名），
/// 其余内容用分组标题、细分隔线与留白组织层级；「检查更新」是唯一
/// 主动作。更新流程：GitHub Releases 检查 → 下载安装包 → 静默升级
/// 并退出本应用。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key, this.updateService});

  /// 更新服务（测试注入 fake；默认单例走 GitHub API）。
  final UpdateService? updateService;

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

/// 更新流程阶段。
enum _UpdatePhase { idle, checking, upToDate, available, downloading, failed }

class _AboutScreenState extends State<AboutScreen> {
  _UpdatePhase _phase = _UpdatePhase.idle;
  UpdateInfo? _update;
  double _progress = 0;
  String? _error;

  UpdateService get _svc => widget.updateService ?? UpdateService.instance;

  // ───────────────────────── 数据 ─────────────────────────

  static const _capabilities = [
    (Icons.library_books_outlined, '字幕库', '导入排序预览，格式互转与编码检测'),
    (Icons.local_fire_department_outlined, '字幕烧录', 'libass 硬字幕压制，保留 ASS 特效'),
    (Icons.translate, 'AI 翻译', 'OpenAI 兼容 API，保留时间轴，可双语'),
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

  // ───────────────────────── 更新流程 ─────────────────────────

  Future<void> _checkUpdate() async {
    setState(() {
      _phase = _UpdatePhase.checking;
      _error = null;
    });
    try {
      final info =
          await _svc.checkLatest(currentVersion: AppConstants.appVersion);
      if (!mounted) return;
      setState(() {
        _update = info;
        _phase =
            info == null ? _UpdatePhase.upToDate : _UpdatePhase.available;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = '检查更新失败：$e';
      });
    }
  }

  Future<void> _upgrade() async {
    final info = _update;
    final url = info?.setupUrl;
    if (info == null || url == null) return;
    setState(() {
      _phase = _UpdatePhase.downloading;
      _progress = 0;
    });
    try {
      final dest =
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'SubtitleStudioPro-${info.version}-setup.exe';
      await _svc.downloadSetup(url, dest, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      await _svc.launchInstaller(dest);
      // 安装程序已独立启动（/SILENT），退出本应用让位升级
      await _exitApp();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.failed;
        _error = '升级失败：$e';
      });
    }
  }

  Future<void> _exitApp() async {
    try {
      await TrayService.instance.shutdown();
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {}
  }

  Future<void> _openReleasePage() async {
    final url = _update?.releaseUrl;
    if (url == null || url.isEmpty) return;
    try {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } catch (_) {}
  }

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
                    _updatePanel(scheme, text),
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

  // ───────────────────────── 更新面板 ─────────────────────────

  Widget _updatePanel(ColorScheme scheme, TextTheme text) {
    final busy =
        _phase == _UpdatePhase.checking || _phase == _UpdatePhase.downloading;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '版本与更新',
                  style: text.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : _checkUpdate,
                icon: busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, size: 16),
                label: Text(
                  _phase == _UpdatePhase.checking
                      ? '检查中…'
                      : _phase == _UpdatePhase.downloading
                          ? '下载中…'
                          : '检查更新',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ..._updateStatusBody(scheme, text),
        ],
      ),
    );
  }

  List<Widget> _updateStatusBody(ColorScheme scheme, TextTheme text) {
    switch (_phase) {
      case _UpdatePhase.idle:
        return [
          Text(
            '当前版本 v${AppConstants.appVersion}，点击右上角按钮检查新版本。',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ];
      case _UpdatePhase.checking:
        return [
          Text(
            '正在连接 GitHub Releases 检查更新…',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ];
      case _UpdatePhase.upToDate:
        return [
          Row(
            children: [
              Icon(Icons.check_circle_outline,
                  size: 16, color: Colors.green.shade600),
              const SizedBox(width: 6),
              Text(
                '已是最新版本（v${AppConstants.appVersion}）',
                style: text.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ];
      case _UpdatePhase.available:
        final u = _update!;
        return [
          Row(
            children: [
              Icon(Icons.new_releases_outlined,
                  size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                '发现新版本 v${u.version}',
                style: text.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          if (u.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                u.notes.trim(),
                maxLines: 10,
                style: text.bodySmall?.copyWith(height: 1.6),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: u.setupUrl != null ? _upgrade : null,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('立即升级'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _openReleasePage,
                child: const Text('查看发布页'),
              ),
              if (u.setupUrl == null)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    '该版本未提供安装包，请前往发布页下载',
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ];
      case _UpdatePhase.downloading:
        final u = _update;
        return [
          Text(
            '正在下载 v${u?.version ?? ''} 安装包（${(_progress * 100).round()}%），'
            '完成后将自动升级并重启应用。',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progress,
              minHeight: 6,
              backgroundColor:
                  scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            ),
          ),
        ];
      case _UpdatePhase.failed:
        return [
          Text(
            _error ?? '检查更新失败',
            style: text.bodySmall?.copyWith(color: scheme.error),
          ),
        ];
    }
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
