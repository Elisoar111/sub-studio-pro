import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/main.dart';

/// 应用退出序列（v2.0.2 修复）：
/// 托盘清理抛异常不得阻断窗口销毁——否则托盘 destroy 失败时
/// 应用将完全无法退出（只能任务管理器杀进程）。
void main() {
  test('托盘清理抛异常时窗口销毁仍执行', () async {
    var destroyed = false;
    final errors = <String>[];

    await safeExitSequence(
      cleanup: () async => throw StateError('tray destroy failed'),
      destroy: () async => destroyed = true,
      onError: (step, e) => errors.add('$step: $e'),
    );

    expect(destroyed, isTrue, reason: '托盘清理失败不得阻断窗口销毁');
    expect(errors, hasLength(1));
    expect(errors.single, contains('cleanup'));
  });

  test('窗口销毁抛异常时不外抛（退出流程不中断崩溃）', () async {
    final errors = <String>[];

    await safeExitSequence(
      cleanup: () async {},
      destroy: () async => throw StateError('destroy failed'),
      onError: (step, e) => errors.add('$step: $e'),
    );

    expect(errors.single, contains('destroy'));
  });

  test('正常路径：两步按序执行且无错误回调', () async {
    final steps = <String>[];

    await safeExitSequence(
      cleanup: () async => steps.add('cleanup'),
      destroy: () async => steps.add('destroy'),
    );

    expect(steps, ['cleanup', 'destroy']);
  });
}
