import 'package:flutter/widgets.dart';

import 'app_localizations.dart';
import 'app_localizations_zh.dart';

/// BuildContext 内取文案（MaterialApp 已挂 delegates 时可用）。
AppLocalizations l10nOf(BuildContext context) => AppLocalizations.of(context);

/// 无 BuildContext 场景（系统托盘菜单等原生入口）的文案访问：
/// app.dart 在 locale 解析后调用 [update] 写入当前语言实例，
/// 未写入前（如测试）回退中文模板。
class L10nHolder {
  L10nHolder._();

  static AppLocalizations _current = AppLocalizationsZh();

  static AppLocalizations get current => _current;

  static void update(AppLocalizations l10n) => _current = l10n;
}
