// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../smart_anchor.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(SmartAnchor)
final smartAnchorProvider = SmartAnchorProvider._();

final class SmartAnchorProvider
    extends $NotifierProvider<SmartAnchor, SmartAnchorInput> {
  SmartAnchorProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'smartAnchorProvider',
        isAutoDispose: false,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$smartAnchorHash();

  @$internal
  @override
  SmartAnchor create() => SmartAnchor();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(SmartAnchorInput value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<SmartAnchorInput>(value),
    );
  }
}

String _$smartAnchorHash() => r'c48e57bd7ce89193d0eed76cae17ee3c612cf2a8';

abstract class _$SmartAnchor extends $Notifier<SmartAnchorInput> {
  SmartAnchorInput build();
  @$mustCallSuper
  @override
  WhenComplete runBuild() {
    final ref = this.ref as $Ref<SmartAnchorInput, SmartAnchorInput>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<SmartAnchorInput, SmartAnchorInput>,
              SmartAnchorInput,
              Object?,
              Object?
            >;
    return element.handleCreate(ref, build);
  }
}
