import 'package:flutter_test/flutter_test.dart';
import 'package:subtitle_studio_pro/models/ai_profile.dart';
import 'package:subtitle_studio_pro/providers/app_providers.dart';
import 'package:subtitle_studio_pro/services/storage_service.dart';

/// v2.2.1 多配置档案：
/// - AiProfile JSON 序列化
/// - SettingsProvider：档案列表存取、激活切换同步单配置字段、
///   无档案时保持旧单配置行为（向后兼容）
/// - 主备降级：主档案 HTTP 类失败后取第一个就绪备用档案
void main() {
  setUp(() {
    StorageService.instance.useMemoryStoreForTesting();
  });

  group('AiProfile', () {
    test('JSON roundtrip', () {
      const p = AiProfile(
          name: 'DeepSeek', baseUrl: 'https://api.deepseek.com', apiKey: 'sk-1', model: 'deepseek-chat');
      final j = p.toJson();
      expect(AiProfile.fromJson(j), p);
    });

    test('config：转 AiApiConfig；isReady 判定', () {
      const p = AiProfile(name: 'x', baseUrl: 'b', apiKey: 'k', model: 'm');
      expect(p.isReady, isTrue);
      expect(p.config.model, 'm');
      expect(const AiProfile(name: 'x', baseUrl: '', apiKey: 'k', model: 'm').isReady, isFalse);
    });

    test('相等性（重名校验用）', () {
      const a = AiProfile(name: 'P', baseUrl: 'u', apiKey: 'k', model: 'm');
      const b = AiProfile(name: 'P', baseUrl: 'u2', apiKey: 'k2', model: 'm2');
      expect(a, b, reason: '同名即同一档案');
    });
  });

  group('SettingsProvider 档案', () {
    test('默认无档案：单配置行为不受影响', () {
      final s = SettingsProvider.instance;
      expect(s.aiProfiles, isEmpty);
      expect(s.aiActiveProfile, isEmpty);
    });

    test('setAiProfiles：保存列表并激活首个（同步单配置字段）', () async {
      final s = SettingsProvider.instance;
      await s.setAiProfiles(const [
        AiProfile(name: 'OpenAI', baseUrl: 'https://api.openai.com', apiKey: 'sk-a', model: 'gpt-4o-mini'),
        AiProfile(name: 'DeepSeek', baseUrl: 'https://api.deepseek.com', apiKey: 'sk-b', model: 'deepseek-chat'),
      ]);
      expect(s.aiProfiles.length, 2);
      expect(s.aiActiveProfile, 'OpenAI', reason: '默认激活第一个');
      expect(s.aiBaseUrl, 'https://api.openai.com');
      expect(s.aiApiKey, 'sk-a');
      expect(s.aiModel, 'gpt-4o-mini');
    });

    test('switchAiProfile：切换激活并同步单配置', () async {
      final s = SettingsProvider.instance;
      await s.setAiProfiles(const [
        AiProfile(name: 'OpenAI', baseUrl: 'https://api.openai.com', apiKey: 'sk-a', model: 'gpt-4o-mini'),
        AiProfile(name: 'DeepSeek', baseUrl: 'https://api.deepseek.com', apiKey: 'sk-b', model: 'deepseek-chat'),
      ]);
      await s.switchAiProfile('DeepSeek');
      expect(s.aiActiveProfile, 'DeepSeek');
      expect(s.aiModel, 'deepseek-chat');

      // 切换回 OpenAI
      await s.switchAiProfile('OpenAI');
      expect(s.aiModel, 'gpt-4o-mini');
    });

    test('切换不存在的档案：忽略不抛异常', () async {
      final s = SettingsProvider.instance;
      await s.setAiProfiles(const [
        AiProfile(name: 'A', baseUrl: 'u', apiKey: 'k', model: 'm'),
      ]);
      await s.switchAiProfile('不存在的');
      expect(s.aiActiveProfile, 'A');
    });

    test('load()：从存储恢复档案与激活状态', () async {
      final store = StorageService.instance;
      await store.setSetting('ai_profiles',
          '[{"name":"P1","baseUrl":"u1","apiKey":"k1","model":"m1"},'
          '{"name":"P2","baseUrl":"u2","apiKey":"k2","model":"m2"}]');
      await store.setSetting('ai_active_profile', 'P2');
      await SettingsProvider.instance.load();
      final s = SettingsProvider.instance;
      expect(s.aiProfiles.length, 2);
      expect(s.aiActiveProfile, 'P2');
      expect(s.aiModel, 'm2', reason: '恢复激活档案的单配置字段');
    });

    test('重名档案被拒绝（同名校验）', () async {
      final s = SettingsProvider.instance;
      await s.setAiProfiles(const [
        AiProfile(name: 'A', baseUrl: 'u', apiKey: 'k', model: 'm'),
      ]);
      expect(
        () => s.setAiProfiles(const [
          AiProfile(name: 'A', baseUrl: 'u1', apiKey: 'k1', model: 'm1'),
          AiProfile(name: 'A', baseUrl: 'u2', apiKey: 'k2', model: 'm2'),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('主备降级', () {
    test('HTTP 类失败 → 返回激活档案之外第一个就绪档案', () {
      const profiles = [
        AiProfile(name: '主', baseUrl: 'u1', apiKey: 'k1', model: 'm1'),
        AiProfile(name: '备', baseUrl: 'u2', apiKey: 'k2', model: 'm2'),
      ];
      final fb = AiFailover.fallbackAfter(
        profiles: profiles,
        activeName: '主',
        parseFailure: false,
      );
      expect(fb, isNotNull);
      expect(fb!.model, 'm2');
    });

    test('解析类失败不降级（模型可达，输出问题换档案无益）', () {
      final fb = AiFailover.fallbackAfter(
        profiles: const [
          AiProfile(name: '主', baseUrl: 'u1', apiKey: 'k1', model: 'm1'),
          AiProfile(name: '备', baseUrl: 'u2', apiKey: 'k2', model: 'm2'),
        ],
        activeName: '主',
        parseFailure: true,
      );
      expect(fb, isNull);
    });

    test('无备用档案 / 备用未就绪 / 档案为空 → null', () {
      expect(
        AiFailover.fallbackAfter(
            profiles: const [], activeName: '', parseFailure: false),
        isNull,
      );
      expect(
        AiFailover.fallbackAfter(
          profiles: const [
            AiProfile(name: '主', baseUrl: 'u1', apiKey: 'k1', model: 'm1'),
            AiProfile(name: '备', baseUrl: '', apiKey: '', model: ''),
          ],
          activeName: '主',
          parseFailure: false,
        ),
        isNull,
        reason: '备用档案未配置完整不降级',
      );
    });
  });
}
