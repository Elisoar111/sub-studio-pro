import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:subtitle_studio_pro/core/constants.dart';
import 'package:subtitle_studio_pro/services/update/update_service.dart';

/// 自动更新（v1.5-2）：GitHub Releases 启动检查 + 一键升级。
///
/// UpdateService 构造可注入 apiBase，测试用本机 HttpServer 假扮
/// GitHub API；版本比较为纯函数直测。
void main() {
  group('compareVersions', () {
    test('语义化版本数值比较（含多位数）', () {
      expect(compareVersions('2.1.0', '2.0.0'), 1);
      expect(compareVersions('2.0.0', '2.0.0'), 0);
      expect(compareVersions('2.10.0', '2.9.0'), 1,
          reason: '按段数值比，不是字符串比');
      expect(compareVersions('10.0.0', '9.0.0'), 1);
      expect(compareVersions('2.0.1', '2.0.0'), 1);
      expect(compareVersions('1.9.9', '2.0.0'), -1);
    });

    test('v 前缀 / 缺段 / 后缀容忍', () {
      expect(compareVersions('v2.1.0', '2.0.0'), 1, reason: 'tag 的 v 前缀剥离');
      expect(compareVersions('2.1', '2.0.9'), 1, reason: '缺段按 0 补');
      expect(compareVersions('2.1.0-beta', '2.0.0'), 1,
          reason: '非数字后缀不参与比较');
    });
  });

  group('UpdateService.checkLatest（本机 HttpServer 假扮 GitHub API）', () {
    late HttpServer server;
    late UpdateService svc;
    Object? servedBody;
    int servedStatus = 200;

    setUp(() async {
      servedBody = null;
      servedStatus = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final res = req.response;
        res.statusCode = servedStatus;
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(servedBody ?? {}));
        await res.close();
      });
      svc = UpdateService(apiBase: 'http://127.0.0.1:${server.port}');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    Map<String, dynamic> release(String tag) => {
          'tag_name': tag,
          'html_url': 'https://github.com/demo/app/releases/tag/$tag',
          'assets': [
            {
              'name': 'SubtitleStudioPro-$tag-setup.exe',
              'browser_download_url':
                  'https://github.com/demo/app/releases/download/$tag/SubtitleStudioPro-$tag-setup.exe',
            },
            {
              'name': 'subtitle-studio-pro-$tag-portable.zip',
              'browser_download_url': 'ignored',
            },
          ],
          'body': 'release notes here',
        };

    test('远端版本更新 → 返回 UpdateInfo（含 setup 资产直链）', () async {
      servedBody = release('v2.1.0');

      final info = await svc.checkLatest(currentVersion: '2.0.0');

      expect(info, isNotNull);
      expect(info!.version, '2.1.0');
      expect(info.setupUrl,
          contains('SubtitleStudioPro-v2.1.0-setup.exe'));
      expect(info.releaseUrl, contains('releases/tag/v2.1.0'));
      expect(info.notes, 'release notes here');
    });

    test('版本相同或更低 → null（无更新）', () async {
      servedBody = release('v2.0.0');
      expect(await svc.checkLatest(currentVersion: '2.0.0'), isNull);

      servedBody = release('v1.9.0');
      expect(await svc.checkLatest(currentVersion: '2.0.0'), isNull);
    });

    test('404（尚无 release）→ null 而非异常', () async {
      servedStatus = 404;
      expect(await svc.checkLatest(currentVersion: '2.0.0'), isNull);
    });

    test('无 setup 资产 → setupUrl 为 null（UI 回退打开 Release 页）', () async {
      servedBody = {
        'tag_name': 'v2.1.0',
        'html_url': 'https://github.com/demo/app/releases/tag/v2.1.0',
        'assets': [
          {'name': 'subtitle-studio-pro-v2.1.0-portable.zip', 'browser_download_url': 'x'},
        ],
      };

      final info = await svc.checkLatest(currentVersion: '2.0.0');

      expect(info, isNotNull);
      expect(info!.setupUrl, isNull);
    });

    test('网络异常 → 抛出的异常向上传播（调用方静默降级）', () async {
      await server.close(force: true);
      expect(
        () => svc.checkLatest(currentVersion: '2.0.0'),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('UpdateService.downloadSetup', () {
    test('流式下载到目标文件并回调进度至 1.0', () async {
      final payload = List<int>.generate(256 * 1024, (i) => i & 0xff);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final res = req.response;
        res.headers.contentLength = payload.length;
        res.add(payload);
        await res.close();
      });
      addTearDown(() => server.close(force: true));

      final svc = UpdateService(apiBase: 'http://x');
      final dir = Directory.systemTemp.createTempSync('update_dl_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dest =
          '${dir.path}${Platform.pathSeparator}setup.exe';

      final progress = <double>[];
      final file = await svc.downloadSetup(
        'http://127.0.0.1:${server.port}/setup.exe',
        dest,
        onProgress: progress.add,
      );

      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), payload.length);
      expect(progress.last, 1.0);
      expect(progress.first, lessThan(1.0));
    });
  });

  test('AppConstants.appVersion 与 pubspec.yaml 同步（防漂移）', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true)
        .firstMatch(pubspec);
    expect(m, isNotNull, reason: 'pubspec.yaml 缺 version 字段');
    expect(AppConstants.appVersion, m!.group(1),
        reason: 'AppConstants.appVersion 与 pubspec 版本漂移，请同步');
  });

  group('checkForUpdatesSilently 启动检查（v1.5-2）', () {
    test('发现新版本 → 写入 startupUpdate', () async {
      startupUpdate.value = null;

      await checkForUpdatesSilently(
        service: _FakeService(const UpdateInfo(
          version: '9.9.9',
          releaseUrl: 'u',
          setupUrl: 's',
          notes: '',
        )),
      );

      expect(startupUpdate.value?.version, '9.9.9');
      startupUpdate.value = null;
    });

    test('已是最新 → 不写入；异常 → 静默吞掉且不写入', () async {
      startupUpdate.value = null;

      await checkForUpdatesSilently(service: _FakeService(null));
      expect(startupUpdate.value, isNull, reason: '无更新不应写横幅状态');

      await checkForUpdatesSilently(
          service: _FakeService(null, error: const HttpException('offline')));
      expect(startupUpdate.value, isNull, reason: '网络失败应静默降级');
    });
  });
}

class _FakeService extends UpdateService {
  _FakeService(this._info, {this.error});

  final UpdateInfo? _info;
  final Object? error;

  @override
  Future<UpdateInfo?> checkLatest({required String currentVersion}) async {
    if (error != null) throw error!;
    return _info;
  }
}
