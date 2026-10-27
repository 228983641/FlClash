class SwitchEvent {
  const SwitchEvent({
    required this.serviceId,
    required this.fromProxy,
    required this.toProxy,
    required this.reason,
    required this.switchedAt,
  });

  final String serviceId;
  final String fromProxy;
  final String toProxy;
  final String reason;
  final int switchedAt;

  Map<String, dynamic> toJson() {
    return {
      'serviceId': serviceId,
      'fromProxy': fromProxy,
      'toProxy': toProxy,
      'reason': reason,
      'switchedAt': switchedAt,
    };
  }

  factory SwitchEvent.fromJson(Map<String, dynamic> json) {
    return SwitchEvent(
      serviceId: json['serviceId'] as String? ?? '',
      fromProxy: json['fromProxy'] as String? ?? '',
      toProxy: json['toProxy'] as String? ?? '',
      reason: json['reason'] as String? ?? '',
      switchedAt: (json['switchedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

List<SwitchEvent> appendSwitchEvent(
  List<SwitchEvent> events,
  SwitchEvent event, {
  int maxEvents = 10,
}) {
  final next = [...events, event];
  if (next.length <= maxEvents) {
    return next;
  }
  return next.sublist(next.length - maxEvents);
}

bool isSwitchFrozen(List<SwitchEvent> events, int nowMs) {
  final windowStart = nowMs - 10 * 60 * 1000;
  return events.where((event) => event.switchedAt >= windowStart).length >= 3;
}
