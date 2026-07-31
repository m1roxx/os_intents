import 'package:flutter/services.dart';
import 'package:os_intents_platform_interface/os_intents_platform_interface.dart';

/// Android implementation, serving both invocation paths.
///
/// An app shortcut or an Assistant capability starts the launcher Activity, and
/// the plugin routes it to the UI isolate. A generated `@AppFunction` has no
/// Activity at all and goes through `OsIntentsBridge` into a headless engine.
/// The same channel and the same protocol carry both — they differ only in
/// which engine is on the other end.
class OsIntentsAndroid extends OsIntentsPlatform {
  static const MethodChannel _channel = MethodChannel('dev.osintents/background');

  /// Development hooks, served by the plugin on whichever engine it attached
  /// to — normally the UI one.
  static const MethodChannel _debug = MethodChannel('dev.osintents/debug');

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
  Future<void> ready({bool background = false}) async {
    // Announced from both isolates now. The headless engine has always needed
    // it; the UI isolate needs it since the app-shortcuts layer arrived, which
    // gave Android a foreground invocation path it did not have — a shortcut
    // tap can be a cold start, and the plugin holds the invocation until this
    // says there is something to hand it to.
    await _channel.invokeMethod<void>('ready');
  }

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
  ) async {
    final out = await _debug.invokeMethod<Map<Object?, Object?>>(
      'debugInvokeBackground',
      {'id': id, 'args': args},
    );
    return out?.cast<String, Object?>();
  }

  @override
  Future<String?> debugStaticValue(String id) async => null;
}
