import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/logging/log_file_store.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('log_store_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File log(Directory dir, [String name = 'app.log']) =>
      File('${dir.path}${Platform.pathSeparator}$name');

  test('单条记录追加为合法 JSON 行，字段齐全', () {
    final store = LogFileStore(tmp);
    store.write({
      'ts': '2026-08-20T12:00:00.000',
      'level': 'info',
      'tag': 'APP',
      'message': 'hello',
    });

    final lines = log(tmp).readAsLinesSync();
    expect(lines, hasLength(1));
    final decoded = jsonDecode(lines.single) as Map<String, dynamic>;
    expect(decoded['level'], 'info');
    expect(decoded['tag'], 'APP');
    expect(decoded['message'], 'hello');
    expect(decoded['ts'], '2026-08-20T12:00:00.000');
  });

  test('多条记录逐行追加，顺序保持', () {
    final store = LogFileStore(tmp);
    for (var i = 0; i < 3; i++) {
      store.write({'ts': 't$i', 'level': 'info', 'message': 'line-$i'});
    }

    final lines = log(tmp).readAsLinesSync();
    expect(lines, hasLength(3));
    for (var i = 0; i < 3; i++) {
      final decoded = jsonDecode(lines[i]) as Map<String, dynamic>;
      expect(decoded['message'], 'line-$i');
    }
  });

  test('超过单文件大小阈值时轮转：旧内容移入 app.1.log，新记录写新 app.log', () {
    final store = LogFileStore(tmp, maxBytesPerFile: 120);
    final long = 'x' * 60;
    for (var i = 0; i < 8; i++) {
      store.write({'ts': 't$i', 'level': 'info', 'message': long});
    }

    expect(log(tmp, 'app.1.log').existsSync(), isTrue,
        reason: '超阈值后应产生轮转文件');
    final rotated =
        jsonDecode(log(tmp, 'app.1.log').readAsLinesSync().last) as Map;
    final current =
        jsonDecode(log(tmp).readAsLinesSync().last) as Map;
    expect(current['ts'].toString().compareTo(rotated['ts'].toString()), greaterThan(0),
        reason: '当前文件应比轮转文件新');
  });

  test('轮转文件数超过 maxFiles 时删除最老', () {
    final store = LogFileStore(tmp, maxBytesPerFile: 100, maxFiles: 2);
    final long = 'y' * 60;
    for (var i = 0; i < 20; i++) {
      store.write({'ts': 't$i', 'level': 'info', 'message': long});
    }

    expect(log(tmp).existsSync(), isTrue);
    expect(log(tmp, 'app.1.log').existsSync(), isTrue);
    expect(log(tmp, 'app.2.log').existsSync(), isFalse,
        reason: 'maxFiles=2 时最老的轮转文件应被删除');
  });

  test('构造时自动创建日志目录', () {
    final nested =
        Directory('${tmp.path}${Platform.pathSeparator}logs');
    LogFileStore(nested);
    expect(nested.existsSync(), isTrue);
  });
}
