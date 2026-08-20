/// AI 服务商预置（仅 BaseURL，模型名不预置——
/// 由「获取模型列表」按 API Key 实时从服务商 /models 接口拉取）。
///
/// 归一化规则见 [AiApiConfig]：仅 host 的 BaseURL 自动补 /v1，
/// 带路径的（Gemini v1beta/openai、智谱 /api/paas/v4 等）原样保留。
class AiProvider {
  final String id;
  final String name;
  final String baseUrl;

  const AiProvider(this.id, this.name, this.baseUrl);
}

const List<AiProvider> aiProviders = [
  AiProvider('openai', 'OpenAI', 'https://api.openai.com'),
  AiProvider('anthropic', 'Anthropic Claude', 'https://api.anthropic.com'),
  AiProvider(
      'gemini', 'Google Gemini', 'https://generativelanguage.googleapis.com/v1beta/openai/'),
  AiProvider('deepseek', 'DeepSeek', 'https://api.deepseek.com'),
  AiProvider('qwen', '通义千问', 'https://dashscope.aliyuncs.com/compatible-mode'),
  AiProvider('glm', '智谱 GLM', 'https://open.bigmodel.cn/api/paas/v4'),
  AiProvider('moonshot', '月之暗面 Kimi', 'https://api.moonshot.cn'),
  AiProvider('siliconflow', '硅基流动', 'https://api.siliconflow.cn'),
  AiProvider('custom', '自定义', ''),
];
