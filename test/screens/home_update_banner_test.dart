import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/screens/home_screen.dart';
import 'package:subtitle_studio_pro/screens/about_screen.dart';
import 'package:subtitle_studio_pro/services/update/update_service.dart';

/// 首页更新横幅（v1.5-2 启动检查）：startupUpdate 非空时显示，
/// 可跳转关于页、可关闭（本次会话不再提示）。
///
/// 单测试体：SettingsProvider.instance 是共享单例，ProviderScope 销毁时
/// 会被 Riverpod 标记 disposed，多个 testWidgets 顺序使用会抛
/// "used after being disposed"（与 home_shell 系列测试同约定）。
void main() {
  testWidgets('无横幅 → 出现新版本横幅 → 查看进关于页 → 关闭后消失', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: HomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 初始无新版本：不显示横幅
    expect(find.textContaining('发现新版本'), findsNothing);

    // 启动检查写入新版本 → 横幅出现
    startupUpdate.value = const UpdateInfo(
      version: '9.9.9',
      releaseUrl: 'https://github.com/demo/app/releases/tag/v9.9.9',
      setupUrl: null,
      notes: '',
    );
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v9.9.9，点击查看更新内容'), findsOneWidget);

    // 「查看」→ 打开关于页（检查更新与一键升级入口）
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);

    // 返回首页，关闭横幅 → 本次会话不再显示
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('本次不再提示'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v9.9.9，点击查看更新内容'), findsNothing);
    expect(startupUpdate.value, isNull);
  });
}
