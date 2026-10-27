class CloudflareEdgeInfo {
  const CloudflareEdgeInfo({
    required this.ip,
    required this.countryCode,
    required this.colo,
    required this.warpOn,
    required this.httpProtocol,
  });

  final String ip;
  final String countryCode;
  final String colo;
  final bool warpOn;
  final String httpProtocol;
}

CloudflareEdgeInfo? parseCloudflareTrace(String text) {
  final fields = <String, String>{};
  for (final line in text.split('\n')) {
    final separator = line.indexOf('=');
    if (separator <= 0) {
      continue;
    }
    fields[line.substring(0, separator).trim()] = line
        .substring(separator + 1)
        .trim();
  }
  final ip = fields['ip'];
  final colo = fields['colo'];
  if (ip == null || ip.isEmpty || colo == null || colo.isEmpty) {
    return null;
  }
  return CloudflareEdgeInfo(
    ip: ip,
    countryCode: fields['loc'] ?? '',
    colo: colo,
    warpOn: fields['warp'] == 'on',
    httpProtocol: fields['http'] ?? '',
  );
}
