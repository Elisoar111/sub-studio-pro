import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/core/constants.dart';
import 'package:subtitle_studio_pro/screens/about_screen.dart';

/// 关于页（v2.1.0 更新）：检查更新入口已迁至设置页「维护」分组，
/// 关于页回归纯信息页——品牌横幅（应用名 / 版本徽章 / 定位语）、
/// 分区标题、能力速览、技术栈与格式支持。
void main() {
  Future<void> pumpAbout(
    WidgetTester tester,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: AboutScreen(),
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

  testWidgets('更新入口已迁移：不再出现检查更新面板', (tester) async {
    await pumpAbout(tester, const Size(1280, 800));

    expect(find.text('版本与更新'), findsNothing,
        reason: 'v2.1.0 起更新面板应移至设置页维护分组');
    expect(find.text('检查更新'), findsNothing);
    expect(find.text('立即升级'), findsNothing);
  });

  testWidgets('小窗口下整页无溢出', (tester) async {
    await pumpAbout(tester, const Size(720, 600));
    expect(tester.takeException(), isNull);
  });
}
