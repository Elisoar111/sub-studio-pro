import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/logging/debug_bundle.dart';

void main() {
  late Directory tmp;
  late Directory logsDir;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('debug_bundle_test');
    logsDir = Directory('${tmp.path}${Platform.pathSeparator}logs')
      ..createSync();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Archive unzip(File zip) =>
      ZipDecoder().decodeBytes(zip.readAsBytesSync());

  test('导出 zip 含全部日志文件与 settings.json', () {
    File('${logsDir.path}${Platform.pathSeparator}app.log')
        .writeAsStringSync('{"ts":"t1","level":"info"}\n');
    File('${logsDir.path}${Platform.pathSeparator}app.1.log')
        .writeAsStringSync('{"ts":"t0","level":"info"}\n');
    File('${logsDir.path}${Platform.pathSeparator}note.txt')
        .writeAsStringSync('非日志文件不应打包');

    final zip = DebugBundle.export(
      logsDir: logsDir,
      settings: const {'theme_mode': 'dark'},
      outputPath: '${tmp.path}${Platform.pathSeparator}bundle.zip',
    );

    final names = unzip(zip).files.map((f) => f.name).toSet();
    expect(names, containsAll(['logs/app.log', 'logs/app.1.log', 'settings.json']));
    expect(names, isNot(contains('logs/note.txt')),
        reason: '只打包 .log 文件');
  });

  test('settings.json 中 API Key 已脱敏，其余设置原样保留', () {
    final zip = DebugBundle.export(
      logsDir: logsDir,
      settings: const {
        'ai_api_key': 'sk-1234567890abcdef',
        'theme_mode': 'dark',
      },
      outputPath: '${tmp.path}${Platform.pathSeparator}bundle.zip',
    );

    final settingsEntry =
        unzip(zip).files.firstWhere((f) => f.name == 'settings.json');
    final decoded =
        jsonDecode(utf8.decode(settingsEntry.content as List<int>))
            as Map<String, dynamic>;
    expect(decoded['ai_api_key'], 'sk-1****');
    expect(decoded['theme_mode'], 'dark');
  });

  test('sanitize：空 Key 留空、短 Key 全打码、非密钥键不动', () {
    final sanitized = DebugBundle.sanitize(const {
      'ai_api_key': '',
      'whisper_path': r'D:\tools\whisper.exe',
      'some_apikey_field': 'short',
    });

    expect(sanitized['ai_api_key'], '');
    expect(sanitized['whisper_path'], r'D:\tools\whisper.exe');
    expect(sanitized['some_apikey_field'], '****');
  });

  test('日志目录为空时仍可导出（仅 settings.json）', () {
    final zip = DebugBundle.export(
      logsDir: logsDir,
      settings: const {},
      outputPath: '${tmp.path}${Platform.pathSeparator}bundle.zip',
    );

    expect(zip.existsSync(), isTrue);
    expect(unzip(zip).files.map((f) => f.name), ['settings.json']);
  });
}
