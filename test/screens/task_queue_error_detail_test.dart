import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/core/utils/logger.dart';
import 'package:subtitle_studio_pro/models/queue_task.dart';
import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/screens/task_queue_screen.dart';
import 'package:subtitle_studio_pro/services/queue_service.dart';

/// 错误详情可复制（v1.1 P2）：任务失败信息支持展开完整日志并一键复制，
/// 工单排障刚需。
///
/// 注意：queueProvider 默认暴露 QueueService.instance 单例，而
/// ProviderScope 卸载时 ChangeNotifierProvider 会 dispose 掉它，
/// 污染后续测试。因此这里用独立实例 override（forTesting 构造）。
void main() {
  // flutter_test 未注册 clipboard mock 时，Clipboard.setData/getData 的
  // platform 消息永不返回，测试会挂到 10 分钟超时。注册内存 mock 代替。
  String? copied;
  setUpAll(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          copied = (call.arguments as Map?)?['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return copied == null ? null : {'text': copied};
        default:
          return null;
      }
    });
  });

  testWidgets('失败任务可展开完整错误 + 会话日志，并一键复制', (tester) async {
    final q = QueueService.forTesting();
    final task = q.addTask(type: TaskType.burn, title: '失败的任务.mp4');
    task.status = TaskStatus.failed;
    task.error = 'FFmpeg 退出码 1\n流映射失败\nOutput file #0 does not contain any stream';
    Logger.instance.clear();
    Logger.instance.ffmpeg(task.id.substring(0, 6), 'frame= 100 fps=30 q=23.0');

    await tester.pumpWidget(ProviderScope(
      overrides: [queueProvider.overrideWith((ref) => q)],
      child: const MaterialApp(home: TaskQueueScreen()),
    ));
    await tester.pump();

    // 折叠态：错误最多 3 行 + 不显示日志区
    expect(find.text('详情'), findsOneWidget);
    expect(find.text('执行日志'), findsNothing, reason: '折叠时不显示日志区');

    // 展开：完整错误 + 会话日志可见
    // （ProgressPanel 有 indeterminate 进度条动画，pumpAndSettle 永不 settle，
    //  用固定时长 pump 推进 ripple 与 rebuild）
    await tester.tap(find.text('详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('执行日志'), findsOneWidget);
    expect(find.textContaining('frame= 100 fps=30'), findsOneWidget);

    // 复制：剪贴板包含任务信息 + 完整错误 + 会话日志
    await tester.tap(find.text('复制'));
    await tester.pump();
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, isNotNull);
    final text = clip!.text!;
    expect(text, contains('失败的任务.mp4'));
    expect(text, contains('Output file #0 does not contain any stream'));
    expect(text, contains('frame= 100 fps=30'));

    // 收起恢复折叠态
    await tester.tap(find.text('收起'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('执行日志'), findsNothing);
  });

  testWidgets('非失败任务不显示详情/复制按钮', (tester) async {
    final q = QueueService.forTesting();
    final task = q.addTask(type: TaskType.burn, title: '成功任务.mp4');
    task.status = TaskStatus.completed;

    await tester.pumpWidget(ProviderScope(
      overrides: [queueProvider.overrideWith((ref) => q)],
      child: const MaterialApp(home: TaskQueueScreen()),
    ));
    await tester.pump();

    expect(find.text('详情'), findsNothing);
    expect(find.text('复制'), findsNothing);
  });
}
