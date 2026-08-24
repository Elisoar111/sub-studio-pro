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

  testWidgets('直播面板（v2.2.1）：流式译文增量逐字上屏', (tester) async {
    final task = QueueService.instance.addTask(
      type: TaskType.subtitleTranslate,
      title: '翻译 demo.srt → 简体中文',
    );
    task.status = TaskStatus.running;
    task.liveThinking = '先分析语境';
    task.liveTranslating = '第一句译文正在逐字上';

    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('翻译进度'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('译文：'), findsOneWidget,
        reason: '流式译文行应有「译文：」前缀');
    expect(find.textContaining('第一句译文正在逐字上'), findsOneWidget,
        reason: '当前批次译文增量应在面板实时可见');
  });

  testWidgets('直播面板：队列无进行中翻译任务时不渲染', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();
    expect(find.text('翻译进度'), findsNothing);
  });

  testWidgets('直播面板：任务完成后保留展示 token 用量（不再计费）', (tester) async {
    final task = QueueService.instance.addTask(
      type: TaskType.subtitleTranslate,
      title: '翻译 demo.srt → 简体中文',
    );
    task.status = TaskStatus.completed;
    task.finishedAt = DateTime.now();
    task.usagePromptTokens = 1000;
    task.usageCompletionTokens = 500;
    task.usageTotalTokens = 1500;

    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('翻译进度'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('翻译进度'), findsOneWidget,
        reason: '刚完成的翻译任务应在面板保留展示');
    expect(
      find.textContaining('消耗：1,500 token（入 1,000 / 出 500）'),
      findsOneWidget,
      reason: '任务结束显示 token 消耗摘要',
    );
    expect(find.textContaining(r'$'), findsNothing,
        reason: 'v2.2.2 起移除 token 计费，不显示任何费用');
  });

  testWidgets('直播面板：完成已久的任务仍保留可回看（像 Whisper 一样）',
      (tester) async {
    final task = QueueService.instance.addTask(
      type: TaskType.subtitleTranslate,
      title: '翻译 demo.srt → 简体中文',
    );
    task.status = TaskStatus.completed;
    task.finishedAt = DateTime.now().subtract(const Duration(hours: 1));
    task.liveLines.add('翻译批次 1/3 完成（line 0 → 译0）');

    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('翻译进度'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('翻译进度'), findsOneWidget,
        reason: '已完成任务不设过期时间，随时回翻译页查看');
  });

  testWidgets('直播面板：详情按钮打开完整直播日志', (tester) async {
    final task = QueueService.instance.addTask(
      type: TaskType.subtitleTranslate,
      title: '翻译 demo.srt → 简体中文',
    );
    task.status = TaskStatus.completed;
    task.finishedAt = DateTime.now();
    task.liveThinking = '先分析语境';
    task.liveTranslating = '{"lines":["译0"]}';
    for (var i = 1; i <= 8; i++) {
      task.liveLines.add('批次事件 $i');
    }

    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('翻译进度'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // 面板摘要只显示尾部 6 条（事件 3–8），完整日志经「详情」查看
    expect(find.textContaining('批次事件 1'), findsNothing,
        reason: '面板摘要只显示尾部若干条');

    final detailBtn = find.byIcon(Icons.receipt_long_outlined).first;
    await tester.ensureVisible(detailBtn);
    await tester.pumpAndSettle();
    await tester.tap(detailBtn);
    await tester.pumpAndSettle();

    expect(find.text('直播详情'), findsOneWidget, reason: '详情对话框应打开');
    expect(find.textContaining('批次事件 1'), findsOneWidget,
        reason: '完整日志包含面板外的早期事件行');
    expect(find.textContaining('批次事件 8'), findsAtLeastNWidgets(1),
        reason: '对话框与面板摘要均含最新事件');
    expect(find.textContaining('先分析语境'), findsAtLeastNWidgets(1),
        reason: '详情包含思考流（面板摘要与对话框各一处）');
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
