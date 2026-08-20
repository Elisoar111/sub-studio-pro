import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/screens/convert_screen.dart';
import 'package:subtitle_studio_pro/screens/history_screen.dart';
import 'package:subtitle_studio_pro/screens/player_screen.dart';
import 'package:subtitle_studio_pro/screens/subtitle_list_screen.dart';
import 'package:subtitle_studio_pro/screens/track_screen.dart';

/// v1.2.x 布局门禁补齐：convert / track / history / player / subtitle_list
/// 空态在常见窗口尺寸下整页渲染不得出现 RenderFlex 溢出
/// （对齐 burn / transcode / translate / whisper / mux 已有档位）。
void main() {
  const sizes = [
    (Size(1280, 800), '标准桌面'),
    (Size(1024, 700), '小桌面'),
    (Size(800, 600), '最小门禁'),
  ];

  Widget wrap(Widget child) => ProviderScope(
        child: MaterialApp(home: child),
      );

  for (final (size, label) in sizes) {
    Future<void> pumpPage(WidgetTester tester, Widget page) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.reset();
      });
      await tester.pumpWidget(wrap(page));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('字幕转换页 $label ${size.width}x${size.height} 无溢出',
        (tester) async {
      await pumpPage(tester, const ConvertScreen(files: []));
      expect(tester.takeException(), isNull, reason: '$label 下转换页布局异常');
    });

    testWidgets('轨道处理页 $label ${size.width}x${size.height} 无溢出',
        (tester) async {
      await pumpPage(tester, const TrackScreen());
      expect(tester.takeException(), isNull, reason: '$label 下轨道处理页布局异常');
      // 双页签（提取 / 封装）都过一遍
      final tab = find.text('封装');
      if (tab.evaluate().isNotEmpty) {
        await tester.tap(tab);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull,
            reason: '$label 下封装页签布局异常');
      }
    });

    testWidgets('播放器页 $label ${size.width}x${size.height} 无溢出（空态）',
        (tester) async {
      await pumpPage(tester, const PlayerScreen());
      expect(tester.takeException(), isNull, reason: '$label 下播放器空态布局异常');
    });

    testWidgets('字幕列表页 $label ${size.width}x${size.height} 无溢出',
        (tester) async {
      await pumpPage(tester, const SubtitleListScreen());
      expect(tester.takeException(), isNull, reason: '$label 下字幕列表页布局异常');
    });
  }

  // HistoryProvider 为单例 ChangeNotifierProvider：多 testWidgets 各自的
  // ProviderScope teardown 会 dispose 单例并串扰后续测试（同
  // settings_screen_structure_test 已知问题）。因此历史页在单个
  // testWidgets 内复用一个 scope，连续切换三档窗口尺寸断言。
  testWidgets('历史记录页 三档窗口连续缩放无溢出', (tester) async {
    await tester.pumpWidget(wrap(const HistoryScreen()));
    for (final (size, label) in sizes) {
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '$label 下历史页布局异常');
      expect(find.text('历史记录'), findsOneWidget);
    }
    await tester.binding.setSurfaceSize(null);
    tester.view.reset();
  });
}
