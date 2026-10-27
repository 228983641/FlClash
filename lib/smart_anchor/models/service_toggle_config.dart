class ServiceToggleConfig {
  const ServiceToggleConfig({
    required this.serviceId,
    required this.displayName,
    required this.isEnabled,
    required this.targetCountry,
    required this.matchRules,
    required this.dnsDomains,
    this.targetCountries = const [],
    this.officialName = '',
    this.regionMode = 'blacklist',
    this.regionCountries = const [],
  });

  final String serviceId;
  final String displayName;
  final bool isEnabled;
  final String targetCountry;
  final List<String> matchRules;
  final List<String> dnsDomains;
  final List<String> targetCountries;

  /// The vendor's own spelling, used for proxy group names. Empty means the
  /// display name already is the official spelling.
  final String officialName;

  /// Region filter mode for this service: 'blacklist' bans the listed
  /// regions, 'whitelist' allows only the listed regions.
  final String regionMode;

  /// Regions (country codes) checked in the region filter.
  final List<String> regionCountries;

  String get groupLabel => officialName.isEmpty ? displayName : officialName;

  String get effectiveRegionMode =>
      regionMode == 'whitelist' ? 'whitelist' : 'blacklist';

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
    String? regionMode,
    List<String>? regionCountries,
  }) {
    return ServiceToggleConfig(
      serviceId: serviceId,
      displayName: displayName,
      isEnabled: isEnabled ?? this.isEnabled,
      targetCountry: targetCountry ?? this.targetCountry,
      matchRules: matchRules,
      dnsDomains: dnsDomains,
      targetCountries: targetCountries ?? this.targetCountries,
      officialName: officialName,
      regionMode: regionMode ?? this.regionMode,
      regionCountries: regionCountries ?? this.regionCountries,
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
    'officialName': officialName,
    'regionMode': regionMode,
    'regionCountries': regionCountries,
  };

  factory ServiceToggleConfig.fromJson(Map<String, dynamic> json) {
    final countries = json['targetCountries'];
    final countryList = countries is List
        ? [for (final country in countries) country.toString()]
        : const <String>[];
    final regionRaw = json['regionCountries'];
    final regionList = regionRaw is List
        ? [for (final country in regionRaw) country.toString()]
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
      officialName: json['officialName'] as String? ?? '',
      regionMode: json['regionMode'] as String? ?? 'blacklist',
      regionCountries: regionList,
    );
  }
}

String smartGroupName(ServiceToggleConfig service) =>
    '🎯 Smart-${service.groupLabel}';

String smartGroupNameForId(
  String serviceId,
  Map<String, ServiceToggleConfig> serviceById,
) {
  final service = serviceById[serviceId];
  if (service == null) {
    return '🎯 Smart-${serviceId.toUpperCase()}';
  }
  return smartGroupName(service);
}

const List<ServiceToggleConfig> defaultServiceToggles = [
  ServiceToggleConfig(
    serviceId: 'claude',
    displayName: 'Claude (克劳德)',
    officialName: 'Claude',
    isEnabled: false,
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
    officialName: 'ChatGPT',
    isEnabled: false,
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
    officialName: 'Gemini',
    isEnabled: false,
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
    officialName: 'Cloudflare',
    isEnabled: false,
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
    officialName: 'Netflix',
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
    officialName: 'Google',
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
    officialName: 'X',
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
    officialName: 'Grok',
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
  ServiceToggleConfig(
    serviceId: 'muse',
    displayName: 'Muse (Meta)',
    officialName: 'Muse',
    isEnabled: false,
    targetCountry: 'US',
    matchRules: ['DOMAIN-SUFFIX,muse.ai'],
    dnsDomains: ['muse.ai'],
  ),
];
