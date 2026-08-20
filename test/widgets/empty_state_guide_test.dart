import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/widgets/common.dart';

/// 空状态「下一步」指引（v1.1 P2）：各功能页空列表时给出编号步骤，
/// 指向文件选择 / 设置，降低上手门槛。
void main() {
  testWidgets('EmptyState.steps 渲染编号步骤列表', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EmptyState(
          icon: Icons.inbox_outlined,
          message: '任务队列为空',
          steps: ['在功能页添加任务', '点击开始执行'],
        ),
      ),
    ));

    expect(find.text('下一步'), findsOneWidget, reason: '应有「下一步」标题');
    // 编号与文案分属两个 Text（编号高亮主色），分别断言
    expect(find.text('1  '), findsOneWidget);
    expect(find.text('在功能页添加任务'), findsOneWidget);
    expect(find.text('2  '), findsOneWidget);
    expect(find.text('点击开始执行'), findsOneWidget);
  });

  testWidgets('无 steps 时保持原样，不出现「下一步」', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EmptyState(icon: Icons.inbox_outlined, message: '暂无内容'),
      ),
    ));
    expect(find.text('暂无内容'), findsOneWidget);
    expect(find.text('下一步'), findsNothing);
  });

  testWidgets('StepGuide 可独立使用并渲染全部步骤', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: StepGuide(steps: ['第一步', '第二步', '第三步']),
      ),
    ));
    for (final s in const ['第一步', '第二步', '第三步']) {
      expect(find.text(s), findsOneWidget);
    }
    expect(find.text('3  '), findsOneWidget);
  });
}
