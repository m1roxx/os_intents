import 'dart:async';

import 'registry.dart';
import 'result.dart';

/// Invokes intents in a plain Dart test, with no device and no Siri.
///
/// ```dart
/// final harness = IntentHarness($osIntentsRegistry);
/// final result = await harness.invoke('addTask', {'title': 'Buy milk'});
/// expect(result, isA<DialogResult>());
/// ```
class IntentHarness {
  IntentHarness(this._registry);

  final IntentRegistry _registry;

  /// Ids the generator produced. Useful as a regression test in itself: assert
  /// on this list and a renamed handler fails CI instead of silently orphaning
  /// the shortcuts your users already built.
  List<String> get registeredIds => _registry.bindings.keys.toList()..sort();

  Future<IntentResult> invoke(String id, [Map<String, Object?> args = const {}]) {
    final binding = _registry[id];
    if (binding == null) {
      throw ArgumentError.value(
        id,
        'id',
        'not registered. Known ids: ${registeredIds.join(', ')}',
      );
    }
    return binding.invoke(args);
  }
}
