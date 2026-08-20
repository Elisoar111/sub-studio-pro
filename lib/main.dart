import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'providers/app_providers.dart';
import 'services/ffmpeg/ffmpeg_service.dart';
import 'services/mkvtoolnix/mkvtoolnix_service.dart';
import 'services/notification_service.dart';
import 'services/queue_service.dart';
import 'services/storage_service.dart';
import 'services/whisper/whisper_service.dart';

/// 应用入口（仅 Windows 桌面）。
///
/// 初始化顺序：
/// 1. media_kit（libmpv）——播放器内核；
/// 2. window_manager —— 窗口标题 / 尺寸 / 最小尺寸；
/// 3. Hive —— 历史 / 设置；
/// 4. FFmpeg —— 检测系统 FFmpeg（优先用户自定义路径，否则 PATH）；
/// 5. 状态（Riverpod providers）；
/// 6. 任务队列接入 FFmpeg 与历史记录。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) 媒体库初始化（libmpv）
  MediaKit.ensureInitialized();

  // 2) 窗口管理
  await windowManager.ensureInitialized();
  const windowOptions = WindowOptions(
    size: Size(1200, 800),
    minimumSize: Size(1000, 700),
    center: true,
    title: 'Subtitle Studio Pro',
    titleBarStyle: TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // 3) 本地存储（Hive）
  await StorageService.instance.init();

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

  runApp(const ProviderScope(child: SubtitleStudioApp()));
}
