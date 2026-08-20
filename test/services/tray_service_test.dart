import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:subtitle_studio_pro/l10n/app_localizations_en.dart';
import 'package:subtitle_studio_pro/l10n/app_localizations_zh.dart';
import 'package:subtitle_studio_pro/l10n/l10n.dart';
import 'package:subtitle_studio_pro/services/tray_service.dart';

/// 系统托盘（v2.0）：菜单构建与 key 动作分发为纯逻辑，可在无插件环境验证。
///
/// tray_manager 的 setIcon/setContextMenu 依赖原生插件，仅在真机生效；
/// 本测试覆盖：菜单项结构、暂停状态驱动的 label 切换、key → 回调分发。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildMenu 菜单构建', () {
    test('运行中：包含显示主窗 / 暂停队列 / 退出，顺序与分隔符合预期', () {
      final menu = TrayService.buildMenu(paused: false);
      final items =
          (menu.items ?? const <MenuItem>[]).where((i) => i.type != 'separator').toList();
      expect(items.map((i) => i.key), [
        TrayService.kShow,
        TrayService.kTogglePause,
        TrayService.kExit,
      ]);
      expect(
          items.firstWhere((i) => i.key == TrayService.kTogglePause).label,
          '暂停队列');
    });

    test('已暂停：切换项 label 变为恢复队列', () {
      final menu = TrayService.buildMenu(paused: true);
      final toggle = (menu.items ?? const <MenuItem>[])
          .firstWhere((i) => i.key == TrayService.kTogglePause);
      expect(toggle.label, '恢复队列');
    });

    test('语言切换：L10nHolder 更新后菜单 label 跟随（默认回退中文）', () {
      // 默认（未 update）：中文模板
      expect(TrayService.buildMenu(paused: false).items!
          .firstWhere((i) => i.key == TrayService.kShow)
          .label, '显示主窗');

      // 更新为英文 → 全部菜单项英文
      L10nHolder.update(AppLocalizationsEn());
      final en = TrayService.buildMenu(paused: true);
      expect(en.items!.firstWhere((i) => i.key == TrayService.kShow).label,
          'Show Main Window');
      expect(en.items!.firstWhere((i) => i.key == TrayService.kTogglePause).label,
          'Resume Queue');
      expect(en.items!.firstWhere((i) => i.key == TrayService.kExit).label,
          'Exit');

      // 还原全局，避免影响其他测试
      L10nHolder.update(AppLocalizationsZh());
    });
  });

  group('handleMenuKey 动作分发', () {
    test('三个 key 分别触发对应回调，未知 key 安全忽略', () {
      var shown = 0;
      var toggled = 0;
      var exited = 0;
      void handle(String key) => TrayService.handleMenuKey(
            key,
            onShow: () => shown++,
            onTogglePause: () => toggled++,
            onExit: () => exited++,
          );

      handle(TrayService.kShow);
      handle(TrayService.kTogglePause);
      handle(TrayService.kExit);
      handle('unknown');

      expect(shown, 1);
      expect(toggled, 1);
      expect(exited, 1);
    });
  });
}
