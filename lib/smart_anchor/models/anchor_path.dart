class AnchorPathPoint {
  const AnchorPathPoint({
    required this.serviceId,
    required this.proxyName,
    required this.latitude,
    required this.longitude,
    required this.countryCode,
    required this.city,
    required this.recordedAt,
    required this.note,
  });

  final String serviceId;
  final String proxyName;
  final double latitude;
  final double longitude;
  final String countryCode;
  final String city;
  final int recordedAt;
  final String note;

  String get placeLabel => city.isEmpty ? countryCode : city;

  Map<String, dynamic> toJson() {
    return {
      'serviceId': serviceId,
      'proxyName': proxyName,
      'latitude': latitude,
      'longitude': longitude,
      'countryCode': countryCode,
      'city': city,
      'recordedAt': recordedAt,
      'note': note,
    };
  }

  factory AnchorPathPoint.fromJson(Map<String, dynamic> json) {
    return AnchorPathPoint(
      serviceId: json['serviceId'] as String? ?? '',
      proxyName: json['proxyName'] as String? ?? '',
      latitude: (json['latitude'] as num?)?.toDouble() ?? 0,
      longitude: (json['longitude'] as num?)?.toDouble() ?? 0,
      countryCode: json['countryCode'] as String? ?? '',
      city: json['city'] as String? ?? '',
      recordedAt: (json['recordedAt'] as num?)?.toInt() ?? 0,
      note: json['note'] as String? ?? '',
    );
  }
}

List<AnchorPathPoint> appendPathPoint(
  List<AnchorPathPoint> points,
  AnchorPathPoint point, {
  int maxPoints = 30,
}) {
  if (points.isNotEmpty && points.last.proxyName == point.proxyName) {
    return points;
  }
  final next = [...points, point];
  if (next.length <= maxPoints) {
    return next;
  }
  return next.sublist(next.length - maxPoints);
}
