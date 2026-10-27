enum OfficialServiceStatus { operational, degraded, outage, unknown }

const Map<String, String> officialStatusEndpoints = {
  'claude': 'https://status.anthropic.com/api/v2/status.json',
  'openai': 'https://status.openai.com/api/v2/status.json',
  'cloudflare': 'https://www.cloudflarestatus.com/api/v2/status.json',
};

OfficialServiceStatus parseStatuspageStatus(Map<String, dynamic> json) {
  final status = json['status'];
  if (status is! Map<String, dynamic>) {
    return OfficialServiceStatus.unknown;
  }
  return switch (status['indicator']) {
    'none' => OfficialServiceStatus.operational,
    'minor' => OfficialServiceStatus.degraded,
    'major' || 'critical' => OfficialServiceStatus.outage,
    _ => OfficialServiceStatus.unknown,
  };
}
