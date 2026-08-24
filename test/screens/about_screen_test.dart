import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/core/constants.dart';
import 'package:subtitle_studio_pro/screens/about_screen.dart';

/// 关于页（v2.2.1 更新）：纯信息页——品牌横幅、能力速览、技术栈、
/// 格式支持，以及各版本更新日志（最新在前）。
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
    // 更新日志首条徽章与当前版本同文本，横幅徽章只需存在
    expect(find.text('v${AppConstants.appVersion}'), findsWidgets,
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

  testWidgets('AI 翻译能力描述反映 v2.2.1 新能力', (tester) async {
    await pumpAbout(tester, const Size(1280, 800));

    expect(find.text('多配置档案一键切换，流式直播与用量统计'), findsOneWidget,
        reason: '能力速览应随版本演进更新文字');
  });

  testWidgets('更新日志：仅展示最新版本的更新内容', (tester) async {
    await pumpAbout(tester, const Size(1280, 800));

    // 日志区块位于格式支持之后，需滚动到可视区
    await tester.scrollUntilVisible(
      find.text('更新日志'),
      300,
      scrollable: find.byType(Scrollable).first,
    );

    // 当前版本要点
    expect(find.text('流式译文逐字上屏与 token 用量统计'), findsOneWidget);
    expect(find.text('多配置档案一键切换，主备自动降级'), findsOneWidget);
    expect(find.text('翻译内容缓存：相似台词零成本命中'), findsOneWidget);

    // 历史版本不再展示
    for (final v in ['v2.2.0', 'v2.1.1', 'v2.1.0', 'v2.0', 'v1.5', 'v1.3']) {
      expect(find.text(v), findsNothing,
          reason: '更新日志只保留最新版本内容，不应出现 $v');
    }
  });

  testWidgets('小窗口下整页无溢出', (tester) async {
    await pumpAbout(tester, const Size(720, 600));
    expect(tester.takeException(), isNull);
  });
}
