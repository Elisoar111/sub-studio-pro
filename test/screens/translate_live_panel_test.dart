import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/task_queue_screen.dart';
import 'package:subtitle_studio_pro/screens/translate_screen.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';
import 'package:subtitle_studio_pro/widgets/file_drop_zone.dart';

/// v2.2 翻译页直播面板：
/// - 队列中 running 的翻译任务，思考流 / 事件行在翻译页实时展示
/// - 开始翻译后不再自动跳转队列页，留在翻译页看直播
void main() {
  setUp(() {
    QueueService.instance.clearAll();
  });

  testWidgets('直播面板：running 任务展示思考流与事件行', (tester) async {
    final task = QueueService.instance.addTask(
      type: TaskType.subtitleTranslate,
      title: '翻译 demo.srt → 简体中文',
    );
    task.status = TaskStatus.running;
    task.liveThinking = '正在分析语境与术语一致性…';
    task.liveLines
      ..add('翻译批次 1/3：line 0')
      ..add('翻译批次 1/3 完成（line 0 → 译0）');

    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();

    // 面板位于长列表底部：先滚动到可见再断言
    await tester.scrollUntilVisible(
      find.text('翻译进度'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('翻译进度'), findsOneWidget, reason: '有进行中翻译任务时应出现直播面板');
    expect(find.textContaining('正在分析语境与术语一致性'), findsOneWidget,
        reason: '思考流应在面板中可见');
    expect(find.textContaining('翻译批次 1/3：line 0'), findsOneWidget,
        reason: '事件行应在面板中可见');
    expect(find.textContaining('翻译批次 1/3 完成'), findsOneWidget);
    expect(find.text('查看队列'), findsOneWidget, reason: '面板保留手动进队列的入口');
  });

  testWidgets('直播面板：队列无进行中翻译任务时不渲染', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();
    expect(find.text('翻译进度'), findsNothing);
  });

  testWidgets('开始翻译：留在翻译页不跳队列，任务入队并提示', (tester) async {
    await SettingsProvider.instance.setAiConfig(
      apiKey: 'k',
      baseUrl: 'https://api.test',
      model: 'm',
    );
    addTearDown(() => SettingsProvider.instance.setAiConfig(
          apiKey: '',
          baseUrl: '',
          model: '',
        ));

    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();

    // 模拟拖入字幕文件
    tester
        .widget<FileDropZone>(find.byType(FileDropZone))
        .onFilesDropped([r'C:\fake\demo.srt']);
    await tester.pump();

    // 滚到底部让开始按钮完整进入视口（scrollUntilVisible 后中心仍可能出界）
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -900));
    await tester.pump();
    await tester.tap(find.text('开始翻译（1 个文件）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(TaskQueueScreen), findsNothing,
        reason: 'v2.2 开始翻译后应留在翻译页，不再自动跳队列');
    expect(
      QueueService.instance.tasks
          .where((t) => t.type == TaskType.subtitleTranslate),
      isNotEmpty,
      reason: '任务应已入队',
    );
    expect(find.textContaining('已加入队列'), findsOneWidget);
  });
}
