class ServiceToggleConfig {
  const ServiceToggleConfig({
    required this.serviceId,
    required this.displayName,
    required this.isEnabled,
    required this.targetCountry,
    required this.matchRules,
    required this.dnsDomains,
  });

  final String serviceId;
  final String displayName;
  final bool isEnabled;
  final String targetCountry;
  final List<String> matchRules;
  final List<String> dnsDomains;

  List<String> get lockedCountries {
    final code = targetCountry.trim().toUpperCase();
    return code.isEmpty ? const [] : [code];
  }

  ServiceToggleConfig copyWith({bool? isEnabled, String? targetCountry}) {
    return ServiceToggleConfig(
      serviceId: serviceId,
      displayName: displayName,
      isEnabled: isEnabled ?? this.isEnabled,
      targetCountry: targetCountry ?? this.targetCountry,
      matchRules: matchRules,
      dnsDomains: dnsDomains,
    );
  }

  Map<String, dynamic> toJson() => {
        'serviceId': serviceId,
        'displayName': displayName,
        'isEnabled': isEnabled,
        'targetCountry': targetCountry,
        'matchRules': matchRules,
        'dnsDomains': dnsDomains,
      };

  factory ServiceToggleConfig.fromJson(Map<String, dynamic> json) {
    final countries = json['targetCountries'];
    final firstCountry = countries is List && countries.isNotEmpty
        ? countries.first.toString()
        : null;
    return ServiceToggleConfig(
      serviceId: json['serviceId'] as String,
      displayName: json['displayName'] as String,
      isEnabled: json['isEnabled'] as bool,
      targetCountry:
          firstCountry ?? (json['targetCountry'] as String? ?? ''),
      matchRules: List<String>.from(json['matchRules'] as List),
      dnsDomains: List<String>.from(json['dnsDomains'] as List),
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
    matchRules: ['GEOSITE,google', 'GEOSITE,youtube'],
    dnsDomains: ['google.com', 'youtube.com'],
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
];
