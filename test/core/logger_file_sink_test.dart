import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/core/utils/logger.dart';
import 'package:subtitle_studio_pro/services/logging/log_file_store.dart';

void main() {
  late Directory tmp;
  late LogFileStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('logger_sink_test');
    store = LogFileStore(tmp);
    Logger.instance.clear();
    Logger.instance.attachFileStore(store);
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

  test('log() 落盘为 level=info 的 JSON 记录，含 tag 与时间戳', () {
    Logger.instance.log('hello', tag: 'FFMPEG');

    final rec = lastRecord();
    expect(rec['level'], 'info');
    expect(rec['tag'], 'FFMPEG');
    expect(rec['message'], 'hello');
    expect(rec['ts'], isA<String>());
  });

  test('log() 无 tag 时记录 tag 为 APP', () {
    Logger.instance.log('plain');

    expect(lastRecord()['tag'], 'APP');
  });

  test('error() 落盘 level=error，message 含异常与堆栈', () {
    final err = StateError('boom');
    final stack = StackTrace.current;

    Logger.instance.error('任务失败', err, stack);

    final rec = lastRecord();
    expect(rec['level'], 'error');
    expect(rec['tag'], 'ERROR');
    expect(rec['message'], contains('boom'));
    expect(rec['message'], contains('任务失败'));
    expect(rec['message'], contains('\n'));
  });

  test('内存环形缓冲行为不受挂接影响', () {
    Logger.instance.log('buffered', tag: 'X');

    expect(Logger.instance.dump(), contains('buffered'));
    expect(Logger.instance.linesForTag('X'), hasLength(1));
  });
}
