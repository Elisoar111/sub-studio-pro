import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/home_shell.dart';

/// 启动自动导航（v1.5 文件关联）：带字幕文件启动时 HomeShell 应自动
/// 切到字幕库（IndexedStack 第 2 页），播种的文件直接可见；正常启动
/// 停留首页。
///
/// 单测试体：SettingsProvider.instance 是共享单例，ProviderScope 销毁
/// 时被 Riverpod dispose，多 testWidgets 会串扰（同 settings 结构测试）。
void main() {
  testWidgets('带字幕文件启动 → 自动切到字幕库并显示文件', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.reset();
    });

    final tmp = Directory.systemTemp.createTempSync('startup_nav_test');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final srt =
        File('${tmp.path}${Platform.pathSeparator}opened.srt')
          ..writeAsStringSync('1\n00:00:00,000 --> 00:00:02,000\nhi\n');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          startupSubtitleFilesProvider.overrideWith((ref) => [srt.path]),
        ],
        child: const MaterialApp(
          home: HomeShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 自动导航后字幕库已构建：播种文件可见，AppBar 标题为「字幕库」
    expect(find.text('opened.srt'), findsOneWidget,
        reason: '字幕库未构建或未播种启动文件');
    expect(find.widgetWithText(AppBar, '字幕库'), findsOneWidget);
  });
}
