import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import 'about_screen.dart';
import 'burn_screen.dart';
import 'history_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'subtitle_list_screen.dart';
import 'task_queue_screen.dart';
import 'track_screen.dart';
import 'transcode_screen.dart';
import 'translate_screen.dart';
import 'whisper_screen.dart';

/// 应用主框架：NavigationRail 侧边导航（桌面宽屏）+ 内容区。
/// 各功能页用 IndexedStack 保持状态（切换导航不丢失）。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  /// 已访问过的页面（懒加载：未访问的用占位，首次进入才构建）。首页默认可见。
  final List<bool> _visited = [
    true,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
    false,
  ];

  /// 导航目的地（图标 + label）。
  static const List<(IconData, String)> _destinations = [
    (Icons.dashboard_outlined, '首页'),
    (Icons.closed_caption_outlined, '字幕库'),
    (Icons.theaters, '字幕烧录'),
    (Icons.swap_vert_circle_outlined, '轨道处理'),
    (Icons.compress, '转码压缩'),
    (Icons.translate, 'AI 翻译'),
    (Icons.mic_none, 'Whisper字幕'),
    (Icons.queue, '任务队列'),
    (Icons.history, '历史记录'),
  ];

  /// 任务队列在侧边栏中的索引（Ctrl+Q 直达）。
  static const _queueIndex = 7;

  /// Ctrl+1..9 对应的数字键（与 [_destinations] 顺序一一对应）。
  static const List<LogicalKeyboardKey> _pageKeys = [
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  late final List<Widget> _pages = [
    HomeScreen(onNavigate: _select),
    const SubtitleListScreen(),
    const BurnScreen(),
    const TrackScreen(),
    const TranscodeScreen(),
    const TranslateScreen(),
    const WhisperScreen(),
    const TaskQueueScreen(),
    const HistoryScreen(),
  ];

  /// 字幕库在侧边栏中的索引（文件关联双击字幕启动时直达）。
  static const _libraryIndex = 1;

  @override
  void initState() {
    super.initState();
    // 文件关联（v1.5）：双击字幕文件启动 → 自动切到字幕库（该页
    // initState 会消费同一 provider 把文件播种进列表）
    if (ref.read(startupSubtitleFilesProvider).isNotEmpty) {
      _visited[_libraryIndex] = true;
      _index = _libraryIndex;
    }
  }

  void _select(int i) {
    setState(() {
      _index = i;
      _visited[i] = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // 全局快捷键：Ctrl+1..9 直达功能页、Ctrl+Q 打开任务队列。
    // Focus(autofocus) 保证无控件聚焦时快捷键仍生效；焦点进入页面内
    // 任意子控件（输入框/按钮）时作为祖先仍可响应，弹出路由（设置等）
    // 打开时焦点移出 shell，快捷键自然失效。
    return CallbackShortcuts(
      bindings: {
        for (var i = 0; i < _pageKeys.length; i++)
          SingleActivator(_pageKeys[i], control: true): () => _select(i),
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true): () =>
            _select(_queueIndex),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: _index,
                onDestinationSelected: _select,
                // 紧凑标签模式：仅选中项显示文字，矮窗口也不溢出
                labelType: NavigationRailLabelType.selected,
                useIndicator: true,
                minWidth: 76,
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 18, 8, 22),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              scheme.primary,
                              scheme.tertiary,
                            ],
                          ),
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.35),
                              blurRadius: 12,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.subtitles,
                          size: 24,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                trailing: Expanded(
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: '设置',
                            icon: const Icon(Icons.settings_outlined),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const SettingsScreen()),
                            ),
                          ),
                          IconButton(
                            tooltip: '关于',
                            icon: const Icon(Icons.info_outline),
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const AboutScreen()),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                destinations: [
                  for (final (icon, label) in _destinations)
                    NavigationRailDestination(
                      icon: Icon(icon),
                      selectedIcon: Icon(icon, color: scheme.primary),
                      label: Text(label),
                    ),
                ],
              ),
              VerticalDivider(
                width: 1,
                color: scheme.outlineVariant.withValues(alpha: 0.5),
              ),
              Expanded(
                child: IndexedStack(
                  index: _index,
                  children: [
                    // 懒加载：未访问的页面用占位，首次进入才构建并保持状态
                    for (var i = 0; i < _pages.length; i++)
                      _visited[i] ? _pages[i] : const SizedBox.shrink(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
