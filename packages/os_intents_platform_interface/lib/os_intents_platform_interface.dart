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
  Future<Map<String, Object?>?> debugInvokeBackground(
    String id,
    Map<String, Object?> args,
  ) async => null;

  @override
  Future<String?> debugStaticValue(String id) async => null;
}
