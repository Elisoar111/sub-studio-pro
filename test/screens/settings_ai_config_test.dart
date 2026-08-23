import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/settings_screen.dart';
import 'package:subtitle_studio_pro/services/ai/translation_service.dart';
import 'package:subtitle_studio_pro/services/ffmpeg/ffmpeg_service.dart';

/// v2.2 设置页 AI 配置（单测试体：SettingsProvider 单例避免串扰）：
/// - BaseURL + Key 填好后「获取模型」拉取列表，模型改为下拉选择（手填输入框删除）
/// - 「测试连接」按钮验证配置可用
void main() {
  setUpAll(() async {
    await FfmpegService.create();
    await SettingsProvider.instance.load();
  });

  tearDown(() {
    TranslationService.listModelsOverride = null;
    TranslationService.testConnectionOverride = null;
  });

  /// 出队所有 SnackBar：每轮 5s 让队头提示到期退场，最多清 3 条。
  Future<void> drainSnacks(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('AI 配置：获取模型 → 下拉选择 → 保存 → 测试连接成败提示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      tester.view.reset();
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // 锚点跳到 AI 分组
    await tester.tap(find.widgetWithText(ListTile, 'AI'));
    await tester.pumpAndSettle();
    expect(find.text('AI 字幕翻译'), findsOneWidget);

    // ── 阶段 1：获取模型 → 下拉选择（手填输入框已删除） ──
    TranslationService.listModelsOverride =
        (config) async => ['deepseek-chat', 'deepseek-reasoner'];
    await tester.enterText(
        find.widgetWithText(TextField, 'API BaseURL'), 'https://api.test');
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), 'sk-1');

    await tester.ensureVisible(find.text('获取模型'));
    await tester.tap(find.text('获取模型'));
    await tester.pumpAndSettle();
    expect(find.text('已获取 2 个模型'), findsOneWidget,
        reason: '拉取成功应提示数量');

    expect(find.widgetWithText(TextField, '模型'), findsNothing,
        reason: 'v2.2 删除手动输入模型名称');
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget,
        reason: '模型改为下拉选择');

    // 打开下拉并选择 deepseek-reasoner
    await tester.ensureVisible(find.byType(DropdownButtonFormField<String>));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('deepseek-reasoner').last);
    await tester.pumpAndSettle();

    // ── 阶段 2：保存配置 ──
    await tester.ensureVisible(find.text('保存配置'));
    await tester.tap(find.text('保存配置'));
    await tester.pumpAndSettle();
    expect(SettingsProvider.instance.aiModel, 'deepseek-reasoner',
        reason: '下拉选择的模型应保存到设置');
    expect(SettingsProvider.instance.aiBaseUrl, 'https://api.test');
    expect(SettingsProvider.instance.aiApiKey, 'sk-1');
    // 等提示 SnackBar 全部出队（阶段 1 + 阶段 2 各一条）
    await drainSnacks(tester);

    // ── 阶段 3：测试连接成功 ──
    TranslationService.testConnectionOverride = (config) async =>
        const TestConnectionResult(ok: true, latencyMs: 88, reply: 'pong');
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接成功'), findsOneWidget);
    expect(find.textContaining('88'), findsOneWidget,
        reason: '成功提示应包含延迟毫秒数');
    await drainSnacks(tester);

    // ── 阶段 4：Key 清空后测试连接失败（未发请求，走配置校验分支） ──
    TranslationService.testConnectionOverride = null;
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), '');
    await tester.ensureVisible(find.text('测试连接'));
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.textContaining('连接失败'), findsOneWidget);
  });
}
