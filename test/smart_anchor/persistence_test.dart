import 'package:fl_clash/smart_anchor/models/node_metadata.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_toggle_config.dart';
import 'package:fl_clash/smart_anchor/services/persistence.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:fl_clash/smart_anchor/services/service_access.dart';
import 'package:flutter_test/flutter_test.dart';

const anchor = ServiceAnchor(
  serviceTag: 'claude',
  countryCode: 'US',
  lastProxyName: 'US-01',
  egressIp: '1.2.3.4',
  subnet24: '1.2.3',
  asn: 'AS20057',
  isp: 'Example',
  latitude: 34.0522,
  longitude: -118.2437,
  city: 'Los Angeles',
  confirmedAt: 0,
);

NodeMetadataCache node(String name, int updatedAt) {
  return NodeMetadataCache(
    proxyName: name,
    entryServer: 'entry.example',
    egressIp: '1.2.3.4',
    countryCode: 'US',
    latitude: 34.0522,
    longitude: -118.2437,
    asn: 'AS20057',
    ipType: 'residential',
    fraudScore: 0,
    purityScore: 90,
    wafPass: true,
    updatedAt: updatedAt,
  );
}

void main() {
  test('save and load round-trips anchors, nodes and access', () async {
    final store = SmartAnchorStore(InMemorySmartAnchorRecordStore());
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.save(
      SmartAnchorInput(
        services: [
          const ServiceToggleConfig(
            serviceId: 'claude',
            displayName: 'Claude',
            isEnabled: true,
            targetCountry: 'US',
            matchRules: ['DOMAIN-SUFFIX,claude.ai'],
            dnsDomains: ['claude.ai'],
          ),
        ],
        anchors: {'claude': anchor},
        metadataByProxy: {'US-01': node('US-01', now)},
        accessByService: {
          'claude': {
            'US-01': ServiceAccessResult(
              serviceId: 'claude',
              proxyName: 'US-01',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.accessible,
              checkedAt: now,
            ),
          },
        },
      ),
    );
    final snapshot = await store.load();
    expect(snapshot, isNotNull);
    expect(snapshot!.anchors['claude']?.lastProxyName, 'US-01');
    expect(snapshot.metadataByProxy['US-01']?.purityScore, 90);
    expect(
      snapshot.accessByService['claude']?['US-01']?.reason,
      ServiceAccessReason.accessible,
    );
    expect(snapshot.services.first.serviceId, 'claude');
  });

  test('expired nodes and access results are dropped on load', () async {
    final store = SmartAnchorStore(InMemorySmartAnchorRecordStore());
    final old =
        DateTime.now().millisecondsSinceEpoch -
        const Duration(hours: 100).inMilliseconds;
    await store.save(
      SmartAnchorInput(
        metadataByProxy: {'OLD-01': node('OLD-01', old)},
        accessByService: {
          'claude': {
            'OLD-01': ServiceAccessResult(
              serviceId: 'claude',
              proxyName: 'OLD-01',
              egressIp: '1.2.3.4',
              reason: ServiceAccessReason.accessible,
              checkedAt: old,
            ),
          },
        },
      ),
    );
    final snapshot = await store.load();
    expect(snapshot, isNotNull);
    expect(snapshot!.metadataByProxy, isEmpty);
    expect(snapshot.accessByService, isEmpty);
  });

  test('saving a smaller input removes stale keys', () async {
    final store = SmartAnchorStore(InMemorySmartAnchorRecordStore());
    final now = DateTime.now().millisecondsSinceEpoch;
    await store.save(
      SmartAnchorInput(
        anchors: {'claude': anchor},
        metadataByProxy: {'US-01': node('US-01', now)},
      ),
    );
    await store.save(const SmartAnchorInput());
    final snapshot = await store.load();
    expect(snapshot, isNotNull);
    expect(snapshot!.anchors, isEmpty);
    expect(snapshot.metadataByProxy, isEmpty);
  });

  test('deleteAnchor removes only that service anchor', () async {
    final store = SmartAnchorStore(InMemorySmartAnchorRecordStore());
    await store.save(const SmartAnchorInput(anchors: {'claude': anchor}));
    await store.deleteAnchor('claude');
    final snapshot = await store.load();
    expect(snapshot, isNotNull);
    expect(snapshot!.anchors, isEmpty);
  });
}
