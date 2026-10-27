class ServiceToggleConfig {
  const ServiceToggleConfig({
    required this.serviceId,
    required this.displayName,
    required this.isEnabled,
    required this.targetCountry,
    required this.matchRules,
    required this.dnsDomains,
    this.targetCountries = const [],
  });

  final String serviceId;
  final String displayName;
  final bool isEnabled;
  final String targetCountry;
  final List<String> matchRules;
  final List<String> dnsDomains;
  final List<String> targetCountries;

  List<String> get lockedCountries {
    if (targetCountries.isNotEmpty) {
      final seen = <String>{};
      final result = <String>[];
      for (final country in targetCountries) {
        final code = country.trim().toUpperCase();
        if (code.isNotEmpty && seen.add(code)) {
          result.add(code);
        }
      }
      return result;
    }
    final code = targetCountry.trim().toUpperCase();
    return code.isEmpty ? const [] : [code];
  }

  ServiceToggleConfig copyWith({
    bool? isEnabled,
    String? targetCountry,
    List<String>? targetCountries,
  }) {
    return ServiceToggleConfig(
      serviceId: serviceId,
      displayName: displayName,
      isEnabled: isEnabled ?? this.isEnabled,
      targetCountry: targetCountry ?? this.targetCountry,
      matchRules: matchRules,
      dnsDomains: dnsDomains,
      targetCountries: targetCountries ?? this.targetCountries,
    );
  }

  Map<String, dynamic> toJson() => {
    'serviceId': serviceId,
    'displayName': displayName,
    'isEnabled': isEnabled,
    'targetCountry': targetCountry,
    'matchRules': matchRules,
    'dnsDomains': dnsDomains,
    'targetCountries': targetCountries,
  };

  factory ServiceToggleConfig.fromJson(Map<String, dynamic> json) {
    final countries = json['targetCountries'];
    final countryList = countries is List
        ? [for (final country in countries) country.toString()]
        : const <String>[];
    return ServiceToggleConfig(
      serviceId: json['serviceId'] as String,
      displayName: json['displayName'] as String,
      isEnabled: json['isEnabled'] as bool,
      targetCountry: countryList.isNotEmpty
          ? countryList.first
          : (json['targetCountry'] as String? ?? ''),
      matchRules: List<String>.from(json['matchRules'] as List),
      dnsDomains: List<String>.from(json['dnsDomains'] as List),
      targetCountries: countryList,
    );
  }
}

