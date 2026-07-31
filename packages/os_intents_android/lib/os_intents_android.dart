import 'package:flutter/services.dart';
import 'package:os_intents_platform_interface/os_intents_platform_interface.dart';

/// Android implementation, talking to the generated `@AppFunction` methods
/// through `OsIntentsBridge`.
///
/// Only the background channel exists. An `AppFunctionService` runs with no
/// Activity, so there is never a foreground engine to prefer — unlike iOS,
/// where an intent may arrive while the app is on screen.
class OsIntentsAndroid extends OsIntentsPlatform {
  static const MethodChannel _channel = MethodChannel('dev.osintents/background');

  IntentInvocationHandler? _handler;
  EntityQueryHandler? _entities;
  bool _wired = false;

  /// Called by the Flutter tooling via `dartPluginClass`.
  static void registerWith() {
    OsIntentsPlatform.instance = OsIntentsAndroid();
  }

  @override
  void setInvocationHandler(
    IntentInvocationHandler handler, {
    bool background = false,
  }) {
    _handler = handler;
    _wire();
  }

  @override
  void setEntityHandler(
    EntityQueryHandler handler, {
    bool background = false,
  }) {
    _entities = handler;
    _wire();
  }

  void _wire() {
    if (_wired) return;
    _wired = true;
    _channel.setMethodCallHandler((call) async {
      final args = (call.arguments as Map? ?? const {}).cast<String, Object?>();

      if (call.method.startsWith('entities.')) {
        final h = _entities;
        if (h == null) return const <Map<String, Object?>>[];
        return h(call.method, args);
      }

      if (call.method != 'invoke') return null;

      final h = _handler;
      if (h == null) {
        return {'kind': 'error', 'message': 'no handler installed'};
      }
      final id = args['id'] as String;
      final params = (args['args'] as Map? ?? const {}).cast<String, Object?>();
      return h(id, params);
    });
  }

  @override
  Future<void> ready({bool background = false}) =>
      _channel.invokeMethod<void>('ready');

  /// Not implemented on Android.
  ///
  /// `Execution.static_` exists to answer without starting an engine, which on
  /// iOS means reading a value the app stored. The Android side has no
  /// equivalent hook yet, so a static intent simply runs its handler headlessly
  /// — correct, just not free.
  @override
  Future<void> publishStaticValues(Map<String, Object?> values) async {}

  @override
  Future<Map<String, Object?>?> debugInvokeBackground(
    String id,
    Map<String, Object?> args,
  ) async => null;

  @override
  Future<String?> debugStaticValue(String id) async => null;
}
