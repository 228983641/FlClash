import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts known rule types', () {
    expect(isValidMatchRule('GEOSITE,openai'), isTrue);
    expect(isValidMatchRule('DOMAIN-SUFFIX,example.com'), isTrue);
    expect(isValidMatchRule('IP-CIDR,1.2.3.0/24'), isTrue);
    expect(isValidMatchRule('FINAL,DIRECT'), isTrue);
  });

  test('matches type case-insensitively', () {
    expect(isValidMatchRule('geosite,openai'), isTrue);
  });

  test('rejects unknown types and malformed lines', () {
    expect(isValidMatchRule('FOO,bar'), isFalse);
    expect(isValidMatchRule('GEOSITE'), isFalse);
    expect(isValidMatchRule('GEOSITE,'), isFalse);
    expect(isValidMatchRule(',openai'), isFalse);
    expect(isValidMatchRule(''), isFalse);
  });
}
