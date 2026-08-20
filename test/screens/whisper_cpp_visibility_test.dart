import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/settings_screen.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_models.dart';
import 'package:subtitle_studio_pro/services/whisper/whisper_service.dart';

/// v1.3 whisper.cpp 实验性后端 UI 门禁：设置页「转写后端」下拉默认
/// 不含实验项，检测到可执行文件（cppAvailable）后才出现。
///
/// 单测试体：SettingsProvider.instance 是共享单例，ProviderScope 销毁时
/// 被 Riverpod dispose，多 testWidgets 会串扰（同 settings_screen_structure_test）。
void main() {
  setUpAll(() async {
    await FfmpegService.create();
    await SettingsProvider.instance.load();
  });

  testWidgets('后端下拉：实验项默认隐藏，检测到可执行后出现', (tester) async {
    WhisperService.instance.resetForTesting();

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 滚到 Whisper 区并展开后端下拉
    await tester.ensureVisible(find.text('转写后端'));
    await tester.tap(find.text('转写后端'));
    await tester.pumpAndSettle();

    // 菜单已打开：常规后端可见，实验项不出现
    expect(find.text(WhisperBackend.openai.label), findsWidgets);
    expect(find.text(WhisperBackend.whisperCpp.label), findsNothing,
        reason: '未检测到 whisper.cpp 可执行时实验项应隐藏');

    // 关闭菜单，模拟检测到可执行文件
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    WhisperService.instance.cppAvailable.value = true;
    await tester.pump();

    await tester.tap(find.text('转写后端'));
    await tester.pumpAndSettle();
    expect(find.text(WhisperBackend.whisperCpp.label), findsOneWidget,
        reason: '检测到 whisper.cpp 可执行后实验项应出现');

    WhisperService.instance.resetForTesting();
  });
}
