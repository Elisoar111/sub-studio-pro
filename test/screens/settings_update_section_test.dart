import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/core/constants.dart';
import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/settings_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/update/update_service.dart';

/// 设置页「维护」分组的更新区块（v2.1.0：检查更新从关于页迁移至此）：
/// - 手动「检查更新」状态流转（最新 / 发现新版本 / 失败）
/// - 「自动检查更新」开关（默认开启，每 6 小时静默检查）
///
/// 单测试体：SettingsProvider.instance 是共享单例，ProviderScope 销毁时
/// 被 Riverpod dispose，多 testWidgets 会串扰（同 settings_screen_structure_test）。
class _FakeUpdateService extends UpdateService {
  UpdateInfo? info;
  Object? error;

  @override
  Future<UpdateInfo?> checkLatest({required String currentVersion}) async {
    if (error != null) throw error!;
    return info;
  }
}

const _newVersion = UpdateInfo(
  version: '9.9.9',
  releaseUrl: 'https://github.com/demo/app/releases/tag/v9.9.9',
  setupUrl: 'https://github.com/demo/app/releases/download/v9.9.9/setup.exe',
  notes: '修复若干问题',
);

void main() {
  setUpAll(() async {
    await FfmpegService.create();
    await SettingsProvider.instance.load();
  });

  tearDownAll(() {
    stopPeriodicUpdateCheck();
  });

  testWidgets('维护分组更新区块：手动检查流转 + 自动检查开关', (tester) async {
    final svc = _FakeUpdateService();
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<void> pumpSettings() async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData.light(useMaterial3: true),
            home: SettingsScreen(updateService: svc),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // 维护分组在长页面底部，tap 前先滚入视口
    Future<void> scrollToAndTap(String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
    }

    // ── 区块完整渲染 ──
    await pumpSettings();
    expect(find.text('版本与更新'), findsOneWidget,
        reason: '更新区块应位于设置页维护分组');
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('自动检查更新'), findsOneWidget);
    expect(find.textContaining('每 6 小时'), findsOneWidget,
        reason: '开关副标题应说明检查间隔');

    // ── 手动检查：无新版本 ──
    svc.info = null;
    await scrollToAndTap('检查更新');
    expect(find.text('已是最新版本（v${AppConstants.appVersion}）'),
        findsOneWidget);

    // ── 手动检查：发现新版本 ──
    svc.info = _newVersion;
    await scrollToAndTap('检查更新');
    expect(find.text('发现新版本 v9.9.9'), findsOneWidget);
    expect(find.text('修复若干问题'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '立即升级'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '查看发布页'), findsOneWidget);

    // ── 手动检查：失败 → 错误提示且按钮可重试 ──
    svc.info = null;
    svc.error = const SocketException('offline');
    await scrollToAndTap('检查更新');
    expect(find.textContaining('检查更新失败'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '检查更新'), findsOneWidget);
    svc.error = null;

    // ── 自动检查开关：默认开启，关闭同步 provider ──
    expect(SettingsProvider.instance.autoUpdateCheck, isTrue,
        reason: '自动检查更新默认开启');
    await scrollToAndTap('自动检查更新');
    expect(SettingsProvider.instance.autoUpdateCheck, isFalse,
        reason: '关闭开关应同步到 provider');

    // 恢复默认，避免影响其他测试；随即停掉真实定时器，
    // 否则 testWidgets 结束时 6 小时周期定时器仍挂起（!timersPending）。
    await SettingsProvider.instance.setAutoUpdateCheck(true);
    stopPeriodicUpdateCheck();
  });
}
