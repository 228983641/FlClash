class CountryLock {
  static List<String> normalize(List<String> countries) {
    final seen = <String>{};
    final result = <String>[];
    for (final country in countries) {
      final code = country.trim().toUpperCase();
      if (code.isEmpty || seen.contains(code)) {
        continue;
      }
      seen.add(code);
      result.add(code);
    }
    return result;
  }

  static bool passes(String nodeCountry, List<String> lockedCountries) {
    if (lockedCountries.isEmpty) {
      return true;
    }
    return lockedCountries.contains(nodeCountry.toUpperCase());
  }

  static String description(List<String> lockedCountries) {
    final lock = normalize(lockedCountries);
    if (lock.isEmpty) {
      return '不限国家：不按国家过滤节点，排序只看纯净度和离锚点距离。'
          '登录地可能在不同国家之间跳变，账号风控风险最高；'
          '适合不在乎账号地区一致性的服务。改回锁国会清空旧锚点，'
          '下次以新锁国重新选锚点。';
    }
    if (lock.length == 1) {
      return '默认单国锁 ${lock.first}：只用该国节点，登录地固定在一个国家，'
          '账号风控风险最低；但该国无可用节点时只剩尾部应急池，'
          '可能出现无节点可用的情况。改锁国会清空旧锚点，'
          '下次以新锁国重新选锚点。';
    }
    return '多国锁 ${lock.join('、')}：只用这些国家的节点，'
        '登录地会在这几个国家之间变化，风控风险介于单国锁和不限国家之间；'
        '非默认选项，默认只能单国。改锁国会清空旧锚点，'
        '下次以新锁国重新选锚点。';
  }
}
