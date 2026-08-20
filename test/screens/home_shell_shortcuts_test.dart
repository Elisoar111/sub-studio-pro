import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/l10n/app_localizations.dart';
import 'package:subtitle_studio_pro/screens/burn_screen.dart';
import 'package:subtitle_studio_pro/screens/home_shell.dart';
import 'package:subtitle_studio_pro/screens/task_queue_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// 全局快捷键（ROADMAP v1.1 P1）：Ctrl+1..9 切换功能页、Ctrl+Q 打开
/// 任务队列。播放器空格播放/暂停已在 PlayerScreen 内实现，不在此覆盖。
///
/// 映射：Ctrl+N = 侧边栏第 N 页 —— Ctrl+1 首页 / Ctrl+2 字幕库 /
/// Ctrl+3 字幕烧录 / Ctrl+4 轨道处理 / Ctrl+5 转码压缩 / Ctrl+6 AI 翻译 /
/// Ctrl+7 Whisper字幕 / Ctrl+8 任务队列 / Ctrl+9 历史记录。
///
/// 单测试体：SettingsProvider.instance 是共享单例，ProviderScope 销毁
/// 时被 Riverpod dispose，多 testWidgets 会串扰。
void main() {
  // BurnScreen 的编码面板读取 FfmpegService.instance（探测编码器），
  // setUpAll 在真实异步环境执行，检测不到 ffmpeg 也不抛异常。
  // 编码器探测须在 setUpAll 预热缓存：testWidgets 的 FakeAsync 中
  // Process.run 会留下 pending timer 导致测试失败。
  setUpAll(() async {
    await FfmpegService.create();
    await FfmpegService.instance.availableEncoders();
  });

  Future<void> sendCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('Ctrl+1..9 切页、Ctrl+Q 开队列、裸数字不切页', (tester) async {
    // 1280×800：默认 800×600 测试面会触发 NavigationRail 尾部按钮列的
    // 既有溢出缺陷（与快捷键无关，单独跟踪），用门禁档位尺寸规避
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.reset();
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          // v2.0 起导航标签走 AppLocalizations，测试环境固定中文
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: HomeShell(),
        ),
      ),
    );
    await tester.pump();

    int stackIndex() =>
        tester.widget<IndexedStack>(find.byType(IndexedStack)).index ?? 0;

    expect(stackIndex(), 0, reason: '初始应在首页');

    // Ctrl+2 → 字幕库（第 2 页）
    await sendCtrl(tester, LogicalKeyboardKey.digit2);
    expect(stackIndex(), 1, reason: 'Ctrl+2 应切到字幕库');

    // Ctrl+3 → 字幕烧录（第 3 页）
    await sendCtrl(tester, LogicalKeyboardKey.digit3);
    expect(stackIndex(), 2, reason: 'Ctrl+3 应切到字幕烧录');
    expect(find.byType(BurnScreen), findsOneWidget);

    // Ctrl+8 → 任务队列
    await sendCtrl(tester, LogicalKeyboardKey.digit8);
    expect(stackIndex(), 7, reason: 'Ctrl+8 应切到任务队列');
    expect(find.byType(TaskQueueScreen), findsOneWidget);

    // Ctrl+1 → 返回首页
    await sendCtrl(tester, LogicalKeyboardKey.digit1);
    expect(stackIndex(), 0, reason: 'Ctrl+1 应返回首页');

    // Ctrl+Q → 直达任务队列
    await sendCtrl(tester, LogicalKeyboardKey.keyQ);
    expect(stackIndex(), 7, reason: 'Ctrl+Q 应直达任务队列');

    // 无修饰键的数字键不切页（当前在任务队列，应保持）
    await tester.sendKeyDownEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.digit4);
    await tester.pump();
    expect(stackIndex(), 7, reason: '裸数字键不应触发页面切换');
  });
}
