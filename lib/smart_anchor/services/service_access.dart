enum ServiceAccessReason {
  accessible,
  regionBlocked,
  serviceDown,
  networkFailed,
  unknown,
}

class ServiceAccessResult {
  const ServiceAccessResult({
    required this.serviceId,
    required this.proxyName,
    required this.egressIp,
    required this.reason,
    required this.checkedAt,
    this.ttlHours = 24,
  });

  final String serviceId;
  final String proxyName;
  final String egressIp;
  final ServiceAccessReason reason;
  final int checkedAt;
  final int ttlHours;

  bool get isAccessible => reason == ServiceAccessReason.accessible;

  bool get isExpired {
    final ageMs = DateTime.now().millisecondsSinceEpoch - checkedAt;
    return ageMs > ttlHours * 3600 * 1000;
  }

  bool get blocksRanking => reason == ServiceAccessReason.regionBlocked;

  Map<String, dynamic> toJson() => {
    'serviceId': serviceId,
    'proxyName': proxyName,
    'egressIp': egressIp,
    'reason': reason.name,
    'checkedAt': checkedAt,
    'ttlHours': ttlHours,
  };

  factory ServiceAccessResult.fromJson(Map<String, dynamic> json) {
    return ServiceAccessResult(
      serviceId: json['serviceId'] as String,
      proxyName: json['proxyName'] as String,
      egressIp: json['egressIp'] as String,
      reason: ServiceAccessReason.values.byName(json['reason'] as String),
      checkedAt: json['checkedAt'] as int,
      ttlHours: (json['ttlHours'] as num?)?.toInt() ?? 24,
    );
  }
}

class ServiceProbeEndpoint {
  const ServiceProbeEndpoint({required this.url, required this.chain});

  final String url;
  final String chain;
}

class ServiceProbeConfig {
  const ServiceProbeConfig({required this.serviceId, required this.endpoints});

  final String serviceId;
  final List<ServiceProbeEndpoint> endpoints;
}

const List<ServiceProbeConfig> defaultServiceProbeConfigs = [
  ServiceProbeConfig(
    serviceId: 'claude',
    endpoints: [
      ServiceProbeEndpoint(url: 'https://claude.ai', chain: 'web'),
      ServiceProbeEndpoint(url: 'https://api.anthropic.com', chain: 'api'),
    ],
  ),
  ServiceProbeConfig(
    serviceId: 'openai',
    endpoints: [
      ServiceProbeEndpoint(url: 'https://chatgpt.com', chain: 'web'),
      ServiceProbeEndpoint(
        url: 'https://api.openai.com/v1/models',
        chain: 'api',
      ),
    ],
  ),
  ServiceProbeConfig(
    serviceId: 'gemini',
    endpoints: [
      ServiceProbeEndpoint(url: 'https://gemini.google.com', chain: 'web'),
      ServiceProbeEndpoint(
        url: 'https://generativelanguage.googleapis.com/v1/models',
        chain: 'api',
      ),
    ],
  ),
  ServiceProbeConfig(
    serviceId: 'cloudflare',
    endpoints: [
      ServiceProbeEndpoint(
        url: 'https://challenges.cloudflare.com',
        chain: 'web',
      ),
    ],
  ),
  ServiceProbeConfig(
    serviceId: 'netflix',
    endpoints: [
      ServiceProbeEndpoint(url: 'https://www.netflix.com', chain: 'web'),
    ],
  ),
  ServiceProbeConfig(
    serviceId: 'youtube',
    endpoints: [
      ServiceProbeEndpoint(url: 'https://www.youtube.com', chain: 'web'),
    ],
  ),
  ServiceProbeConfig(
    serviceId: 'x',
    endpoints: [
      ServiceProbeEndpoint(url: 'https://x.com', chain: 'web'),
      ServiceProbeEndpoint(url: 'https://api.x.com', chain: 'api'),
    ],
  ),
];

const _regionBlockedMarkers = [
  'not supported in your country',
  'unsupported country',
  'not available in your region',
  'not available in your country',
  'service is not available',
  'restricted region',
  'geo-block',
  'geoblocked',
];

ServiceAccessReason classifyProbeResponse({
  required int? statusCode,
  required String body,
  required bool networkError,
}) {
  if (networkError || statusCode == null) {
    return ServiceAccessReason.networkFailed;
  }
  if (statusCode == 200 ||
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 400 ||
      statusCode == 401) {
    return ServiceAccessReason.accessible;
  }
  if (statusCode == 403) {
    final lower = body.toLowerCase();
    for (final marker in _regionBlockedMarkers) {
      if (lower.contains(marker)) {
        return ServiceAccessReason.regionBlocked;
      }
    }
    return ServiceAccessReason.unknown;
  }
  if (statusCode == 429 || statusCode >= 500) {
    return ServiceAccessReason.serviceDown;
  }
  return ServiceAccessReason.unknown;
}

class ServiceOutageGuard {
  ServiceOutageGuard({this.threshold = 3, this.windowMs = 5 * 60 * 1000});

  final int threshold;
  final int windowMs;
  final List<int> _serviceDownAt = [];
  bool _officialOutage = false;

  void noteOfficialOutage() {
    _officialOutage = true;
  }

  bool get officialOutage => _officialOutage;

  bool get shouldNotBlameNodes => suspectedOutage || _officialOutage;

  void recordFailure(ServiceAccessReason reason, int nowMs) {
    if (reason != ServiceAccessReason.serviceDown) {
      return;
    }
    _serviceDownAt.add(nowMs);
    _serviceDownAt.removeWhere((at) => nowMs - at > windowMs);
  }

  bool get suspectedOutage => _serviceDownAt.length >= threshold;

  void reset() {
    _serviceDownAt.clear();
    _officialOutage = false;
  }
}
