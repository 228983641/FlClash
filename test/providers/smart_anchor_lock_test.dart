import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/providers/smart_anchor.dart';
import 'package:fl_clash/smart_anchor/models/service_anchor.dart';
import 'package:fl_clash/smart_anchor/services/persistence.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late db.Database testDatabase;

  setUp(() {
    testDatabase = db.Database(NativeDatabase.memory());
    db.database = testDatabase;
  });

  tearDown(() => testDatabase.close());

  test('a lock change drops the anchor in the same state update', () async {
    final container = ProviderContainer(
      overrides: [smartAnchorProvider.overrideWith(SmartAnchor.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(smartAnchorProvider.notifier);
    await notifier.restore();
    notifier.setAnchor('claude', anchor);
    expect(container.read(smartAnchorProvider).anchors, contains('claude'));

    var emissions = 0;
    final subscription = container.listen(
      smartAnchorProvider,
      (_, _) => emissions++,
    );
    addTearDown(subscription.close);

    notifier.setLockCountries('claude', ['JP']);

    final state = container.read(smartAnchorProvider);
    expect(emissions, 1);
    expect(state.anchors, isNot(contains('claude')));
    expect(
      state.services
          .firstWhere((service) => service.serviceId == 'claude')
          .lockedCountries,
      ['JP'],
    );
    await _awaitPersistedLock();
  });

  test('the persisted snapshot keeps the anchor dropped', () async {
    final container = ProviderContainer(
      overrides: [smartAnchorProvider.overrideWith(SmartAnchor.new)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(smartAnchorProvider.notifier);
    await notifier.restore();
    notifier.setAnchor('claude', anchor);
    notifier.setLockCountries('claude', ['JP']);

    final snapshot = await _awaitPersistedLock();
    expect(snapshot, isNotNull);
    expect(snapshot!.anchors, isNot(contains('claude')));
  });
}

Future<SmartAnchorSnapshot?> _awaitPersistedLock() async {
  final store = SmartAnchorStore.drift();
  SmartAnchorSnapshot? snapshot;
  for (var attempt = 0; attempt < 100; attempt++) {
    snapshot = await store.load();
    final claude = snapshot?.services
        .where((service) => service.serviceId == 'claude')
        .firstOrNull;
    if (claude != null && claude.lockedCountries.contains('JP')) {
      break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return snapshot;
}
