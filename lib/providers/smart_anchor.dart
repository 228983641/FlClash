import 'dart:async';

import 'package:fl_clash/smart_anchor/services/persistence.dart';
import 'package:fl_clash/smart_anchor/services/profile_wiring.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'generated/smart_anchor.g.dart';

@Riverpod(keepAlive: true)
class SmartAnchor extends _$SmartAnchor {
  SmartAnchorStore get _store => SmartAnchorStore.drift();

  @override
  SmartAnchorInput build() {
    return const SmartAnchorInput();
  }

  void update(SmartAnchorInput next) {
    state = next;
    unawaited(_store.save(next));
  }

  Future<void> restore() async {
    final snapshot = await _store.load();
    if (snapshot == null) {
      return;
    }
    state = state.copyWith(
      services: snapshot.services.isEmpty ? null : snapshot.services,
      anchors: snapshot.anchors,
      metadataByProxy: snapshot.metadataByProxy,
      accessByService: snapshot.accessByService,
    );
  }

  void clearAnchor(String serviceId) {
    final anchors = Map.of(state.anchors)..remove(serviceId);
    state = state.copyWith(anchors: anchors);
    unawaited(_store.deleteAnchor(serviceId));
  }
}
