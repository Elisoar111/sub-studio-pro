import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/l10n/app_localizations.dart';
import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/home_shell.dart';
import 'package:subtitle_studio_pro/screens/settings_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// 多语言界面（ROADMAP v2.0）：导航壳文案中/英切换 + 设置页语言分段
/// 控件写回 SettingsProvider（localeMode 持久化、localeOverride 驱动
/// MaterialApp 重建）。
///
/// 单测试体：SettingsProvider.instance 是共享单例，ProviderScope 销毁时
/// 被 Riverpod dispose，多 testWidgets 会串扰（同 home_shell_shortcuts_test）。
void main() {
  setUpAll(() async {
    // 与 home_shell_shortcuts_test 相同：预热编码器探测，避免 FakeAsync
    // pending timer
    await FfmpegService.create();
    await FfmpegService.instance.availableEncoders();
  });

  testWidgets('导航壳随 locale 切换中英文案；语言分段控件写回 provider',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.reset();
    });

    Future<void> pumpShell(Locale locale) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            home: const HomeShell(),
          ),
        ),
      );
      await tester.pump();
    }

    // ── 中文：导航选中项显示「首页」，工具提示为「设置」 ──
    await pumpShell(const Locale('zh'));
    expect(find.text('首页'), findsOneWidget);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.text('Home'), findsNothing);

    // ── 英文：导航与工具提示切换为英文 ──
    await pumpShell(const Locale('en'));
    expect(find.text('Home'), findsOneWidget);
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.text('首页'), findsNothing);

    // ── 设置页语言分段控件：点击 English → localeMode=en ──
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('语言'), findsOneWidget, reason: '语言卡片应存在');
    await tester.tap(find.text('English'));
    await tester.pump();
    expect(SettingsProvider.instance.localeMode, 'en');
    expect(SettingsProvider.instance.localeOverride, const Locale('en'));

    // 切回中文 → localeMode=zh
    await tester.tap(find.text('中文'));
    await tester.pump();
    expect(SettingsProvider.instance.localeMode, 'zh');
    expect(SettingsProvider.instance.localeOverride, const Locale('zh'));
  });
}
