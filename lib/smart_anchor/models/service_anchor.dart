class ServiceAnchor {
  const ServiceAnchor({
    required this.serviceTag,
    required this.countryCode,
    required this.lastProxyName,
    required this.egressIp,
    required this.subnet24,
    required this.asn,
    required this.isp,
    required this.latitude,
    required this.longitude,
    required this.city,
    required this.confirmedAt,
  });

  final String serviceTag;
  final String countryCode;
  final String lastProxyName;
  final String egressIp;
  final String subnet24;
  final String asn;
  final String isp;
  final double latitude;
  final double longitude;
  final String city;
  final int confirmedAt;

  Map<String, dynamic> toJson() => {
        'serviceTag': serviceTag,
        'countryCode': countryCode,
        'lastProxyName': lastProxyName,
        'egressIp': egressIp,
        'subnet24': subnet24,
        'asn': asn,
        'isp': isp,
        'latitude': latitude,
        'longitude': longitude,
        'city': city,
        'confirmedAt': confirmedAt,
      };

  factory ServiceAnchor.fromJson(Map<String, dynamic> json) {
    return ServiceAnchor(
      serviceTag: json['serviceTag'] as String,
      countryCode: json['countryCode'] as String,
      lastProxyName: json['lastProxyName'] as String,
      egressIp: json['egressIp'] as String,
      subnet24: json['subnet24'] as String,
      asn: json['asn'] as String,
      isp: json['isp'] as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      city: json['city'] as String,
      confirmedAt: json['confirmedAt'] as int,
    );
  }

  ServiceAnchor copyWith({
    String? lastProxyName,
    String? egressIp,
    String? subnet24,
    String? asn,
    String? isp,
    double? latitude,
    double? longitude,
    String? city,
    int? confirmedAt,
  }) {
    return ServiceAnchor(
      serviceTag: serviceTag,
      countryCode: countryCode,
      lastProxyName: lastProxyName ?? this.lastProxyName,
      egressIp: egressIp ?? this.egressIp,
      subnet24: subnet24 ?? this.subnet24,
      asn: asn ?? this.asn,
      isp: isp ?? this.isp,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      city: city ?? this.city,
      confirmedAt: confirmedAt ?? this.confirmedAt,
    );
  }
}
