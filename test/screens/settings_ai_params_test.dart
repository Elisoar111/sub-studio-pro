import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/settings_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// v2.2.1 设置页 AI 高级参数（单测试体：SettingsProvider 单例避免串扰）：
/// 超时 / 重试 / 并发 / 输入输出单价，保存后写入 SettingsProvider。
void main() {
  setUpAll(() async {
    await FfmpegService.create();
    await SettingsProvider.instance.load();
  });

  testWidgets('高级参数：修改并保存 → Provider 更新', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.reset();
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ListTile, 'AI'));
    await tester.pumpAndSettle();
    expect(find.text('AI 字幕翻译'), findsOneWidget);

    // 默认值回显
    expect(find.widgetWithText(TextField, '超时（秒）'), findsOneWidget);
    expect(find.widgetWithText(TextField, '重试次数'), findsOneWidget);
    expect(find.text('1（串行）'), findsOneWidget);
    // v2.2.2 移除 token 计费：单价输入框不再出现
    expect(find.textContaining('单价'), findsNothing);

    // 修改参数
    await tester.enterText(
        find.widgetWithText(TextField, '超时（秒）'), '90');
    await tester.enterText(find.widgetWithText(TextField, '重试次数'), '4');

    // 并发下拉选 2
    final concurrencyField = find.byWidgetPredicate(
        (w) => w is DropdownButtonFormField<int>);
    await tester.ensureVisible(concurrencyField);
    await tester.tap(concurrencyField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('2').last);
    await tester.pumpAndSettle();

    // 保存
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    final s = SettingsProvider.instance;
    expect(s.aiTimeoutSeconds, 90);
    expect(s.aiRetries, 4);
    expect(s.aiConcurrency, 2);
  });
}
