import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/core/constants.dart';
import 'package:subtitle_studio_pro/screens/about_screen.dart';
import 'package:subtitle_studio_pro/services/update/update_service.dart';

/// 关于页（v1.5 重设计）回归：
/// - 品牌横幅（应用名 / 版本徽章 / 定位语）与分区标题完整渲染
/// - 版本与更新面板的状态流转（检查 → 最新 / 发现新版本 / 失败）
/// - 常见窗口尺寸下无 RenderFlex 溢出
class _FakeUpdateService extends UpdateService {
  _FakeUpdateService({this.info, this.error});

  final UpdateInfo? info;
  final Object? error;

  @override
  Future<UpdateInfo?> checkLatest({required String currentVersion}) async {
    if (error != null) throw error!;
    return info;
  }
}

void main() {
  Future<void> pumpAbout(
    WidgetTester tester,
    Size size, {
    UpdateService? service,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: AboutScreen(updateService: service),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('品牌横幅与分区标题完整渲染', (tester) async {
    await pumpAbout(tester, const Size(1280, 800));

    expect(find.text(AppConstants.appName), findsOneWidget);
    expect(find.text('v${AppConstants.appVersion}'), findsOneWidget,
        reason: '品牌横幅缺少版本徽章');
    expect(find.text('字幕工作流一体化桌面工具'), findsOneWidget);

    expect(find.text('版本与更新'), findsOneWidget);
    expect(find.text('核心能力'), findsOneWidget);
    expect(find.text('技术栈'), findsOneWidget);
    expect(find.text('格式支持'), findsOneWidget);
  });

  testWidgets('九大能力条目全部出现', (tester) async {
    await pumpAbout(tester, const Size(1280, 800));

    for (final name in [
      '字幕库',
      '字幕烧录',
      'AI 翻译',
      'Whisper 字幕',
      '轨道处理',
      '转码压缩',
      '视频预览',
      '任务队列',
      '历史记录',
    ]) {
      expect(find.text(name), findsOneWidget, reason: '缺少能力条目：$name');
    }
  });

  testWidgets('检查更新：远端无新版本 → 已是最新版本', (tester) async {
    await pumpAbout(
      tester,
      const Size(1280, 800),
      service: _FakeUpdateService(info: null),
    );

    expect(find.text('检查更新'), findsOneWidget);
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('已是最新版本（v${AppConstants.appVersion}）'),
        findsOneWidget);
  });

  testWidgets('检查更新：发现新版本 → 展示版本 / 说明 / 立即升级入口',
      (tester) async {
    await pumpAbout(
      tester,
      const Size(1280, 800),
      service: _FakeUpdateService(
        info: const UpdateInfo(
          version: '9.9.9',
          releaseUrl: 'https://github.com/demo/app/releases/tag/v9.9.9',
          setupUrl:
              'https://github.com/demo/app/releases/download/v9.9.9/setup.exe',
          notes: '修复若干问题',
        ),
      ),
    );

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v9.9.9'), findsOneWidget);
    expect(find.text('修复若干问题'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '立即升级'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '查看发布页'), findsOneWidget);
  });

  testWidgets('检查更新：网络失败 → 显示错误提示', (tester) async {
    await pumpAbout(
      tester,
      const Size(1280, 800),
      service: _FakeUpdateService(error: const SocketException('offline')),
    );

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.textContaining('检查更新失败'), findsOneWidget);
    // 失败后按钮恢复可用（可重试）
    expect(find.widgetWithText(OutlinedButton, '检查更新'), findsOneWidget);
  });

  testWidgets('小窗口下整页无溢出', (tester) async {
    await pumpAbout(tester, const Size(720, 600));
    expect(tester.takeException(), isNull);
  });
}
