import '../models/node_metadata.dart';
import 'scoring_engine.dart';

class GeoIpRateLimited implements Exception {
  const GeoIpRateLimited(this.sourceId);

  final String sourceId;
}

class GeoIpResult {
  const GeoIpResult({
    required this.ip,
    required this.countryCode,
    required this.latitude,
    required this.longitude,
    required this.asn,
    required this.ipType,
    this.fraudScore = 0,
    this.isAbuse = false,
    this.sourceCount = 1,
    this.countryDisputed = false,
    this.city,
    this.adminRegion,
    this.geoConfidence,
    this.asnConfidence,
  });

  final String ip;
  final String countryCode;
  final double latitude;
  final double longitude;
  final String asn;
  final String ipType;
  final double fraudScore;
  final bool isAbuse;
  final int sourceCount;
  final bool countryDisputed;
  final String? city;
  final String? adminRegion;
  final double? geoConfidence;
  final double? asnConfidence;

  NodeMetadataCache toNodeMetadata({
    required String proxyName,
    required String entryServer,
    required bool wafPass,
    required int updatedAt,
  }) {
    return NodeMetadataCache(
      proxyName: proxyName,
      entryServer: entryServer,
      egressIp: ip,
      countryCode: countryCode,
      latitude: latitude,
      longitude: longitude,
      asn: asn,
      ipType: ipType,
      fraudScore: fraudScore,
      purityScore: ScoringEngine.purityScore(
        ipType: ipType,
        fraudScore: fraudScore,
        isAbuse: isAbuse,
      ),
      wafPass: wafPass,
      updatedAt: updatedAt,
      sourceCount: sourceCount,
      countryDisputed: countryDisputed,
      adminRegion: adminRegion,
      city: city,
      geoConfidence: geoConfidence,
      asnConfidence: asnConfidence,
    );
  }
}

