import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/queue_task.dart';
import '../providers/app_providers.dart';
import '../services/mkvtoolnix/mkvtoolnix_service.dart';
import '../services/update/update_service.dart';
import '../widgets/feature_grid.dart';
import '../widgets/progress_panel.dart';
import 'about_screen.dart';
import 'player_screen.dart';

/// 首页概览（NavigationRail 的第 0 项）：功能入口网格 + 环境状态 + 运行中任务。
///
/// [onNavigate]：切换到主导航的某个功能页（由 HomeShell 注入）。
class HomeScreen extends ConsumerWidget {
  final void Function(int index)? onNavigate;

  const HomeScreen({super.key, this.onNavigate});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        children: [
          Text('Subtitle Studio Pro',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          // 启动检查发现新版本（v1.5-2）：可关闭提示条，点击进关于页升级
          ValueListenableBuilder<UpdateInfo?>(
            valueListenable: startupUpdate,
            builder: (context, info, _) => info == null
                ? const SizedBox.shrink()
                : _updateBanner(context, info),
          ),
          if (!settings.ffmpegReady) _ffmpegWarning(context),
          // 首页常驻 HomeShell（IndexedStack），设置页导入工具后须靠
          // notifier 通知横幅消失，不能静态读取 isAvailable
          ValueListenableBuilder<bool>(
            valueListenable: MkvToolNixService.instance.availability,
            builder: (context, mkvReady, _) => mkvReady
                ? const SizedBox.shrink()
                : _mkvtoolnixWarning(context),
          ),
          WorkflowSection(
            title: '字幕工作流',
            icon: Icons.subtitles,
            features: [
              FeatureEntry(
                title: '字幕库',
                subtitle: '导入 / 排序 / 预览字幕，格式转换',
                icon: Icons.closed_caption_outlined,
                color: const Color(0xFF3D5AFE),
                onTap: () => onNavigate?.call(1),
              ),
              FeatureEntry(
                title: '字幕烧录',
                subtitle: '硬字幕压入视频（SRT/ASS），可选样式',
                icon: Icons.theaters,
                color: const Color(0xFFFF6D00),
                onTap: () => onNavigate?.call(2),
              ),
              FeatureEntry(
                title: '轨道处理',
                subtitle: '提取任意轨道 / MKV 封装字幕音频字体',
                icon: Icons.swap_vert_circle_outlined,
                color: const Color(0xFF3949AB),
                onTap: () => onNavigate?.call(3),
              ),
              FeatureEntry(
                title: 'AI 翻译',
                subtitle: '批量翻译字幕，保留时间轴与样式，可双语',
                icon: Icons.translate,
                color: const Color(0xFF43A047),
                onTap: () => onNavigate?.call(5),
              ),
              FeatureEntry(
                title: 'Whisper字幕',
                subtitle: 'Whisper 识别视频 / 音频语音，批量生成字幕',
                icon: Icons.mic_none,
                color: const Color(0xFF7CB342),
                onTap: () => onNavigate?.call(6),
              ),
            ],
          ),
          WorkflowSection(
            title: '视频处理',
            icon: Icons.movie_filter,
            features: [
              FeatureEntry(
                title: '转码压缩',
                subtitle: '转格式 / 调分辨率码率 / 一键压缩',
                icon: Icons.compress,
                color: const Color(0xFF00ACC1),
                onTap: () => onNavigate?.call(4),
              ),
              FeatureEntry(
                title: '视频预览',
                subtitle: '播放列表 · 轨道切换 · 字幕样式实时调整',
                icon: Icons.play_circle_outline,
                color: const Color(0xFFF4511E),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PlayerScreen()),
                ),
              ),
            ],
          ),
          WorkflowSection(
            title: '任务与记录',
            icon: Icons.inventory_2,
            features: [
              FeatureEntry(
                title: '任务队列',
                subtitle: '批量任务、实时进度、可取消',
                icon: Icons.queue,
                color: const Color(0xFF00897B),
                // 独立子组件监听队列，避免任务进度导致整个首页重建
                badgeWidget: const _QueueBadge(),
                onTap: () => onNavigate?.call(7),
              ),
              FeatureEntry(
                title: '历史记录',
                subtitle: '自动保存每次操作参数与结果',
                icon: Icons.history,
                color: const Color(0xFF5E35B1),
                onTap: () => onNavigate?.call(8),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _QueuePanel(),
        ],
      ),
    );
  }

  /// 新版本提示条（v1.5-2 启动检查）：点击进关于页查看说明并升级；
  /// 关闭按钮仅隐藏本次会话的提示。
  Widget _updateBanner(BuildContext context, UpdateInfo info) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.new_releases_outlined,
                size: 18, color: scheme.onPrimaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '发现新版本 v${info.version}，点击查看更新内容',
                style: TextStyle(
                    fontSize: 13, color: scheme.onPrimaryContainer),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AboutScreen()),
              ),
              child: const Text('查看'),
            ),
            IconButton(
              tooltip: '本次不再提示',
              icon: Icon(Icons.close,
                  size: 16, color: scheme.onPrimaryContainer),
              onPressed: () => startupUpdate.value = null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _ffmpegWarning(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.warning_amber, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '未检测到可用的 FFmpeg。字幕烧录 / 转码将无法工作。'
                '请安装 FFmpeg 或在「设置」中指定 ffmpeg.exe 路径。',
                style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mkvtoolnixWarning(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(Icons.extension_off, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '未检测到 MKVToolNix。轨道提取 / 封装将无法工作。'
                '请安装 MKVToolNix，或在「设置 → MKVToolNix」中配置目录 / 导入。',
                style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 任务队列角标：独立监听队列状态（待处理 + 运行中数量）。
class _QueueBadge extends ConsumerWidget {
  const _QueueBadge();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(queueProvider).tasks.where((t) {
      return t.status == TaskStatus.pending || t.status == TaskStatus.running;
    }).length;
    if (count == 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.error,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
            color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 运行中任务面板：独立监听队列，避免任务进度导致首页主体整体重建。
class _QueuePanel extends ConsumerWidget {
  const _QueuePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider);
    final tasks = queue.tasks;
    if (tasks.isEmpty) return const SizedBox.shrink();
    return ProgressPanel(tasks: tasks, onCancelAll: () => queue.cancelAll());
  }
}
