import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/services/storage_service.dart';

void main() {
  setUp(() {
    StorageService.instance.useMemoryStoreForTesting();
  });

  test('dumpSettings 返回全部已写入设置', () async {
    final s = StorageService.instance;
    await s.setSetting('theme_mode', 'dark');
    await s.setSetting('ai_api_key', 'sk-secret');

    final dumped = s.dumpSettings();
    expect(dumped['theme_mode'], 'dark');
    expect(dumped['ai_api_key'], 'sk-secret');
    expect(dumped, hasLength(2));
  });

  test('未写入任何设置时返回空 Map', () {
    expect(StorageService.instance.dumpSettings(), isEmpty);
  });
}
