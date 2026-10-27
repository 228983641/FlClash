import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/smart_anchor.g.dart';

@Riverpod(keepAlive: true)
class SmartAnchor extends _$SmartAnchor {
  @override
  SmartAnchorInput build() {
    return const SmartAnchorInput();
  }

  void update(SmartAnchorInput next) {
    state = next;
  }
}
