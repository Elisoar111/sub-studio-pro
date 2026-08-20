import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/constants.dart';

/// 新版本信息（GitHub Releases latest 解析结果）。
class UpdateInfo {
  /// 版本号（已剥 v 前缀，如 `2.1.0`）。
  final String version;

  /// Release 页面链接（浏览器兜底入口）。
  final String releaseUrl;

  /// `SubtitleStudioPro-*-setup.exe` 资产直链；null = 该 Release 未带
  /// 安装包（UI 回退打开 [releaseUrl]）。
  final String? setupUrl;

  /// Release Notes（Markdown 原文）。
  final String notes;

  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.setupUrl,
    required this.notes,
  });
}

/// 语义化版本比较：仅取数字段逐段比较，忽略 `v` 前缀与非数字后缀
/// （`v2.10.0-beta` → 2.10.0）。a>b 返回 1，相等 0，否则 -1。
int compareVersions(String a, String b) {
  List<int> parse(String s) => s.trim().replaceFirst(RegExp(r'^[vV]'), '')
      .split(RegExp(r'[.-]'))
      .map((seg) => int.tryParse(seg) ?? 0)
      .toList();
  final pa = parse(a);
  final pb = parse(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final d = (i < pa.length ? pa[i] : 0) - (i < pb.length ? pb[i] : 0);
    if (d != 0) return d > 0 ? 1 : -1;
  }
  return 0;
}

/// 应用更新（v1.5 自动更新）：
/// - [checkLatest] 查 GitHub Releases `latest`，与当前版本比较；
/// - [downloadSetup] 流式下载安装包（进度回调 0..1）；
/// - [launchInstaller] 启动安装包（/SILENT 静默升级）。
///
/// 网络层用 dart:io HttpClient（与 AI 翻译一致，不引入 http 包）；
/// [apiBase] / [repoSlug] 构造可注入，测试用本机 HttpServer 假扮 API。
class UpdateService {
  UpdateService(
      {this.apiBase = 'https://api.github.com',
      this.repoSlug = 'Elisoar111/sub-studio-pro'});

  static final UpdateService instance =
      UpdateService(repoSlug: 'Elisoar111/sub-studio-pro');

  /// GitHub API 根地址（测试注入本机 HttpServer）。
  final String apiBase;

  /// 仓库 `owner/name`。
  final String repoSlug;

  final _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// 查询最新 Release；比 [currentVersion] 新则返回信息，否则 null。
  ///
  /// 404（尚未发布过任何 Release）按无更新处理；其余网络/解析异常
  /// 原样上抛，由调用方决定静默降级还是提示。
  Future<UpdateInfo?> checkLatest({
    required String currentVersion,
  }) async {
    final uri = Uri.parse('$apiBase/repos/$repoSlug/releases/latest');
    final req = await _client.getUrl(uri);
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw HttpException('GitHub API ${res.statusCode}');
    }
    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body) as Map<String, dynamic>;
    final tag = (json['tag_name'] as String?)?.trim() ?? '';
    final htmlUrl = (json['html_url'] as String?) ?? '';
    if (tag.isEmpty) return null;

    // 安装包资产：SubtitleStudioPro-<版本>-setup.exe（便携版 zip 不用于升级）
    String? setupUrl;
    final assets = (json['assets'] as List?) ?? const [];
    for (final a in assets) {
      final name = (a as Map<String, dynamic>)['name'] as String? ?? '';
      if (RegExp(r'^SubtitleStudioPro-.*-setup\.exe$').hasMatch(name)) {
        setupUrl = a['browser_download_url'] as String?;
        break;
      }
    }

    final version = tag.replaceFirst(RegExp(r'^[vV]'), '');
    if (compareVersions(version, currentVersion) <= 0) return null;
    return UpdateInfo(
      version: version,
      releaseUrl: htmlUrl,
      setupUrl: setupUrl,
      notes: (json['body'] as String?) ?? '',
    );
  }

  /// 流式下载 [url] 到 [destPath]；[onProgress] 回调 0..1。
  Future<File> downloadSetup(
    String url,
    String destPath, {
    void Function(double progress)? onProgress,
  }) async {
    final req = await _client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('下载失败 HTTP ${res.statusCode}');
    }
    final total = res.contentLength;
    final sink = File(destPath).openSync(mode: FileMode.write);
    try {
      var received = 0;
      await for (final chunk in res) {
        sink.writeFromSync(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
    onProgress?.call(1.0);
    return File(destPath);
  }

  /// 启动安装包做静默升级（/SILENT：仅进度条不问问题）。
  /// detached：安装程序独立于本进程存活，调用方随后应退出应用。
  Future<void> launchInstaller(String setupPath) async {
    await Process.start(
      setupPath,
      const ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART'],
      mode: ProcessStartMode.detached,
    );
  }
}

/// 启动检查结果（v1.5-2）：后台静默检查发现新版本时写入，
/// 首页据此显示可关闭的更新横幅；用户关闭或升级后置回 null。
final ValueNotifier<UpdateInfo?> startupUpdate = ValueNotifier<UpdateInfo?>(null);

/// 启动时静默检查更新（v1.5-2）：有新版本才写 [startupUpdate]，
/// 网络/解析异常一律吞掉——启动检查绝不打扰用户。
/// [service] 注入缝：测试传 fake，默认走 GitHub API 单例。
Future<void> checkForUpdatesSilently({UpdateService? service}) async {
  try {
    final info = await (service ?? UpdateService.instance)
        .checkLatest(currentVersion: AppConstants.appVersion);
    if (info != null) startupUpdate.value = info;
  } catch (_) {
    // 静默失败：无网络 / API 限流等场景不打扰用户
  }
}
