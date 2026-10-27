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
];
