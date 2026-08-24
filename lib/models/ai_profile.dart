import '../services/ai/translation_service.dart' show AiApiConfig;

/// AI 配置档案（v2.2.1）：OpenAI / DeepSeek / 中转站多套配置一键切换，
/// 不用反复改单条配置。同名视为同一档案（重名校验依据）。
class AiProfile {
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;

  const AiProfile({
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  bool get isReady =>
      baseUrl.trim().isNotEmpty &&
      apiKey.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  AiApiConfig get config =>
      AiApiConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);

  Map<String, dynamic> toJson() =>
      {'name': name, 'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};

  factory AiProfile.fromJson(Map<String, dynamic> j) => AiProfile(
        name: (j['name'] ?? '') as String,
        baseUrl: (j['baseUrl'] ?? '') as String,
        apiKey: (j['apiKey'] ?? '') as String,
        model: (j['model'] ?? '') as String,
      );

  @override
  bool operator ==(Object other) => other is AiProfile && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// 主备降级（v2.2.1）：主配置以 HTTP / 网络类错误（非解析类）耗尽重试后，
/// 取激活档案之外第一个配置完整的档案作为备用重跑；
/// 解析类失败（模型可达、输出异常）不降级。
class AiFailover {
  AiFailover._();

  static AiApiConfig? fallbackAfter({
    required List<AiProfile> profiles,
    required String activeName,
    required bool parseFailure,
  }) {
    if (parseFailure) return null;
    for (final p in profiles) {
      if (p.name == activeName) continue;
      if (p.isReady) return p.config;
    }
    return null;
  }
}
