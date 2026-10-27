import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/services/diagnostics.dart';
import 'package:fl_clash/smart_anchor/services/scoring_engine.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

NodeMetadataCache node(String name, String country) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: 'entry.example',
    egressIp: '1.2.3.4',
    countryCode: country,
    latitude: 22.28,
    longitude: 114.15,
    asn: 'AS1234',
    ipType: 'residential',
    fraudScore: 0,
    purityScore: 90,
    wafPass: true,
    updatedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

ServiceAccessResult access(
  String proxy,
  ServiceAccessReason reason,
) {
  return ServiceAccessResult(
    serviceId: 'gemini',
    proxyName: proxy,
    egressIp: '1.2.3.4',
    reason: reason,
    checkedAt: DateTime.now().millisecondsSinceEpoch,
  );
}

const anchor = ServiceAnchor(
  serviceTag: 'gemini',
  countryCode: 'HK',
  lastProxyName: 'HK-01',
  egressIp: '1.2.3.4',
  subnet24: '1.2.3',
  asn: 'AS1234',
  isp: 'Example',
  latitude: 22.28,
  longitude: 114.15,
  city: 'Hong Kong',
  confirmedAt: 0,
);

void main() {
  test('hong kong node passes youtube but is blocked for gemini', () {
    final nodes = [node('HK-01', 'HK'), node('HK-02', 'HK')];
    final youtubeAccess = {
      'HK-01': access('HK-01', ServiceAccessReason.accessible),
    };
    final geminiAccess = {
      'HK-01': access('HK-01', ServiceAccessReason.regionBlocked),
    };
    expect(
      ScoringEngine.filterForService(nodes, [], youtubeAccess).length,
      2,
    );
    expect(
      ScoringEngine.filterForService(nodes, [], geminiAccess)
          .map((n) => n.proxyName),
      ['HK-02'],
    );
    expect(
      ScoringEngine.rankForService(nodes, anchor, [], geminiAccess)
          .map((n) => n.proxyName),
      ['HK-02'],
    );
  });

  test('probe classification separates reachable, blocked, down and failed', () {
    expect(
      classifyProbeResponse(
        statusCode: 401,
        body: '',
        networkError: false,
      ),
      ServiceAccessReason.accessible,
    );
    expect(
      classifyProbeResponse(
        statusCode: 403,
        body: 'This service is not available in your country',
        networkError: false,
      ),
      ServiceAccessReason.regionBlocked,
    );
    expect(
      classifyProbeResponse(
        statusCode: 403,
        body: 'forbidden',
        networkError: false,
      ),
      ServiceAccessReason.unknown,
    );
    expect(
      classifyProbeResponse(
        statusCode: 503,
        body: '',
        networkError: false,
      ),
      ServiceAccessReason.serviceDown,
    );
    expect(
      classifyProbeResponse(
        statusCode: null,
        body: '',
        networkError: true,
      ),
      ServiceAccessReason.networkFailed,
    );
  });

  test('outage guard suppresses failover only after repeated service downs', () {
    final guard = ServiceOutageGuard();
    expect(guard.suspectedOutage, false);
    guard.recordFailure(ServiceAccessReason.serviceDown, 1000);
    guard.recordFailure(ServiceAccessReason.serviceDown, 2000);
    expect(guard.suspectedOutage, false);
    guard.recordFailure(ServiceAccessReason.regionBlocked, 3000);
    expect(guard.suspectedOutage, false);
    guard.recordFailure(ServiceAccessReason.serviceDown, 4000);
    expect(guard.suspectedOutage, true);
  });

  test('trust tiers and leak diagnostics', () {
    expect(ScoringEngine.trustTier(85), 'safe');
    expect(ScoringEngine.trustTier(60), 'watch');
    expect(ScoringEngine.trustTier(40), 'risky');
    expect(
      const DnsLeakResult(
        dnsEgressCountries: ['HK'],
        proxyCountry: 'HK',
      ).leaked,
      false,
    );
    expect(
      const DnsLeakResult(
        dnsEgressCountries: ['CN'],
        proxyCountry: 'HK',
      ).leaked,
      true,
    );
    expect(
      const WebRtcLeakResult(
        webrtcIps: ['9.9.9.9'],
        proxyEgressIp: '1.2.3.4',
      ).leaked,
      true,
    );
    expect(node('HK-01', 'HK').isIpv6, false);
  });

  test('probe configs split web and api chains', () {
    final openai = defaultServiceProbeConfigs.firstWhere(
      (config) => config.serviceId == 'openai',
    );
    expect(
      openai.endpoints.map((endpoint) => endpoint.chain),
      ['web', 'api'],
    );
    expect(
      openai.endpoints.map((endpoint) => endpoint.url),
      contains('https://api.openai.com/v1/models'),
    );
  });
}
