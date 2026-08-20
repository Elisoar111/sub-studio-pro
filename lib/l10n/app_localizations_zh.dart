// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => 'Subtitle Studio Pro';

  @override
  String get navHome => '首页';

  @override
  String get navLibrary => '字幕库';

  @override
  String get navBurn => '字幕烧录';

  @override
  String get navTracks => '轨道处理';

  @override
  String get navTranscode => '转码压缩';

  @override
  String get navTranslate => 'AI 翻译';

  @override
  String get navWhisper => 'Whisper字幕';

  @override
  String get navQueue => '任务队列';

  @override
  String get navHistory => '历史记录';

  @override
  String get tooltipSettings => '设置';

  @override
  String get tooltipAbout => '关于';

  @override
  String get trayShow => '显示主窗';

  @override
  String get trayPauseQueue => '暂停队列';

  @override
  String get trayResumeQueue => '恢复队列';

  @override
  String get trayExit => '退出';

  @override
  String get settingsLanguageTitle => '语言';

  @override
  String get settingsLanguageLabel => '界面语言';

  @override
  String get settingsLanguageSystem => '跟随系统';

  @override
  String get settingsLanguageZh => '中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsLanguageHint => '切换后立即生效，无需重启。';
}
