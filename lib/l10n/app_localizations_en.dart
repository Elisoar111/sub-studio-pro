// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appName => 'Subtitle Studio Pro';

  @override
  String get navHome => 'Home';

  @override
  String get navLibrary => 'Subtitles';

  @override
  String get navBurn => 'Burn Subtitles';

  @override
  String get navTracks => 'Track Tools';

  @override
  String get navTranscode => 'Transcode';

  @override
  String get navTranslate => 'AI Translate';

  @override
  String get navWhisper => 'Whisper Subtitles';

  @override
  String get navQueue => 'Task Queue';

  @override
  String get navHistory => 'History';

  @override
  String get tooltipSettings => 'Settings';

  @override
  String get tooltipAbout => 'About';

  @override
  String get trayShow => 'Show Main Window';

  @override
  String get trayPauseQueue => 'Pause Queue';

  @override
  String get trayResumeQueue => 'Resume Queue';

  @override
  String get trayExit => 'Exit';

  @override
  String get settingsLanguageTitle => 'Language';

  @override
  String get settingsLanguageLabel => 'Interface language';

  @override
  String get settingsLanguageSystem => 'Follow system';

  @override
  String get settingsLanguageZh => '中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsLanguageHint => 'Applies immediately, no restart needed.';
}
