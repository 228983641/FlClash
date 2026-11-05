import 'package:drift/native.dart';
import 'package:fl_clash/database/database.dart' as db;
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_profiles.dart';

void main() {
  late db.Database testDatabase;

  setUp(() {
    testDatabase = db.Database(NativeDatabase.memory());
    db.database = testDatabase;
  });

  tearDown(() async {
    await testDatabase.close();
  });

  testWidgets('a custom setup disposed before its queries return resolves', (
    tester,
  ) async {
    const profile = Profile(
      id: 1,
      label: 'Home',
      type: ProfileType.custom,
      autoUpdateDuration: Duration.zero,
    );
    const subscription = Profile(
      id: 2,
      label: 'Sub',
      type: ProfileType.url,
      url: 'https://example.com/sub',
      autoUpdateDuration: Duration.zero,
    );
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(
          () => TestProfiles([profile, subscription]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );

    final state = await container.read(setupStateProvider(profile.id).future);

    expect(state.profileType, ProfileType.custom);
    expect(state.profileProviders, {'Sub': subscription.id});
  });

  testWidgets('a custom setup leaves the extension of its profile out', (
    tester,
  ) async {
    const profile = Profile(
      id: 1,
      type: ProfileType.custom,
      autoUpdateDuration: Duration.zero,
      extendType: ExtendType.script,
      scriptId: 5,
      matchTarget: 'Proxy',
    );
    await testDatabase.profilesDao.putAll([profile.toCompanion()]);
    await testDatabase.scripts.put(
      Script(
        id: 5,
        label: 'Script',
        lastUpdateTime: DateTime(2026),
      ).toCompanion(),
    );
    await testDatabase.rulesDao.putRule(
      Rule.parse('DOMAIN,global.com,DIRECT', id: 10),
    );
    await testDatabase.rulesDao.putRule(
      Rule.parse('DOMAIN,own.com,DIRECT', id: 11),
      profileId: profile.id,
    );
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );

    final state = await container.read(setupStateProvider(profile.id).future);

    expect(state.script, isNull);
    expect(state.matchTarget, isNull);
    expect(state.addedRules, isEmpty);
    expect(state.rules.map((rule) => rule.id), [11]);
  });

  testWidgets('a custom setup carries the dialers of its own profile', (
    tester,
  ) async {
    const profile = Profile(
      id: 1,
      label: 'Home',
      type: ProfileType.custom,
      autoUpdateDuration: Duration.zero,
    );
    const other = Profile(
      id: 2,
      type: ProfileType.custom,
      autoUpdateDuration: Duration.zero,
    );
    await testDatabase.profilesDao.putAll([
      profile.toCompanion(),
      other.toCompanion(),
    ]);
    await testDatabase.customProxies.put(
      const CustomProxy(id: 30, definition: {'name': 'Home'}).toCompanion(),
    );
    await testDatabase.proxyDialersDao.set(profile.id, 30, 'Relay');
    await testDatabase.proxyDialersDao.set(other.id, 30, 'Other');
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile, other])),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );

    final state = await container.read(setupStateProvider(profile.id).future);

    expect(state.proxyDialers, {30: 'Relay'});
  });

  testWidgets('a URL profile excludes its subscription host from fake-ip', (
    tester,
  ) async {
    const profile = Profile(
      id: 3,
      type: ProfileType.url,
      url: 'https://sub.example.test/path',
      autoUpdateDuration: Duration.zero,
    );
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles([profile])),
        patchClashConfigProvider.overrideWithBuild(
          (_, _) => const PatchClashConfig(
            dns: Dns(fakeIpFilter: ['existing.test']),
            dnsOverrideKeys: {DnsOverrideKey.fakeIpFilter},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );

    final state = await container.read(setupStateProvider(profile.id).future);

    expect(
      state.overrides.dns.fakeIpFilter,
      containsAll(['existing.test', 'sub.example.test']),
    );
    expect(
      state.overrides.dnsOverrideKeys,
      contains(DnsOverrideKey.fakeIpFilter),
    );
  });

  testWidgets('all URL profile hosts are excluded, including custom profiles', (
    tester,
  ) async {
    const profiles = [
      Profile(
        id: 4,
        type: ProfileType.custom,
        autoUpdateDuration: Duration.zero,
        overrides: ProfileOverrides(dns: Dns(fakeIpFilter: ['custom.test'])),
      ),
      Profile(
        id: 5,
        type: ProfileType.url,
        url: 'https://One.Example.test/sub',
        autoUpdateDuration: Duration.zero,
      ),
      Profile(
        id: 6,
        type: ProfileType.url,
        url: 'https://two.example.test/sub',
        autoUpdateDuration: Duration.zero,
      ),
    ];
    final container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(() => TestProfiles(profiles)),
        patchClashConfigProvider.overrideWithBuild(
          (_, _) => const PatchClashConfig(),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );

    final state = await container.read(setupStateProvider(4).future);

    expect(
      state.overrides.dns.fakeIpFilter,
      containsAll(['custom.test', 'one.example.test', 'two.example.test']),
    );
    expect(
      state.overrides.dnsOverrideKeys,
      contains(DnsOverrideKey.fakeIpFilter),
    );
  });
}
