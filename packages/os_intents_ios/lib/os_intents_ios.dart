import 'package:flutter/services.dart';
import 'package:os_intents_platform_interface/os_intents_platform_interface.dart';

/// iOS implementation, talking to the generated Swift `AppIntent` structs
/// through `OsIntentsBridge`.
class OsIntentsIos extends OsIntentsPlatform {
  /// The UI isolate's channel.
  static const MethodChannel _foreground = MethodChannel(
    'dev.osintents/bridge',
  );

  /// The headless engine's channel. Separate because the background engine has
  /// its own binary messenger — a channel made in one isolate cannot be seen
  /// from the other.
  static const MethodChannel _background = MethodChannel(
    'dev.osintents/background',
  );

  IntentInvocationHandler? _fgHandler;
  IntentInvocationHandler? _bgHandler;
  EntityQueryHandler? _fgEntities;
  EntityQueryHandler? _bgEntities;
  final Set<bool> _wired = {};

  /// Called by the Flutter tooling via `dartPluginClass`.
  static void registerWith() {
    OsIntentsPlatform.instance = OsIntentsIos();
  }

  MethodChannel _channel(bool background) =>
      background ? _background : _foreground;

  @override
  void setInvocationHandler(
    IntentInvocationHandler handler, {
    bool background = false,
  }) {
    if (background) {
      _bgHandler = handler;
    } else {
      _fgHandler = handler;
    }
    _wire(background);
  }

  @override
  void setEntityHandler(EntityQueryHandler handler, {bool background = false}) {
    if (background) {
      _bgEntities = handler;
    } else {
      _fgEntities = handler;
    }
    _wire(background);
  }

  /// One handler per channel, dispatching by method — installing a second would
  /// silently replace the first, and entity queries would stop being answered.
  void _wire(bool background) {
    if (!_wired.add(background)) return;

    _channel(background).setMethodCallHandler((call) async {
      final args = (call.arguments as Map? ?? const {}).cast<String, Object?>();

      if (call.method.startsWith('entities.')) {
        final h = background ? _bgEntities : _fgEntities;
        // No entities declared is normal; an empty list is the right answer.
        if (h == null) return const <Map<String, Object?>>[];
        return h(call.method, args);
      }

      if (call.method != 'invoke') return null;

      final h = background ? _bgHandler : _fgHandler;
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
      _channel(background).invokeMethod<void>('ready');

  @override
  Future<void> publishStaticValues(Map<String, Object?> values) =>
      _foreground.invokeMethod<void>('publishStatic', values);

  @override
  Future<Map<String, Object?>?> debugInvokeBackground(
    String id,
    Map<String, Object?> args,
  ) async {
    final out = await _foreground.invokeMethod<Map<Object?, Object?>>(
      'debugInvokeBackground',
      {'id': id, 'args': args},
    );
    return out?.cast<String, Object?>();
  }

  @override
  Future<String?> debugStaticValue(String id) =>
      _foreground.invokeMethod<String>('debugStaticValue', {'id': id});
}
