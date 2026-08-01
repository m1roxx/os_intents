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

/// One generated entity type, wired to the user's `@EntityQuery` class.
///
/// Each callback returns entities already flattened to maps, because that is
/// what crosses the method channel — the generator emits the encoder.
@immutable
class EntityBinding {
  const EntityBinding({
    required this.typeName,
    required this.byIds,
    required this.matching,
    required this.suggested,
  });

  final String typeName;
  final Future<List<Map<String, Object?>>> Function(List<String> ids) byIds;
  final Future<List<Map<String, Object?>>> Function(String query) matching;
  final Future<List<Map<String, Object?>>> Function() suggested;
}

/// Lookup table produced by `os_intents_gen`.
///
/// You never build one by hand — `part 'intents.g.dart'` emits
/// `$osIntentsRegistry` and you pass it to [OsIntents.install].
@immutable
class IntentRegistry {
  const IntentRegistry(this.bindings, {this.entities = const {}});

  final Map<String, IntentBinding> bindings;
  final Map<String, EntityBinding> entities;

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
    OsIntentsPlatform.instance
      ..setInvocationHandler(me._dispatch)
      ..setEntityHandler(me._dispatchEntities);
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
    OsIntentsPlatform.instance
      ..setInvocationHandler(me._dispatch, background: true)
      ..setEntityHandler(me._dispatchEntities, background: true);
    await OsIntentsPlatform.instance.ready(background: true);
    return me;
  }

  /// Publishes answers that `Execution.static_` intents return without starting
  /// any Dart at all.
  ///
  /// Keys are intent ids. Call it whenever the underlying data changes — the
  /// app is the only thing that can, since the static path deliberately runs no
  /// code of yours:
  ///
  /// ```dart
  /// await OsIntents.publishStatic({
  ///   'dueToday': IntentResult.dialog('3 tasks due today'),
  /// });
  /// ```
  ///
  /// Whole results rather than plain strings, so an intent that shows a card
  /// can answer with one on this path too.
  ///
  /// An id with nothing published falls back to running the handler headlessly,
  /// so forgetting this costs speed, not correctness.
  static Future<void> publishStatic(Map<String, IntentResult> results) =>
      OsIntentsPlatform.instance.publishStaticValues({
        for (final e in results.entries) e.key: e.value.toWire(),
      });

  /// Tells the system an intent just happened, so it can offer it back later.
  ///
  /// Declaring an intent makes it *available*: a user who goes looking will
  /// find it in Shortcuts and Spotlight. Donating one makes it *suggested* —
  /// iOS learns that this action, with these values, follows this moment, and
  /// starts putting it in front of the user unasked. Call it from the same
  /// place that did the work:
  ///
  /// ```dart
  /// await TaskRepo.instance.create(title: title);
  /// await OsIntents.donate('addTask', {'title': title});
  /// ```
  ///
  /// [args] takes the values your handler would have received: a `DateTime` or
  /// an enum constant as itself, an entity as its identifier. Every one is
  /// optional, and donating with no values at all is meaningful — it says the
  /// action happened. Anything the system cannot fill in keeps whatever the
  /// intent's own default is.
  ///
  /// Returns whether the platform did anything, and **false on Android**,
  /// where there is nothing to donate to. That is not a gap waiting to be
  /// filled: Android's nearest equivalent is a dynamic shortcut, which is a
  /// launcher entry the app manages by hand rather than a hint to a ranking
  /// model. Guarding on the result is unnecessary — a donation that goes
  /// nowhere costs nothing.
  static Future<bool> donate(
    String id, [
    Map<String, Object?> args = const {},
  ]) => OsIntentsPlatform.instance.donate(id, {
    for (final e in args.entries) e.key: wireValue(e.value),
  });

  /// Reads back what a generated `Execution.static_` intent would answer with.
  ///
  /// For development: confirms [publishStatic] and the native read side agree,
  /// which is not otherwise observable from Dart.
  static Future<String?> debugStaticValue(String id) =>
      OsIntentsPlatform.instance.debugStaticValue(id);

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

  /// Answers the OS while it is resolving an entity the user referred to.
  ///
  /// Runs before the handler does — this is what makes "mark **Buy milk** as
  /// done" turn a spoken phrase into one of your objects.
  Future<List<Map<String, Object?>>> _dispatchEntities(
    String method,
    Map<String, Object?> args,
  ) async {
    final type = args['type'] as String?;
    final binding = type == null ? null : _registry.entities[type];
    if (binding == null) {
      debugPrint(
        'os_intents: no @EntityQuery registered for entity "$type". '
        'Re-run build_runner if you just added one.',
      );
      return const [];
    }
    try {
      return switch (method) {
        'entities.byIds' => await binding.byIds(
          (args['ids'] as List? ?? const []).cast<String>(),
        ),
        'entities.matching' => await binding.matching(
          args['query'] as String? ?? '',
        ),
        'entities.suggested' => await binding.suggested(),
        _ => const <Map<String, Object?>>[],
      };
    } catch (e, st) {
      // Returning empty beats throwing: the user sees "no matches" instead of
      // Shortcuts reporting that the app failed.
      debugPrint(
        'os_intents: entity query "$method" on "$type" threw: $e\n$st',
      );
      return const [];
    }
  }

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
