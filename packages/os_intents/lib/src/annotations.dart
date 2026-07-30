import 'package:meta/meta.dart';
import 'package:meta/meta_meta.dart';

/// Where the handler body runs when the system invokes the intent.
enum Execution {
  /// Bring the app to the foreground and run the handler on the main isolate.
  ///
  /// Always available. This is the fallback whenever [background] cannot be
  /// honoured on a given platform or device.
  foreground,

  /// Run the handler without showing UI.
  ///
  /// Android: a background `FlutterEngine` spawned from an `AppFunction`
  /// service. iOS: the App Intents extension process, which has a hard memory
  /// budget — if the engine cannot be brought up the plugin degrades to
  /// [foreground] and logs the reason.
  background,

  /// No Dart handler at all: the generated native code answers on its own from
  /// data the app previously wrote to the shared container.
  ///
  /// The only mode with no engine startup cost, and the only one that can never
  /// be evicted for memory. Use it for read-only actions ("what's my balance").
  static_,
}

/// Marks a top-level or static function as an OS-level action.
///
/// ```dart
/// @AppIntent(
///   title: 'Add task',
///   phrases: [r'Add a task to $app'],
///   execution: Execution.background,
/// )
/// Future<IntentResult> addTask({required String title}) async { ... }
/// ```
///
/// Every phrase must contain the `$app` placeholder — it expands to
/// `\(.applicationName)` in the generated Swift, which Apple requires. The
/// generator rejects phrases without it rather than letting App Review do it.
@immutable
@Target({TargetKind.function, TargetKind.method})
class AppIntent {
  const AppIntent({
    required this.title,
    this.description,
    this.phrases = const [],
    this.execution = Execution.foreground,
    this.systemImageName,
    this.identifier,
    this.showsInSpotlight = true,
  });

  /// Human-readable name, shown in Shortcuts and Spotlight.
  final String title;

  /// Longer explanation shown in the Shortcuts editor.
  final String? description;

  /// Spoken trigger phrases. Each must contain `$app`.
  final List<String> phrases;

  final Execution execution;

  /// SF Symbol name (iOS) used as the shortcut's glyph.
  final String? systemImageName;

  /// Stable id used on the wire. Defaults to the function name; set it
  /// explicitly before you ship, because renaming the function later would
  /// otherwise orphan shortcuts users have already built.
  final String? identifier;

  final bool showsInSpotlight;
}

/// Describes a single parameter of an [AppIntent] handler.
@immutable
@Target({TargetKind.parameter})
class Param {
  const Param({
    required this.title,
    this.description,
    this.requestValueDialog,
    this.defaultValue,
  });

  final String title;
  final String? description;

  /// Prompt spoken when the user triggered the intent without this value.
  /// Leaving it null makes the parameter effectively required up front.
  final String? requestValueDialog;

  final Object? defaultValue;
}
