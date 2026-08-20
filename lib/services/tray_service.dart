import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/l10n.dart';
import 'queue_service.dart';

/// 系统托盘常驻服务（v2.0）：
/// - 关闭窗口 → 隐藏到托盘，任务后台继续；
/// - 左键托盘图标 → 显示主窗；右键 → 弹出菜单；
/// - 菜单：显示主窗 / 暂停(恢复)队列 / 退出。
///
/// 菜单构建与 key 分发为纯静态逻辑（可测）；tray_manager 原生调用仅在
/// 桌面真机生效。
class TrayService with TrayListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  static const kShow = 'tray_show';
  static const kTogglePause = 'tray_toggle_pause';
  static const kExit = 'tray_exit';

  bool _initialized = false;
  bool _menuPaused = false;
  VoidCallback? _onExit;

  /// main() 中初始化托盘图标与菜单。[onExit] 为「退出」入口（清理托盘后销毁窗口）。
  Future<void> init({VoidCallback? onExit}) async {
    if (_initialized) return;
    _initialized = true;
    _onExit = onExit;
    await trayManager.setIcon('assets/app_icon.ico');
    await trayManager.setToolTip('Subtitle Studio Pro');
    _menuPaused = QueueService.instance.isPaused;
    await trayManager.setContextMenu(buildMenu(paused: _menuPaused));
    trayManager.addListener(this);
    QueueService.instance.addListener(_onQueueChanged);
  }

  /// 托盘菜单（[paused] 驱动暂停/恢复项 label，文案跟随当前语言）。
  static Menu buildMenu({required bool paused}) {
    final l10n = L10nHolder.current;
    return Menu(
      items: [
        MenuItem(key: kShow, label: l10n.trayShow),
        MenuItem.separator(),
        MenuItem(
          key: kTogglePause,
          label: paused ? l10n.trayResumeQueue : l10n.trayPauseQueue,
        ),
        MenuItem.separator(),
        MenuItem(key: kExit, label: l10n.trayExit),
      ],
    );
  }

  /// key → 动作分发（纯逻辑，测试注入回调验证）。
  static void handleMenuKey(
    String? key, {
    VoidCallback? onShow,
    VoidCallback? onTogglePause,
    VoidCallback? onExit,
  }) {
    switch (key) {
      case kShow:
        onShow?.call();
      case kTogglePause:
        onTogglePause?.call();
      case kExit:
        onExit?.call();
      default:
        break;
    }
  }

  /// 队列暂停状态变化时刷新菜单（进度高频通知只做一次状态比对）。
  void _onQueueChanged() {
    final paused = QueueService.instance.isPaused;
    if (paused == _menuPaused || !_initialized) return;
    _menuPaused = paused;
    trayManager.setContextMenu(buildMenu(paused: paused));
  }

  /// 语言切换后刷新菜单文案（未初始化 / 非桌面环境时忽略）。
  Future<void> refreshMenu() async {
    if (!_initialized) return;
    await trayManager.setContextMenu(buildMenu(paused: _menuPaused));
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() => _showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) => handleMenuKey(
        menuItem.key,
        onShow: _showWindow,
        onTogglePause: QueueService.instance.togglePause,
        onExit: _onExit,
      );

  /// 应用退出前清理：移除监听并销毁托盘图标。
  Future<void> shutdown() async {
    if (!_initialized) return;
    _initialized = false;
    trayManager.removeListener(this);
    QueueService.instance.removeListener(_onQueueChanged);
    await trayManager.destroy();
  }
}
