import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh')
  ];

  /// No description provided for @appName.
  ///
  /// In zh, this message translates to:
  /// **'Subtitle Studio Pro'**
  String get appName;

  /// No description provided for @navHome.
  ///
  /// In zh, this message translates to:
  /// **'首页'**
  String get navHome;

  /// No description provided for @navLibrary.
  ///
  /// In zh, this message translates to:
  /// **'字幕库'**
  String get navLibrary;

  /// No description provided for @navBurn.
  ///
  /// In zh, this message translates to:
  /// **'字幕烧录'**
  String get navBurn;

  /// No description provided for @navTracks.
  ///
  /// In zh, this message translates to:
  /// **'轨道处理'**
  String get navTracks;

  /// No description provided for @navTranscode.
  ///
  /// In zh, this message translates to:
  /// **'转码压缩'**
  String get navTranscode;

  /// No description provided for @navTranslate.
  ///
  /// In zh, this message translates to:
  /// **'AI 翻译'**
  String get navTranslate;

  /// No description provided for @navWhisper.
  ///
  /// In zh, this message translates to:
  /// **'Whisper字幕'**
  String get navWhisper;

  /// No description provided for @navQueue.
  ///
  /// In zh, this message translates to:
  /// **'任务队列'**
  String get navQueue;

  /// No description provided for @navHistory.
  ///
  /// In zh, this message translates to:
  /// **'历史记录'**
  String get navHistory;

  /// No description provided for @tooltipSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get tooltipSettings;

  /// No description provided for @tooltipAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get tooltipAbout;

  /// No description provided for @trayShow.
  ///
  /// In zh, this message translates to:
  /// **'显示主窗'**
  String get trayShow;

  /// No description provided for @trayPauseQueue.
  ///
  /// In zh, this message translates to:
  /// **'暂停队列'**
  String get trayPauseQueue;

  /// No description provided for @trayResumeQueue.
  ///
  /// In zh, this message translates to:
  /// **'恢复队列'**
  String get trayResumeQueue;

  /// No description provided for @trayExit.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get trayExit;

  /// No description provided for @settingsLanguageTitle.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguageTitle;

  /// No description provided for @settingsLanguageLabel.
  ///
  /// In zh, this message translates to:
  /// **'界面语言'**
  String get settingsLanguageLabel;

  /// No description provided for @settingsLanguageSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsLanguageSystem;

  /// No description provided for @settingsLanguageZh.
  ///
  /// In zh, this message translates to:
  /// **'中文'**
  String get settingsLanguageZh;

  /// No description provided for @settingsLanguageEn.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get settingsLanguageEn;

  /// No description provided for @settingsLanguageHint.
  ///
  /// In zh, this message translates to:
  /// **'切换后立即生效，无需重启。'**
  String get settingsLanguageHint;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
