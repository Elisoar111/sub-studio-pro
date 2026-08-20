import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/settings_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// v1.5 崩溃与日志：维护分组提供「导出调试包」入口。
/// 单测试体（共享单例 SettingsProvider，避免串扰，同 settings_screen_structure_test）。
void main() {
  setUpAll(() async {
    await FfmpegService.create();
    await SettingsProvider.instance.load();
  });

  testWidgets('维护分组渲染「导出调试包」按钮', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final btn = find.widgetWithText(
        OutlinedButton, '导出调试包（日志 + 脱敏设置）');
    expect(btn, findsOneWidget, reason: '维护分组缺少导出调试包入口');

    // 确保按钮可见（长列表需要滚动进视口才能被用户操作）
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
  });
}
