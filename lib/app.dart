import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'providers/app_providers.dart';
import 'screens/home_shell.dart';

/// 应用根组件：Material 3 主题（亮 / 暗 / 跟随系统 × 自定义种子色）。
/// 设置变更经 Riverpod 通知后即时生效，无需重启。界面文案固定中文。
class SubtitleStudioApp extends ConsumerWidget {
  const SubtitleStudioApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    return MaterialApp(
      title: 'Subtitle Studio Pro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(settings.seedColor),
      darkTheme: AppTheme.dark(settings.seedColor),
      themeMode: settings.themeMode,
      home: const HomeShell(),
    );
  }
}
