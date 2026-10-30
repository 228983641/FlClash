import 'package:fl_clash/smart_anchor/services/cloudflare_trace.dart';
import 'package:fl_clash/smart_anchor/services/service_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cloudflare trace parses edge, warp and protocol', () {
    final info = parseCloudflareTrace('''
fl=1f
h=www.cloudflare.com
ip=1.2.3.4
ts=1700000000.000
visit_scheme=https
uag=Mozilla/5.0
colo=HKG
sliver=none
http=http/2
loc=HK
tls=TLSv1.3
sni=plaintext
warp=off
gateway=off
rbi=off
kex=X25519
''');
    expect(info?.colo, 'HKG');
    expect(info?.countryCode, 'HK');
    expect(info?.warpOn, isFalse);
    expect(info?.httpProtocol, 'http/2');
  });

  test('cloudflare trace without ip or colo is null', () {
    expect(parseCloudflareTrace('loc=HK\ncolo=HKG\n'), isNull);
    expect(parseCloudflareTrace('ip=1.2.3.4\n'), isNull);
  });

  test('statuspage indicator maps to service status', () {
    expect(
      parseStatuspageStatus({
        'status': {
          'indicator': 'none',
          'description': 'All Systems Operational',
        },
      }),
      OfficialServiceStatus.operational,
    );
    expect(
      parseStatuspageStatus({
        'status': {'indicator': 'minor'},
      }),
      OfficialServiceStatus.degraded,
    );
    expect(
      parseStatuspageStatus({
        'status': {'indicator': 'critical'},
      }),
      OfficialServiceStatus.outage,
    );
    expect(parseStatuspageStatus({}), OfficialServiceStatus.unknown);
  });
}