String? _geoText(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Geo confidence from country corroboration alone, on a documented
/// ladder: one uncorroborated source earns 0.4; two or more sources in
/// unanimous agreement earn 0.9; disputed results earn 0.85 when the
/// consensus still holds at least three quarters of the votes and 0.55
/// otherwise. Only the top two rungs clear the 0.8 the city tier asks
/// for, so a contested or thin country conclusion degrades a node to
/// the country tiers instead of placing it by city.
double geoConfidenceFor({
  required int agreeing,
  required int total,
  required bool disputed,
}) {
  if (total <= 1) {
    return 0.4;
  }
  if (!disputed) {
    return 0.9;
  }
  return agreeing / total >= 0.75 ? 0.85 : 0.55;
}

/// ASN confidence from the consensus-country sources that report an
/// ASN: no report earns 0, a single report 0.5, a unanimous report 0.9,
/// and a split report scales between 0.4 and 0.8 by the winner's share.
double asnConfidenceFor({required int agreeing, required int reporting}) {
  if (reporting == 0 || agreeing == 0) {
    return 0;
  }
  if (reporting == 1) {
    return 0.5;
  }
  if (agreeing == reporting) {
    return 0.9;
  }
  return 0.4 + 0.4 * agreeing / reporting;
}

GeoIpResult? aggregateGeoResults(List<GeoIpResult> results) {
  if (results.isEmpty) {
    return null;
  }
  final countryVotes = <String, int>{};
  for (final result in results) {
    countryVotes[result.countryCode] =
        (countryVotes[result.countryCode] ?? 0) + 1;
  }
  var consensus = results.first.countryCode;
  var bestVotes = 0;
  for (final result in results) {
    final votes = countryVotes[result.countryCode]!;
    if (votes > bestVotes) {
      bestVotes = votes;
      consensus = result.countryCode;
    }
  }
  final agreeing = results
      .where((result) => result.countryCode == consensus)
      .toList();
  final asnVotes = <String, int>{};
  for (final result in agreeing) {
    if (result.asn.isEmpty) {
      continue;
    }
    asnVotes[result.asn] = (asnVotes[result.asn] ?? 0) + 1;
  }
  var asn = '';
  var asnVotesBest = 0;
  for (final result in agreeing) {
    final votes = asnVotes[result.asn] ?? 0;
    if (votes > asnVotesBest) {
      asnVotesBest = votes;
      asn = result.asn;
    }
  }
  final cityVotes = <String, int>{};
  final regionVotes = <String, int>{};
  for (final result in agreeing) {
    final city = _geoText(result.city);
    if (city != null) {
      cityVotes[city] = (cityVotes[city] ?? 0) + 1;
    }
    final region = _geoText(result.adminRegion);
    if (region != null) {
      regionVotes[region] = (regionVotes[region] ?? 0) + 1;
    }
  }
  String? winCity;
  String? winRegion;
  var winCityVotes = -1;
  var winRegionVotes = -1;
  for (final result in agreeing) {
    final city = _geoText(result.city);
    final region = _geoText(result.adminRegion);
    if (city == null && region == null) {
      continue;
    }
    final cityScore = city == null ? 0 : cityVotes[city]!;
    final regionScore = region == null ? 0 : regionVotes[region]!;
    if (cityScore > winCityVotes ||
        (cityScore == winCityVotes && regionScore > winRegionVotes)) {
      winCityVotes = cityScore;
      winRegionVotes = regionScore;
      winCity = city;
      winRegion = region;
    }
  }
  final asnReporting = agreeing.where((result) => result.asn.isNotEmpty).length;
  const typePenalty = {
    'hosting': 30,
    'datacenter': 30,
    'business': 10,
    'mobile': 0,
    'residential': 0,
    'isp': 0,
  };
  var worstType = results.first.ipType;
  var worstPenalty = typePenalty[worstType] ?? 30;
  for (final result in results) {
    final penalty = typePenalty[result.ipType] ?? 30;
    if (penalty > worstPenalty) {
      worstPenalty = penalty;
      worstType = result.ipType;
    }
  }
  return GeoIpResult(
    ip: results.first.ip,
    countryCode: consensus,
    latitude:
        agreeing.map((result) => result.latitude).reduce((a, b) => a + b) /
        agreeing.length,
    longitude:
        agreeing.map((result) => result.longitude).reduce((a, b) => a + b) /
        agreeing.length,
    asn: asn,
    ipType: worstType,
    fraudScore: results
        .map((result) => result.fraudScore)
        .reduce((a, b) => a > b ? a : b),
    isAbuse: results.any((result) => result.isAbuse),
    sourceCount: results.length,
    countryDisputed: countryVotes.length > 1,
    city: winCity,
    adminRegion: winRegion,
    geoConfidence: geoConfidenceFor(
      agreeing: agreeing.length,
      total: results.length,
      disputed: countryVotes.length > 1,
    ),
    asnConfidence: asnConfidenceFor(
      agreeing: asnVotesBest,
      reporting: asnReporting,
    ),
  );
}

class ApiKeyPool {
  ApiKeyPool(this.keys, {this.cooldownMs = 24 * 3600 * 1000});

  final List<String> keys;
  final int cooldownMs;
  final Map<String, int> _cooledUntil = {};
  int _cursor = 0;

  List<String> availableKeys(int nowMs) {
    return [
      for (final key in keys)
        if ((_cooledUntil[key] ?? 0) <= nowMs) key,
    ];
  }

  String? nextKey(int nowMs) {
    final available = availableKeys(nowMs);
    if (available.isEmpty) {
      return null;
    }
    final key = available[_cursor % available.length];
    _cursor++;
    return key;
  }

  void markRateLimited(String key, int nowMs) {
    _cooledUntil[key] = nowMs + cooldownMs;
  }

  bool isCooled(String key, int nowMs) {
    return (_cooledUntil[key] ?? 0) > nowMs;
  }
}

class GeoIpCache {
  final Map<String, NodeMetadataCache> _entries = {};

  NodeMetadataCache? lookup(String ip) {
    final entry = _entries[ip];
    if (entry == null || entry.isExpired) {
      return null;
    }
    return entry;
  }

  void put(NodeMetadataCache entry) {
    _entries[entry.egressIp] = entry;
  }

  int get length => _entries.length;
}

typedef GeoIpFetcher =
    Future<Map<String, dynamic>?> Function(
      String ip,
      String? apiKey,
      String sourceId,
    );

GeoIpResult? parseIpApi(Map<String, dynamic> json) {
  if (json['status'] != 'success' ||
      json['countryCode'] is! String ||
      (json['countryCode'] as String).isEmpty) {
    return null;
  }
  final asField = json['as'];
  final asn = asField is String && asField.startsWith('AS')
      ? asField.split(' ').first
      : '';
  final ipType = json['mobile'] == true
      ? 'mobile'
      : json['hosting'] == true
      ? 'hosting'
      : 'isp';
  return GeoIpResult(
    ip: json['query'] as String? ?? '',
    countryCode: json['countryCode'] as String? ?? '',
    latitude: (json['lat'] as num?)?.toDouble() ?? 0,
    longitude: (json['lon'] as num?)?.toDouble() ?? 0,
    asn: asn,
    ipType: ipType,
    isAbuse: json['proxy'] == true,
    city: _geoText(json['city']),
    adminRegion: _geoText(json['regionName']),
  );
}

GeoIpResult? parseIpInfo(Map<String, dynamic> json) {
  final loc = json['loc'];
  if (loc is! String ||
      !loc.contains(',') ||
      json['country'] is! String ||
      (json['country'] as String).isEmpty) {
    return null;
  }
  final parts = loc.split(',');
  final org = json['org'];
  final asn = org is String && org.startsWith('AS') ? org.split(' ').first : '';
  return GeoIpResult(
    ip: json['ip'] as String? ?? '',
    countryCode: json['country'] as String? ?? '',
    latitude: double.tryParse(parts[0]) ?? 0,
    longitude: double.tryParse(parts[1]) ?? 0,
    asn: asn,
    ipType: 'isp',
    city: _geoText(json['city']),
    adminRegion: _geoText(json['region']),
  );
}

GeoIpResult? parseIpWhoIs(Map<String, dynamic> json) {
  if (json['success'] != true ||
      json['country_code'] is! String ||
      (json['country_code'] as String).isEmpty) {
    return null;
  }
  final connection = json['connection'];
  final asnValue = connection is Map ? connection['asn'] : null;
  return GeoIpResult(
    ip: json['ip'] as String? ?? '',
    countryCode: json['country_code'] as String? ?? '',
    latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
    longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
    asn: asnValue is num ? 'AS${asnValue.toInt()}' : '',
    ipType: 'isp',
    city: _geoText(json['city']),
    adminRegion: _geoText(json['region']),
  );
}

GeoIpResult? parseFreeIpApi(Map<String, dynamic> json) {
  if (json['countryCode'] is! String ||
      (json['countryCode'] as String).isEmpty) {
    return null;
  }
  final asnValue = json['asn'];
  final asn = asnValue is String && asnValue.isNotEmpty
      ? (asnValue.startsWith('AS') ? asnValue : 'AS$asnValue')
      : '';
  return GeoIpResult(
    ip: json['ipAddress'] as String? ?? '',
    countryCode: json['countryCode'] as String? ?? '',
    latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
    longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
    asn: asn,
    ipType: 'isp',
    isAbuse: json['isProxy'] == true,
    city: _geoText(json['cityName']),
    adminRegion: _geoText(json['regionName']),
  );
}

GeoIpResult? parseIpApiCo(Map<String, dynamic> json) {
  if (json['country_code'] is! String ||
      (json['country_code'] as String).isEmpty) {
    return null;
  }
  final asnValue = json['asn'];
  final asn = asnValue is String && asnValue.isNotEmpty
      ? (asnValue.startsWith('AS') ? asnValue : 'AS$asnValue')
      : '';
  return GeoIpResult(
    ip: json['ip'] as String? ?? '',
    countryCode: json['country_code'] as String? ?? '',
    latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
    longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
    asn: asn,
    ipType: 'isp',
    city: _geoText(json['city']),
    adminRegion: _geoText(json['region']),
  );
}

GeoIpResult? parseGeoJs(Map<String, dynamic> json) {
  if (json['country_code'] is! String ||
      (json['country_code'] as String).isEmpty) {
    return null;
  }
  final asnValue = json['asn'];
  return GeoIpResult(
    ip: json['ip'] as String? ?? '',
    countryCode: json['country_code'] as String? ?? '',
    latitude: double.tryParse(json['latitude']?.toString() ?? '') ?? 0,
    longitude: double.tryParse(json['longitude']?.toString() ?? '') ?? 0,
    asn: asnValue is num ? 'AS${asnValue.toInt()}' : '',
    ipType: 'isp',
    city: _geoText(json['city']),
    adminRegion: _geoText(json['region']),
  );
}

GeoIpResult? parseIpSb(Map<String, dynamic> json) {
  if (json['country_code'] is! String ||
      (json['country_code'] as String).isEmpty ||
      json['ip'] is! String ||
      (json['ip'] as String).isEmpty) {
    return null;
  }
  final asnValue = json['asn'];
  return GeoIpResult(
    ip: json['ip'] as String? ?? '',
    countryCode: json['country_code'] as String? ?? '',
    latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
    longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
    asn: asnValue is num ? 'AS${asnValue.toInt()}' : '',
    ipType: 'isp',
    city: _geoText(json['city']),
    adminRegion: _geoText(json['region']),
  );
}

class GeoIpService {
  GeoIpService({
    required this.cache,
    required this.fetcher,
    required this.keyPools,
    this.sourceOrder = const [
      'ip-api',
      'ipinfo',
      'ip.sb',
      'ipwho.is',
      'freeipapi',
      'geojs',
      'ipapi.co',
    ],
    this.sourcesPerLookup = 3,
  });

  final GeoIpCache cache;
  final GeoIpFetcher fetcher;
  final Map<String, ApiKeyPool> keyPools;
  final List<String> sourceOrder;
  final int sourcesPerLookup;
  var _lookupCount = 0;

  Future<NodeMetadataCache?> lookup({
    required String ip,
    required String proxyName,
    required String entryServer,
    required bool wafPass,
    required int nowMs,
  }) async {
    final cached = cache.lookup(ip);
    if (cached != null) {
      return cached;
    }
    final perLookup = sourceOrder.isEmpty
        ? 0
        : sourcesPerLookup.clamp(1, sourceOrder.length);
    final start = sourceOrder.isEmpty ? 0 : _lookupCount % sourceOrder.length;
    _lookupCount++;
    final selected = [
      for (var i = 0; i < perLookup; i++)
        sourceOrder[(start + i) % sourceOrder.length],
    ];
    final results = <GeoIpResult>[];
    for (final sourceId in selected) {
      final result = await _querySource(sourceId, ip, nowMs);
      if (result != null) {
        results.add(result);
      }
    }
    final aggregated = aggregateGeoResults(results);
    if (aggregated == null) {
      return null;
    }
    final entry = aggregated.toNodeMetadata(
      proxyName: proxyName,
      entryServer: entryServer,
      wafPass: wafPass,
      updatedAt: nowMs,
    );
    cache.put(entry);
    return entry;
  }

  Future<GeoIpResult?> _querySource(
    String sourceId,
    String ip,
    int nowMs,
  ) async {
    final pool = keyPools[sourceId];
    final attempts = pool == null ? 1 : pool.keys.length;
    for (var i = 0; i < attempts; i++) {
      final key = pool?.nextKey(nowMs);
      if (pool != null && key == null) {
        return null;
      }
      try {
        final json = await fetcher(ip, key, sourceId);
        if (json == null) {
          return null;
        }
        final parsed = switch (sourceId) {
          'ip-api' => parseIpApi(json),
          'ipinfo' => parseIpInfo(json),
          'ip.sb' => parseIpSb(json),
          'ipwho.is' => parseIpWhoIs(json),
          'freeipapi' => parseFreeIpApi(json),
          'geojs' => parseGeoJs(json),
          'ipapi.co' => parseIpApiCo(json),
          _ => null,
        };
        if (parsed != null) {
          return parsed;
        }
        return null;
      } on GeoIpRateLimited {
        if (key != null) {
          pool?.markRateLimited(key, nowMs);
        }
      } catch (_) {
        return null;
      }
    }
    return null;
  }
}
