import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/screens/translate_screen.dart';

/// v1.3 术语表旁车 UI：对话框提供「导入旁车 / 导出旁车」入口。
void main() {
  testWidgets('术语表对话框含导入/导出旁车按钮', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TranslateScreen()));
    await tester.pump();

    // ListView 懒构建：先滚动到术语表按钮
    await tester.scrollUntilVisible(
      find.textContaining('术语表 / 人名表'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // 直接定位含目标文本的按钮（避免 textContaining 命中多个元素）
    final btn = find.ancestor(
      of: find.textContaining('术语表 / 人名表'),
      matching: find.byType(OutlinedButton),
    );
    expect(btn, findsOneWidget);
    await tester.ensureVisible(btn);
    await tester.pump();
    await tester.tap(btn);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('保存'), findsOneWidget, reason: '对话框应已打开');
    expect(find.text('导入旁车'), findsOneWidget);
    expect(find.text('导出旁车'), findsOneWidget);
    expect(find.textContaining('仅保存在应用设置'), findsNothing,
        reason: 'v1.3 起词库可通过旁车文件跨任务共享，说明文案应更新');
  });
}
