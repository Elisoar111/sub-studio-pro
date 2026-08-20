import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/screens/burn_screen.dart';
import 'package:subtitle_studio_pro/screens/transcode_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// 烧录 / 转码页布局回归测试（v1.1 P2 测试补齐）：
/// 空态（未选文件）在常见窗口尺寸下整页渲染不得出现 RenderFlex 溢出，
/// 且空状态「下一步」指引可见。推广自 mux_screen_layout_test 的质量门禁档位。
void main() {
  const sizes = [
    (Size(1280, 800), '标准桌面'),
    (Size(1024, 700), '小桌面'),
    (Size(800, 600), '最小门禁'),
  ];

  setUpAll(() async {
    // 编码面板 build 时异步探测编码器；预热缓存避免 pending timer
    await FfmpegService.create();
  });

  for (final (size, label) in sizes) {
    testWidgets('烧录页 $label ${size.width}x${size.height} 无溢出', (tester) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.reset();
      });

      await tester.pumpWidget(const MaterialApp(home: BurnScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull,
          reason: '$label 下烧录页出现布局异常');
      // 视频卡与字幕卡空态各有指引（内嵌模式除外），至少一个可见
      expect(find.text('下一步'), findsWidgets,
          reason: '空列表应显示「下一步」指引');
    });

    testWidgets('转码页 $label ${size.width}x${size.height} 无溢出', (tester) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.reset();
      });

      await tester.pumpWidget(const MaterialApp(home: TranscodeScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull,
          reason: '$label 下转码页出现布局异常');
      expect(find.text('下一步'), findsWidgets,
          reason: '空列表应显示「下一步」指引');
    });
  }
}
