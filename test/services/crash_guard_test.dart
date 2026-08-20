import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/core/utils/logger.dart';
import 'package:subtitle_studio_pro/services/logging/crash_guard.dart';
import 'package:subtitle_studio_pro/services/logging/log_file_store.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('crash_guard_test');
    Logger.instance.clear();
    Logger.instance.attachFileStore(LogFileStore(tmp));
  });

  tearDown(() {
    Logger.instance.attachFileStore(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, dynamic> lastRecord() {
    final lines =
        File('${tmp.path}${Platform.pathSeparator}app.log').readAsLinesSync();
    expect(lines, isNotEmpty);
    return jsonDecode(lines.last) as Map<String, dynamic>;
  }

  test('handleFlutterError：FlutterErrorDetails 落盘 level=error，含异常与堆栈', () {
    CrashGuard.handleFlutterError(FlutterErrorDetails(
      exception: StateError('widget boom'),
      library: 'widgets',
      stack: StackTrace.current,
    ));

    final rec = lastRecord();
    expect(rec['level'], 'error');
    expect(rec['message'], contains('widget boom'));
    expect(rec['message'], contains('\n'), reason: '应包含堆栈');
  });

  test('handleUncaughtError：返回 true 表示已消化，落盘 level=error', () {
    final handled = CrashGuard.handleUncaughtError(
        RangeError('index out of range'), StackTrace.current);

    expect(handled, isTrue, reason: '返回 true 阻止框架二次抛出');
    final rec = lastRecord();
    expect(rec['level'], 'error');
    expect(rec['message'], contains('index out of range'));
  });

  test('同一异常重复捕获各自独立成条（不合并、不丢栈）', () {
    for (var i = 0; i < 3; i++) {
      CrashGuard.handleUncaughtError(StateError('e$i'), StackTrace.current);
    }

    final lines =
        File('${tmp.path}${Platform.pathSeparator}app.log').readAsLinesSync();
    expect(lines, hasLength(3));
  });
}
