import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/screens/translate_screen.dart';
import 'package:subtitle_studio_pro/screens/whisper_screen.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// 翻译页 / Whisper 页布局回归测试（v1.2 质量门禁）：
/// 空态在常见窗口尺寸下整页渲染不得出现 RenderFlex 溢出，
/// 且 v1.2 新增控件（润色开关 / VAD 开关）可见。
void main() {
  const sizes = [
    (Size(1280, 800), '标准桌面'),
    (Size(1024, 700), '小桌面'),
    (Size(800, 600), '最小门禁'),
  ];

  setUpAll(() {
    // GPU 探测注入：避免 widget 测试拉起真实 nvidia-smi 子进程
    WhisperService.gpuDetectOverride = () async => false;
  });

  tearDownAll(() {
    WhisperService.gpuDetectOverride = null;
  });

  for (final (size, label) in sizes) {
    testWidgets('翻译页 $label ${size.width}x${size.height} 无溢出',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.reset();
      });

      await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull,
          reason: '$label 下翻译页出现布局异常');
      // ListView 懒构建：滚动到设置卡再断言 v1.2 新开关已渲染
      await tester.scrollUntilVisible(
        find.text('译文润色模式'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('译文润色模式'), findsOneWidget,
          reason: 'v1.2 润色开关应可见');
      expect(find.text('同时输出双语合并字幕（_mixed）'), findsOneWidget);
    });

    testWidgets('Whisper 页 $label ${size.width}x${size.height} 无溢出',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() async {
        await tester.binding.setSurfaceSize(null);
        tester.view.reset();
      });

      await tester.pumpWidget(const MaterialApp(home: WhisperScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull,
          reason: '$label 下 Whisper 页出现布局异常');
      expect(find.text('VAD 静音过滤'), findsOneWidget,
          reason: 'v1.2 VAD 开关应可见（后端未检测时为禁用态）');
      expect(find.text('使用 GPU（CUDA）'), findsOneWidget);
    });
  }
}
