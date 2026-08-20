import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/settings_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// 设置页结构化（ROADMAP v1.1 P1）：宽窗口左侧锚点导航（外观 / 输出 /
/// 环境依赖 / AI / 维护）+ 右侧滚动内容；点击锚点滚动到对应分组并高亮；
/// 窄窗口退化为纯滚动列表（无锚点）。
///
/// 单测试体：SettingsProvider.instance 是共享单例，ProviderScope 销毁时
/// 被 Riverpod dispose，多 testWidgets 会串扰（同 home_shell_shortcuts_test）。
void main() {
  setUpAll(() async {
    // 不 init StorageService：测试环境 Hive 无可用目录，未初始化时
    // getSetting 走内存 fallback（默认值），设置页读写均安全。
    await FfmpegService.create();
    await SettingsProvider.instance.load();
  });

  /// 文本是否在测试视口内（滚动跳转后分组标题应滚入可见区）。
  bool onScreen(WidgetTester tester, String text) {
    final box = tester.renderObject<RenderBox>(find.text(text));
    final top = box.localToGlobal(Offset.zero).dy;
    final view = tester.view;
    final height = view.physicalSize.height / view.devicePixelRatio;
    return top >= 0 && top < height;
  }

  testWidgets('锚点导航：分组齐全、初始高亮外观、点击跳转联动高亮、窄窗口退化', (tester) async {
    // ── 宽窗口（1280×800）：锚点导航模式 ──
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: SettingsScreen())),
    );
    await tester.pumpAndSettle();

    // 五个锚点齐全
    for (final label in ['外观', '输出', '环境依赖', 'AI', '维护']) {
      expect(find.widgetWithText(ListTile, label), findsOneWidget,
          reason: '缺少锚点导航项：$label');
    }

    // 初始停在顶部：高亮「外观」，其余不高亮
    bool selected(String label) =>
        tester.widget<ListTile>(find.widgetWithText(ListTile, label)).selected;
    expect(selected('外观'), isTrue, reason: '初始应高亮第一个分组「外观」');
    expect(selected('环境依赖'), isFalse);

    // 初始视口内是主题区（外观分组），FFmpeg 区应在视口外
    expect(onScreen(tester, '主题设置'), isTrue);
    expect(onScreen(tester, 'FFmpeg 路径'), isFalse,
        reason: '未跳转前环境依赖分组应在视口外');

    // 点击「环境依赖」→ FFmpeg 区块滚入视口，高亮切换
    await tester.tap(find.widgetWithText(ListTile, '环境依赖'));
    await tester.pumpAndSettle();

    expect(onScreen(tester, 'FFmpeg 路径'), isTrue,
        reason: '点击锚点后 FFmpeg 区块应滚入视口');
    expect(selected('环境依赖'), isTrue, reason: '跳转后应高亮「环境依赖」');
    expect(selected('外观'), isFalse);

    // 点击「AI」→ AI 翻译区滚入视口
    await tester.tap(find.widgetWithText(ListTile, 'AI'));
    await tester.pumpAndSettle();
    expect(onScreen(tester, 'AI 字幕翻译'), isTrue,
        reason: '点击「AI」锚点后 AI 翻译分组应滚入视口');
    expect(selected('AI'), isTrue);

    // 手动滚回顶部 → 高亮回到「外观」（滚动联动）
    await tester.drag(
        find.byType(Scrollable).first, const Offset(0, 4000));
    await tester.pumpAndSettle();
    expect(selected('外观'), isTrue,
        reason: '滚回顶部后高亮应跟随回到「外观」');

    // ── 窄窗口（800×600 < 锚点模式阈值）：退化为纯滚动列表 ──
    await tester.binding.setSurfaceSize(const Size(800, 600));
    tester.view.physicalSize = const Size(800, 600);
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListTile, '外观'), findsNothing,
        reason: '窄窗口不应显示锚点导航');
    expect(find.text('主题设置'), findsOneWidget,
        reason: '窄窗口下分组内容仍应完整');
    expect(tester.takeException(), isNull, reason: '窄窗口不应溢出');

    await tester.binding.setSurfaceSize(null);
    tester.view.reset();
  });
}
