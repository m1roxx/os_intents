import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:os_intents_platform_interface/os_intents_platform_interface.dart';

import 'result.dart';

/// A single generated handler binding.
@immutable
class IntentBinding {
  const IntentBinding({required this.id, required this.invoke});

  final String id;
  final Future<IntentResult> Function(Map<String, Object?> args) invoke;
}

/// Lookup table produced by `os_intents_gen`.
///
/// You never build one by hand — `part 'intents.g.dart'` emits
/// `$osIntentsRegistry` and you pass it to [OsIntents.install].
@immutable
class IntentRegistry {
  const IntentRegistry(this.bindings);

  final Map<String, IntentBinding> bindings;

  IntentBinding? operator [](String id) => bindings[id];
}

/// Entry point wired up once from `main()`.
class OsIntents {
  OsIntents._(this._registry);

  static OsIntents? _instance;
  final IntentRegistry _registry;

  static OsIntents get instance {
    final i = _instance;
    if (i == null) {
      throw StateError(
        'OsIntents.install() has not been called. Add it to main() before '
        'runApp(), passing the generated \$osIntentsRegistry.',
      );
    }
    return i;
  }

  /// Registers the generated handlers and starts listening for invocations.
  ///
  /// Call from `main()` before `runApp`.
  static Future<OsIntents> install(IntentRegistry registry) async {
    final me = _instance = OsIntents._(registry);
    OsIntentsPlatform.instance.setInvocationHandler(me._dispatch);
    await OsIntentsPlatform.instance.ready();
    return me;
  }

  /// Entry point of the headless isolate, called by generated code.
  ///
  /// You do not call this yourself: the generator emits
  /// `osIntentsBackgroundEntrypoint`, and the native side runs that when an
  /// `Execution.background` intent fires with no UI engine alive.
  ///
  /// This isolate is a different world from the UI one — separate memory,
  /// separate singletons, nothing shared. A handler that reads app state must
  /// read it from disk, not from a variable it set while the app was on screen.
  static Future<OsIntents> installBackground(IntentRegistry registry) async {
    // The binding is not set up for us here the way it is in main().
    WidgetsFlutterBinding.ensureInitialized();

    // Without this, plugins registered only on the Dart side (anything using
    // dartPluginClass) are missing, and their channels answer nothing.
    DartPluginRegistrant.ensureInitialized();

    final me = _instance = OsIntents._(registry);
    OsIntentsPlatform.instance.setInvocationHandler(
      me._dispatch,
      background: true,
    );
    await OsIntentsPlatform.instance.ready(background: true);
    return me;
  }

  /// Runs an intent through the headless engine even though the app is open.
  ///
  /// For verifying the background path during development: the normal router
  /// reuses the UI isolate whenever it is alive, so nothing else exercises this
  /// short of getting Siri to background-launch the app. Not for production use
  /// — a real handler invoked this way sees the background isolate's empty
  /// world, not the state on screen.
  static Future<Map<String, Object?>?> debugInvokeBackground(
    String id, [
    Map<String, Object?> args = const {},
  ]) => OsIntentsPlatform.instance.debugInvokeBackground(id, args);

  Future<Map<String, Object?>> _dispatch(
    String id,
    Map<String, Object?> args,
  ) async {
    final binding = _registry[id];
    if (binding == null) {
      // The native side holds a compile-time list of intents; a miss here means
      // the generated Swift/Kotlin is newer than the Dart half.
      return {
        'kind': 'error',
        'message':
            'No handler registered for intent "$id". Re-run build_runner so '
            'the Dart registry matches the generated native code.',
      };
    }
    try {
      final result = await binding.invoke(args);
      return result.toWire();
    } catch (e, st) {
      debugPrint('os_intents: handler "$id" threw: $e\n$st');
      return {'kind': 'error', 'message': '$e'};
    }
  }
}
