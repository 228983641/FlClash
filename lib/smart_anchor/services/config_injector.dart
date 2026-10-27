import '../models/service_toggle_config.dart';

class SmartConfigInjector {
  static Map<String, dynamic> injectSmartRouting({
    required Map<String, dynamic> rawConfig,
    required List<ServiceToggleConfig> serviceConfigs,
    required Map<String, List<String>> rankedProxiesByService,
  }) {
    final originalProxyGroups = List<dynamic>.from(
      rawConfig['proxy-groups'] as List? ?? [],
    );
    final originalRules = List<dynamic>.from(rawConfig['rules'] as List? ?? []);
    final dnsConfig = Map<String, dynamic>.from(rawConfig['dns'] as Map? ?? {});
    final nameserverPolicy = Map<String, dynamic>.from(
      dnsConfig['nameserver-policy'] as Map? ?? {},
    );
    final injectedTopRules = <String>[];
    final injectedGroups = <Map<String, dynamic>>[];
    for (final service in serviceConfigs) {
      if (!service.isEnabled) {
        continue;
      }
      final groupName = '🎯 Smart-${service.serviceId.toUpperCase()}';
      final ranked = rankedProxiesByService[service.serviceId];
      final sortedNodes = ranked == null || ranked.isEmpty
          ? const ['DIRECT']
          : ranked;
      injectedGroups.add({
        'name': groupName,
        'type': 'select',
        'proxies': sortedNodes,
      });
      for (final rulePattern in service.matchRules) {
        injectedTopRules.add('$rulePattern,$groupName');
      }
      if (service.dnsDomains.isNotEmpty) {
        final domainKey = service.dnsDomains.join(',');
        nameserverPolicy[domainKey] = 'https://1.1.1.1/dns-query#$groupName';
      }
    }
    final result = Map<String, dynamic>.from(rawConfig);
    result['proxy-groups'] = [...injectedGroups, ...originalProxyGroups];
    result['rules'] = [...injectedTopRules, ...originalRules];
    dnsConfig['nameserver-policy'] = nameserverPolicy;
    result['dns'] = dnsConfig;
    return result;
  }
}
