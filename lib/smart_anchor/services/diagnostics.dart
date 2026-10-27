class DnsLeakResult {
  const DnsLeakResult({
    required this.dnsEgressCountries,
    required this.proxyCountry,
  });

  final List<String> dnsEgressCountries;
  final String proxyCountry;

  bool get leaked {
    if (dnsEgressCountries.isEmpty) {
      return false;
    }
    return dnsEgressCountries.any(
      (country) => country.toUpperCase() != proxyCountry.toUpperCase(),
    );
  }
}

class WebRtcLeakResult {
  const WebRtcLeakResult({
    required this.webrtcIps,
    required this.proxyEgressIp,
  });

  final List<String> webrtcIps;
  final String proxyEgressIp;

  bool get leaked {
    return webrtcIps.any((ip) => ip != proxyEgressIp);
  }
}
