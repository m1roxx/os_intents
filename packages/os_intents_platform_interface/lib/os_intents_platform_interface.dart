import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Called when the OS invokes an intent. Returns the wire form of an
/// `IntentResult`.
typedef IntentInvocationHandler =
    Future<Map<String, Object?>> Function(String id, Map<String, Object?> args);

/// Called when the OS resolves an entity — during disambiguation, when filling
/// a Shortcuts parameter, or when turning an identifier back into an object.
///
/// [method] is one of `entities.byIds`, `entities.matching`,
/// `entities.suggested`.
typedef EntityQueryHandler =
    Future<List<Map<String, Object?>>> Function(
      String method,
      Map<String, Object?> args,
    );

/// The contract every platform implementation fulfils.
abstract class OsIntentsPlatform extends PlatformInterface {
  OsIntentsPlatform() : super(token: _token);

  static final Object _token = Object();

  static OsIntentsPlatform _instance = _UnimplementedOsIntents();

  static OsIntentsPlatform get instance => _instance;

  static set instance(OsIntentsPlatform value) {
    PlatformInterface.verifyToken(value, _token);
    _instance = value;
  }

  /// Installs the callback the native side routes invocations to.
  ///
  /// [background] selects the isolate this binds to. The headless engine has
  /// its own binary messenger, so it needs its own channel — a channel created
  /// in one isolate is invisible to the other.
  void setInvocationHandler(
    IntentInvocationHandler handler, {
    bool background = false,
  });

  /// Installs the callback that answers entity queries.
  void setEntityHandler(EntityQueryHandler handler, {bool background = false});

  /// Signals that Dart handlers are registered.
  ///
  /// The native side buffers any invocation that arrives before this resolves —
  /// a cold launch triggered *by* an intent otherwise races app startup and
  /// drops the very invocation that started it.
  Future<void> ready({bool background = false});

  /// Publishes values the `Execution.static_` path reads without an engine.
  Future<void> publishStaticValues(Map<String, Object?> values);

  /// Tells the system this intent just happened, so it can offer it later.
  ///
  /// Returns whether the platform did anything. False is a real answer, not a
  /// failure: donation is an iOS 16+ concept and Android has no counterpart to
  /// route it to.
  Future<bool> donate(String id, Map<String, Object?> args);

  /// Publishes a launcher shortcut the app manages itself.
  ///
  /// Returns whether the platform did anything. False on iOS, and not as a
  /// stand-in for an error: there is nothing there to publish to. The iOS
  /// counterpart of the same intention is [donate], which is a different
  /// mechanism rather than the same one under another name — see
  /// `DynamicShortcut`.
  Future<bool> pushDynamicShortcut(Map<String, Object?> shortcut);

  /// Ids of the dynamic shortcuts currently published, in rank order.
  Future<List<String>> dynamicShortcuts();

  /// Removes dynamic shortcuts by id. Unknown ids are ignored.
  ///
  /// Passing null removes all of them.
  Future<void> removeDynamicShortcuts(List<String>? ids);

  /// How many dynamic shortcuts this launcher will hold, or 0 where there are
  /// none.
  ///
  /// Worth asking rather than assuming: the platform guarantees at least five
  /// and launchers commonly allow more, and what the app should do at the cap
  /// is the app's decision.
  Future<int> maxDynamicShortcuts();

  /// Forces an invocation through the headless engine, for development.
  ///
  /// Returns null on platforms with no background support.
  Future<Map<String, Object?>?> debugInvokeBackground(
    String id,
    Map<String, Object?> args,
  );

  /// Reads back what a generated `Execution.static_` intent would answer with.
  Future<String?> debugStaticValue(String id);
}

class _UnimplementedOsIntents extends OsIntentsPlatform {
  @override
  void setInvocationHandler(
    IntentInvocationHandler handler, {
    bool background = false,
  }) {}

  @override
  void setEntityHandler(
    EntityQueryHandler handler, {
    bool background = false,
  }) {}

  @override
  Future<void> ready({bool background = false}) async {}

  @override
  Future<void> publishStaticValues(Map<String, Object?> values) async {}

  @override
  Future<bool> donate(String id, Map<String, Object?> args) async => false;

  @override
  Future<bool> pushDynamicShortcut(Map<String, Object?> shortcut) async =>
      false;

  @override
  Future<List<String>> dynamicShortcuts() async => const [];

  @override
  Future<void> removeDynamicShortcuts(List<String>? ids) async {}

  @override
  Future<int> maxDynamicShortcuts() async => 0;

  @override
  Future<Map<String, Object?>?> debugInvokeBackground(
    String id,
    Map<String, Object?> args,
  ) async => null;

  @override
  Future<String?> debugStaticValue(String id) async => null;
}
