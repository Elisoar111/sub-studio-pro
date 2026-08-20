import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme.dart';
import 'l10n/app_localizations.dart';
import 'l10n/l10n.dart';
import 'providers/app_providers.dart';
import 'screens/home_shell.dart';
import 'services/tray_service.dart';

/// 应用根组件：Material 3 主题（亮 / 暗 / 跟随系统 × 自定义种子色）+
/// 多语言（v2.0：跟随系统 / 中文 / English，切换即时生效），
/// 设置变更经 Riverpod 通知后即时生效，无需重启。
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: settings.localeOverride,
      home: const _LocaleSync(child: HomeShell()),
    );
  }
}

/// locale 变化同步点：把当前语言的文案实例写入 [L10nHolder]（供托盘等
/// 无 BuildContext 的原生入口使用），并刷新托盘菜单文案。
class _LocaleSync extends StatefulWidget {
  final Widget child;

  const _LocaleSync({required this.child});

  @override
  State<_LocaleSync> createState() => _LocaleSyncState();
}

class _LocaleSyncState extends State<_LocaleSync> {
  AppLocalizations? _applied;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = AppLocalizations.of(context);
    if (!identical(l10n, _applied)) {
      _applied = l10n;
      L10nHolder.update(l10n);
      TrayService.instance.refreshMenu();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
