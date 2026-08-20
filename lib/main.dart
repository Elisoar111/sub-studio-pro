import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'core/utils/logger.dart';
import 'core/utils/startup_args.dart';
import 'providers/app_providers.dart';
import 'services/ffmpeg/ffmpeg_service.dart';
import 'services/logging/crash_guard.dart';
import 'services/logging/log_file_store.dart';
import 'services/mkvtoolnix/mkvtoolnix_service.dart';
import 'services/notification_service.dart';
import 'services/queue_service.dart';
import 'services/storage_service.dart';
import 'services/tray_service.dart';
import 'services/update/update_service.dart';
import 'services/watch_folder_service.dart';
import 'services/whisper/whisper_service.dart';

/// 窗口关闭拦截（v2.0 托盘常驻）：
/// - 「最小化到托盘」开启（默认）：关闭按钮 → 隐藏窗口，任务后台继续；
/// - 关闭该设置：关闭按钮 → 真正退出。
class _WindowCloseHandler with WindowListener {
  @override
  void onWindowClose() async {
    if (SettingsProvider.instance.closeToTray) {
      await windowManager.hide();
      return;
    }
    await _exitApp();
  }
}

/// 退出应用：清理托盘图标后销毁窗口（setPreventClose 下 destroy 仍生效）。
Future<void> _exitApp() async {
  await TrayService.instance.shutdown();
  await windowManager.destroy();
}

/// 应用入口（仅 Windows 桌面）。
///
/// 初始化顺序：
/// 1. media_kit（libmpv）——播放器内核；
/// 2. window_manager —— 窗口标题 / 尺寸 / 最小尺寸 + 关闭拦截；
/// 3. Hive —— 历史 / 设置；
/// 4. FFmpeg —— 检测系统 FFmpeg（优先用户自定义路径，否则 PATH）；
/// 5. 状态（Riverpod providers）；
/// 6. 任务队列接入 FFmpeg 与历史记录；
/// 7. 系统托盘常驻（关闭最小化到托盘、任务后台继续）；
/// 8. 监视文件夹 —— 按设置恢复无人值守自动烧录流水线。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 0) 崩溃捕获（v1.5）：先挂异常钩子（此时仅内存缓冲，待日志目录确定后落盘）
  CrashGuard.install();

  // 0b) 文件关联（v1.5 安装包）：双击字幕文件启动时筛选出真实存在的
  //     字幕路径，经 provider 交给字幕库播种 + HomeShell 自动导航
  final startupSubtitles = subtitleFilesFromArgs(args);

  // 1) 媒体库初始化（libmpv）
  MediaKit.ensureInitialized();

  // 2) 窗口管理 + 关闭拦截（v2.0：关闭 = 最小化到托盘）
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1200, 800),
    minimumSize: Size(1000, 700),
    center: true,
    title: 'Subtitle Studio Pro',
    titleBarStyle: TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setPreventClose(true);
    await windowManager.show();
    await windowManager.focus();
  });
  windowManager.addListener(_WindowCloseHandler());

  // 3) 本地存储（Hive）
  await StorageService.instance.init();

  // 3b) 结构化日志落盘（v1.5）：文档目录 logs/，JSON Lines + 大小轮转
  //     （路径不可用时静默跳过，仅保留内存缓冲）
  try {
    final docs = await getApplicationDocumentsDirectory();
    Logger.instance.attachFileStore(LogFileStore(
        Directory('${docs.path}${Platform.pathSeparator}logs')));
  } catch (e) {
    Logger.instance.error('日志目录初始化失败，仅内存缓冲', e);
  }

  // 4) FFmpeg：优先使用用户在设置中指定的可执行文件路径，否则查找 PATH。
  //    未检测到时应用仍可启动，在设置页配置后重新检测。
  final ffmpegPath = StorageService.instance.getSetting(StorageService.kFfmpegPath);
  final ffprobePath = StorageService.instance.getSetting(StorageService.kFfprobePath);
  final ffmpeg = await FfmpegService.create(
    ffmpegPath: ffmpegPath.isEmpty ? null : ffmpegPath,
    ffprobePath: ffprobePath.isEmpty ? null : ffprobePath,
  );

  // 5) 状态初始化
  await SettingsProvider.instance.load();
  await HistoryProvider.instance.load();
  await SettingsProvider.instance.refreshFfmpegStatus();

  // 5b) MKVToolNix：轨道提取（mkvextract）与封装（mkvmerge）的唯一后端
  //     （不再使用 FFmpeg；未检测到时功能页会引导到设置页配置/导入）
  await MkvToolNixService.instance.init();

  // 5c) Whisper：Whisper 字幕（openai-whisper CLI 子进程）。
  //     检测要跑 `whisper --help`（torch 导入，可达数十秒），不能阻塞
  //     首帧——后台执行，检测完成后经 availability 通知界面刷新；
  //     否则窗口已显示但长时间空白
  unawaited(WhisperService.instance.init());

  // 6) 任务队列（任务结束自动写入历史）+ 系统通知
  await NotificationService.instance.init();
  QueueService.instance.init(
    ffmpeg: ffmpeg,
    onTaskFinished: (task) => HistoryProvider.instance.addFromTask(task),
  );

  // 7) 系统托盘（关闭最小化到托盘，任务后台继续；菜单退出走 _exitApp）
  await TrayService.instance.init(onExit: _exitApp);

  // 8) 监视文件夹（v2.0 无人值守流水线）：按已保存配置恢复监视
  //    （未启用 / 未配置目录时为幂等空操作）
  WatchFolderService.instance.syncFromSettings();

  // 9) 启动检查更新（v1.5-2）：后台静默查 GitHub Releases，发现新版本
  //    时首页横幅提示；无网络 / 失败静默忽略，不阻塞启动
  unawaited(checkForUpdatesSilently());

  runApp(ProviderScope(
    overrides: [
      startupSubtitleFilesProvider.overrideWith((ref) => startupSubtitles),
    ],
    child: const SubtitleStudioApp(),
  ));
}
