import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/subtitle_list_screen.dart';

/// 字幕库启动播种（v1.5 文件关联）：安装包注册 .srt/.ass/.ssa/.vtt/.sub
/// 关联后，双击字幕文件启动应用 → 字幕库列表直接出现该文件。
///
/// 字幕库不依赖 SettingsProvider，多 testWidgets 无单例串扰。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('subtitle_startup_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Widget host(List<String> files) {
    return ProviderScope(
      overrides: [
        startupSubtitleFilesProvider.overrideWith((ref) => files),
      ],
      child: const MaterialApp(home: SubtitleListScreen()),
    );
  }

  testWidgets('启动参数中的字幕文件出现在字幕库列表', (tester) async {
    final srt =
        File('${tmp.path}${Platform.pathSeparator}demo.srt')
          ..writeAsStringSync('1\n00:00:00,000 --> 00:00:02,000\nhi\n');
    final ass =
        File('${tmp.path}${Platform.pathSeparator}oppo.ass')
          ..writeAsStringSync('[Script Info]');

    await tester.pumpWidget(host([srt.path, ass.path]));

    expect(find.text('demo.srt'), findsOneWidget);
    expect(find.text('oppo.ass'), findsOneWidget);
    expect(find.textContaining('导入字幕'), findsWidgets,
        reason: '非空列表不应再显示空态引导');
  });

  testWidgets('无启动文件时保持空态（不播种）', (tester) async {
    await tester.pumpWidget(host(const []));

    expect(find.text('还没有字幕文件\n点击右下角导入 SRT / ASS / SSA / VTT / SUB'),
        findsOneWidget);
  });
}
