import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/services/storage_service.dart';

/// v2.2.1 AI 网络参数（设置层）：
/// - 超时秒数 / 重试次数 / 并发数：默认 120 / 2 / 1，可保存
/// - v2.2.2 移除 token 计费单价（不再有输入/输出价格设置）
void main() {
  setUp(() {
    StorageService.instance.useMemoryStoreForTesting();
  });

  test('默认值：120s 超时 / 2 次重试 / 1 并发', () {
    final s = SettingsProvider.instance;
    expect(s.aiTimeoutSeconds, 120);
    expect(s.aiRetries, 2);
    expect(s.aiConcurrency, 1);
  });

  test('setAiNetworkParams：保存并持久化', () async {
    final s = SettingsProvider.instance;
    await s.setAiNetworkParams(timeoutSeconds: 60, retries: 4, concurrency: 3);
    expect(s.aiTimeoutSeconds, 60);
    expect(s.aiRetries, 4);
    expect(s.aiConcurrency, 3);
    expect(
      StorageService.instance.getSetting('ai_timeout_seconds'),
      '60',
    );
    expect(StorageService.instance.getSetting('ai_retries'), '4');
    expect(StorageService.instance.getSetting('ai_concurrency'), '3');
  });

  test('setAiNetworkParams：非法值回退默认（超时<10s、重试>5、并发>4）', () async {
    final s = SettingsProvider.instance;
    await s.setAiNetworkParams(timeoutSeconds: 1, retries: 99, concurrency: 99);
    expect(s.aiTimeoutSeconds, 120, reason: '过小超时回退默认');
    expect(s.aiRetries, 5, reason: '重试上限 5');
    expect(s.aiConcurrency, 4, reason: '并发上限 4');
  });

  test('load()：从存储恢复（含容错解析）', () async {
    final store = StorageService.instance;
    await store.setSetting('ai_timeout_seconds', '90');
    await store.setSetting('ai_retries', '3');
    await store.setSetting('ai_concurrency', '2');
    await SettingsProvider.instance.load();
    final s = SettingsProvider.instance;
    expect(s.aiTimeoutSeconds, 90);
    expect(s.aiRetries, 3);
    expect(s.aiConcurrency, 2);

    await store.setSetting('ai_timeout_seconds', 'not-a-number');
    await SettingsProvider.instance.load();
    expect(s.aiTimeoutSeconds, 120, reason: '解析失败回退默认');
  });
}
