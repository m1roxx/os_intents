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
  static const MethodChannel _channel = MethodChannel(
    'dev.osintents/background',
  );

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
  void setEntityHandler(EntityQueryHandler handler, {bool background = false}) {
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

  /// Stores what `Execution.static_` intents should answer with.
  ///
  /// Only the AppFunctions path can collect on this. A shortcut starts an
  /// Activity, so the engine is up either way and there is nothing to save —
  /// but a generated `@AppFunction` reads the store first and answers without
  /// bringing an isolate up at all.
  @override
  Future<void> publishStaticValues(Map<String, Object?> values) =>
      _channel.invokeMethod<void>('publishStatic', values);

  /// Android has nothing to donate to, and says so rather than pretending.
  ///
  /// iOS donation feeds Siri's suggestion model: the app reports what the user
  /// just did, and the system offers it back later. Android's nearest
  /// equivalent is a **dynamic shortcut** pushed through `ShortcutManager`,
  /// which is not the same thing — it is a launcher entry the app manages by
  /// hand, with a rank, an icon and a cap of a few per app, not a hint to a
  /// ranking model. Mapping one onto the other would mean deciding when to
  /// evict somebody else's shortcut, which is the app's call and not this
  /// package's.
  ///
  /// So this returns false, and `OsIntents.donate` documents that. Publishing
  /// dynamic shortcuts from Dart is the thing worth having, and it is here
  /// under its own name — [pushDynamicShortcut].
  @override
  Future<bool> donate(String id, Map<String, Object?> args) async => false;

  /// The Android half of "this just happened, offer it back".
  ///
  /// Goes through `ShortcutManager`, and the eviction policy is the platform's
  /// own rather than one invented here: on API 30+ `pushDynamicShortcut` drops
  /// the lowest-ranked entry when the app is at its cap, which is exactly what
  /// the API exists to do. Below that there is no such call, and a push that
  /// would exceed the cap answers false instead of guessing which of the app's
  /// own shortcuts to throw away.
  @override
  Future<bool> pushDynamicShortcut(Map<String, Object?> shortcut) async =>
      await _channel.invokeMethod<bool>('pushShortcut', shortcut) ?? false;

  @override
  Future<List<String>> dynamicShortcuts() async =>
      (await _channel.invokeListMethod<String>('shortcuts')) ?? const [];

  @override
  Future<void> removeDynamicShortcuts(List<String>? ids) =>
      _channel.invokeMethod<void>('removeShortcuts', {'ids': ids});

  @override
  Future<int> maxDynamicShortcuts() async =>
      await _channel.invokeMethod<int>('maxShortcuts') ?? 0;

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
  Future<String?> debugStaticValue(String id) =>
      _debug.invokeMethod<String>('debugStaticValue', {'id': id});
}
