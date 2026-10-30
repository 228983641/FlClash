enum ServiceAccessReason {
  accessible,
  regionBlocked,
  ispBlocked,
  restricted,
  blocked,
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
    this.borrowedFrom,
  });

  final String serviceId;
  final String proxyName;
  final String egressIp;
  final ServiceAccessReason reason;
  final int checkedAt;
  final int ttlHours;

  /// The service whose own probe produced this result, when the service
  /// itself has no core checker and borrowed a donor's verdict. Null means
  /// the result is the service's own measurement. Borrowed verdicts may
  /// exclude a node or a region, but they are not evidence about this
  /// service: the failover guard ignores them and they never count as a
  /// confirmed reachability.
  final String? borrowedFrom;

  bool get isAccessible => reason == ServiceAccessReason.accessible;

  bool get isExpired {
    final ageMs = DateTime.now().millisecondsSinceEpoch - checkedAt;
    return ageMs > ttlHours * 3600 * 1000;
  }

  /// Whether this verdict excludes its own node from the service's
  /// ranking. The split blocking verdicts share this node-level
  /// consequence; they differ only in what they prove about the region.
  bool get blocksRanking =>
      reason == ServiceAccessReason.regionBlocked ||
      reason == ServiceAccessReason.ispBlocked ||
      reason == ServiceAccessReason.restricted ||
      reason == ServiceAccessReason.blocked;

  /// Whether this verdict may blacklist the node's whole country in the
  /// derived unsupported-region set. Only a genuine region verdict is
  /// country evidence: an ISP refusal, a service restriction or a plain
  /// block condemns the node (or its egress), not every node sharing its
  /// country.
  bool get derivesRegionBlock => reason == ServiceAccessReason.regionBlocked;

  Map<String, dynamic> toJson() => {
    'serviceId': serviceId,
    'proxyName': proxyName,
    'egressIp': egressIp,
    'reason': reason.name,
    'checkedAt': checkedAt,
    'ttlHours': ttlHours,
    'borrowedFrom': borrowedFrom,
  };

  factory ServiceAccessResult.fromJson(Map<String, dynamic> json) {
    return ServiceAccessResult(
      serviceId: json['serviceId'] as String,
      proxyName: json['proxyName'] as String,
      egressIp: json['egressIp'] as String,
      reason: ServiceAccessReason.values.byName(json['reason'] as String),
      checkedAt: json['checkedAt'] as int,
      ttlHours: (json['ttlHours'] as num?)?.toInt() ?? 24,
      borrowedFrom: json['borrowedFrom'] as String?,
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

/// Distinct nodes of one service reporting [ServiceAccessReason.serviceDown]
/// inside the window before the failures read as the service's own
/// outage rather than its nodes' faults. The threshold and window keep
/// the values the retired stateful guard used; counting distinct nodes
/// in the caller's snapshot is stricter than counting repeated events,
/// because one node re-reporting cannot manufacture an outage.
const int serviceOutageThreshold = 3;
const int serviceOutageWindowMs = 5 * 60 * 1000;

int serviceOutageEvidenceCount(
  Map<String, ServiceAccessResult> accessByProxy,
  int nowMs,
) {
  var count = 0;
  for (final verdict in accessByProxy.values) {
    if (verdict.reason != ServiceAccessReason.serviceDown) {
      continue;
    }
    if (verdict.borrowedFrom != null || verdict.isExpired) {
      continue;
    }
    if (nowMs - verdict.checkedAt > serviceOutageWindowMs) {
      continue;
    }
    count++;
  }
  return count;
}

bool serviceOutageSuspected(
  Map<String, ServiceAccessResult> accessByProxy,
  int nowMs,
) {
  return serviceOutageEvidenceCount(accessByProxy, nowMs) >=
      serviceOutageThreshold;
}
