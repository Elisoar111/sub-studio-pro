import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/core/constants.dart';
import 'package:subtitle_studio_pro/screens/about_screen.dart';

/// 关于页渲染回归：
/// - 品牌区（应用名 / 版本徽章）与各分区标题完整渲染
/// - 功能条目按三组（字幕工作流 / 视频处理 / 任务与记录）全部出现
/// - 常见窗口尺寸下无 RenderFlex 溢出
void main() {
  Future<void> pumpAbout(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: const AboutScreen(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('品牌区与分区标题完整渲染', (tester) async {
    await pumpAbout(tester, const Size(1280, 800));

    expect(find.text(AppConstants.appName), findsOneWidget);
    expect(find.text('v${AppConstants.appVersion}'), findsOneWidget);
    expect(find.text('字幕工作流一体化桌面工具'), findsOneWidget);

    expect(find.text('核心功能'), findsOneWidget);
    expect(find.text('技术栈'), findsOneWidget);
    expect(find.text('格式支持'), findsOneWidget);
  });

  testWidgets('九大功能条目按三组全部出现', (tester) async {
    await pumpAbout(tester, const Size(1280, 800));

    expect(find.text('字幕工作流'), findsOneWidget);
    expect(find.text('视频处理'), findsOneWidget);
    expect(find.text('任务与记录'), findsOneWidget);

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
      expect(find.text(name), findsOneWidget, reason: '缺少功能条目：$name');
    }
  });

  testWidgets('小窗口下整页无溢出', (tester) async {
    await pumpAbout(tester, const Size(720, 600));
    expect(tester.takeException(), isNull);
  });
}
