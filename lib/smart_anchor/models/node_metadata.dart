class NodeMetadataCache {
  const NodeMetadataCache({
    required this.proxyName,
    required this.entryServer,
    required this.egressIp,
    required this.countryCode,
    required this.latitude,
    required this.longitude,
    required this.asn,
    required this.ipType,
    required this.fraudScore,
    required this.purityScore,
    required this.wafPass,
    required this.updatedAt,
    this.ttlHours = 72,
    this.sourceCount = 1,
    this.countryDisputed = false,
  });

  final String proxyName;
  final String entryServer;
  final String egressIp;
  final String countryCode;
  final double latitude;
  final double longitude;
  final String asn;
  final String ipType;
  final double fraudScore;
  final double purityScore;
  final bool wafPass;
  final int updatedAt;
  final int ttlHours;
  final int sourceCount;
  final bool countryDisputed;

  bool get isIpv6 => egressIp.contains(':');

  bool get isExpired {
    final ageMs = DateTime.now().millisecondsSinceEpoch - updatedAt;
    return ageMs > ttlHours * 3600 * 1000;
  }

  bool sameSubnet24(String anchorSubnet24) {
    final parts = egressIp.split('.');
    if (parts.length != 4) return false;
    return parts.sublist(0, 3).join('.') == anchorSubnet24;
  }

  Map<String, dynamic> toJson() => {
    'proxyName': proxyName,
    'entryServer': entryServer,
    'egressIp': egressIp,
    'countryCode': countryCode,
    'latitude': latitude,
    'longitude': longitude,
    'asn': asn,
    'ipType': ipType,
    'fraudScore': fraudScore,
    'purityScore': purityScore,
    'wafPass': wafPass,
    'updatedAt': updatedAt,
    'ttlHours': ttlHours,
    'sourceCount': sourceCount,
    'countryDisputed': countryDisputed,
  };

  factory NodeMetadataCache.fromJson(Map<String, dynamic> json) {
    return NodeMetadataCache(
      proxyName: json['proxyName'] as String,
      entryServer: json['entryServer'] as String,
      egressIp: json['egressIp'] as String,
      countryCode: json['countryCode'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      asn: json['asn'] as String,
      ipType: json['ipType'] as String,
      fraudScore: (json['fraudScore'] as num).toDouble(),
      purityScore: (json['purityScore'] as num).toDouble(),
      wafPass: json['wafPass'] as bool,
      updatedAt: json['updatedAt'] as int,
      ttlHours: (json['ttlHours'] as num?)?.toInt() ?? 72,
      sourceCount: (json['sourceCount'] as num?)?.toInt() ?? 1,
      countryDisputed: json['countryDisputed'] as bool? ?? false,
    );
  }
}