const List<ServiceToggleConfig> defaultServiceToggles = [
  ServiceToggleConfig(
    serviceId: 'claude',
    displayName: 'Claude (克劳德)',
    isEnabled: true,
    targetCountry: 'US',
    matchRules: [
      'GEOSITE,anthropic',
      'DOMAIN-SUFFIX,claude.ai',
      'DOMAIN-SUFFIX,anthropic.com',
    ],
    dnsDomains: ['claude.ai', 'anthropic.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'openai',
    displayName: 'ChatGPT (OpenAI)',
    isEnabled: true,
    targetCountry: 'US',
    matchRules: [
      'GEOSITE,openai',
      'DOMAIN-SUFFIX,chatgpt.com',
      'DOMAIN-SUFFIX,oaistatic.com',
    ],
    dnsDomains: ['chatgpt.com', 'oaistatic.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'gemini',
    displayName: 'Google Gemini',
    isEnabled: true,
    targetCountry: 'US',
    matchRules: [
      'GEOSITE,google-gemini',
      'DOMAIN-SUFFIX,gemini.google.com',
      'DOMAIN-SUFFIX,makersuite.google.com',
    ],
    dnsDomains: ['gemini.google.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'cloudflare',
    displayName: 'Cloudflare 护盾站点',
    isEnabled: true,
    targetCountry: 'US',
    matchRules: [
      'GEOSITE,cloudflare',
      'DOMAIN-SUFFIX,cloudflare.com',
      'DOMAIN-SUFFIX,challenges.cloudflare.com',
    ],
    dnsDomains: ['cloudflare.com', 'challenges.cloudflare.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'netflix',
    displayName: 'Netflix (奈飞)',
    isEnabled: false,
    targetCountry: 'SG',
    matchRules: [
      'GEOSITE,netflix',
      'DOMAIN-SUFFIX,netflix.com',
      'DOMAIN-SUFFIX,nflxvideo.net',
    ],
    dnsDomains: ['netflix.com', 'nflxvideo.net'],
  ),
  ServiceToggleConfig(
    serviceId: 'google',
    displayName: 'Google 综合服务',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['GEOSITE,google'],
    dnsDomains: ['google.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'youtube',
    displayName: 'YouTube',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['GEOSITE,youtube'],
    dnsDomains: ['youtube.com', 'youtu.be'],
  ),
  ServiceToggleConfig(
    serviceId: 'x',
    displayName: 'X (Twitter)',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['GEOSITE,twitter'],
    dnsDomains: ['x.com', 'twitter.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'copilot',
    displayName: 'Microsoft Copilot',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,copilot.microsoft.com'],
    dnsDomains: ['copilot.microsoft.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'meta-ai',
    displayName: 'Meta AI',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,meta.ai'],
    dnsDomains: ['meta.ai'],
  ),
  ServiceToggleConfig(
    serviceId: 'grok',
    displayName: 'Grok (xAI)',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,grok.com', 'DOMAIN-SUFFIX,x.ai'],
    dnsDomains: ['grok.com', 'x.ai'],
  ),
  ServiceToggleConfig(
    serviceId: 'perplexity',
    displayName: 'Perplexity',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,perplexity.ai', 'DOMAIN-SUFFIX,perplexity.com'],
    dnsDomains: ['perplexity.ai', 'perplexity.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'mistral',
    displayName: 'Mistral Le Chat',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,chat.mistral.ai', 'DOMAIN-SUFFIX,mistral.ai'],
    dnsDomains: ['chat.mistral.ai', 'mistral.ai'],
  ),
  ServiceToggleConfig(
    serviceId: 'poe',
    displayName: 'Poe',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,poe.com'],
    dnsDomains: ['poe.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'deepseek',
    displayName: 'DeepSeek',
    isEnabled: false,
    targetCountry: '',
    matchRules: [
      'DOMAIN-SUFFIX,chat.deepseek.com',
      'DOMAIN-SUFFIX,deepseek.com',
    ],
    dnsDomains: ['chat.deepseek.com', 'deepseek.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'kimi',
    displayName: 'Kimi (Moonshot)',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['DOMAIN-SUFFIX,kimi.ai'],
    dnsDomains: ['kimi.ai'],
  ),
  ServiceToggleConfig(
    serviceId: 'doubao',
    displayName: '豆包 (Doubao)',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['DOMAIN-SUFFIX,doubao.com'],
    dnsDomains: ['doubao.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'qwen',
    displayName: 'Qwen (通义)',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['DOMAIN-SUFFIX,chat.qwen.ai', 'DOMAIN-SUFFIX,qwen.ai'],
    dnsDomains: ['chat.qwen.ai', 'qwen.ai'],
  ),
  ServiceToggleConfig(
    serviceId: 'glm',
    displayName: 'ChatGLM (智谱)',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['DOMAIN-SUFFIX,chatglm.cn', 'DOMAIN-SUFFIX,z.ai'],
    dnsDomains: ['chatglm.cn', 'z.ai'],
  ),
  ServiceToggleConfig(
    serviceId: 'ernie',
    displayName: '文心一言 (ERNIE)',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['DOMAIN-SUFFIX,yiyan.baidu.com'],
    dnsDomains: ['yiyan.baidu.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'yuanbao',
    displayName: '腾讯元宝 (Yuanbao)',
    isEnabled: false,
    targetCountry: '',
    matchRules: ['DOMAIN-SUFFIX,yuanbao.tencent.com'],
    dnsDomains: ['yuanbao.tencent.com'],
  ),
  ServiceToggleConfig(
    serviceId: 'disney',
    displayName: 'Disney+',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: [
      'DOMAIN-SUFFIX,disneyplus.com',
      'DOMAIN-SUFFIX,disney-plus.net',
    ],
    dnsDomains: ['disneyplus.com', 'disney-plus.net'],
  ),
  ServiceToggleConfig(
    serviceId: 'appletv',
    displayName: 'Apple TV+',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,tv.apple.com'],
    dnsDomains: ['tv.apple.com'],
  ),
];
