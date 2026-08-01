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
    this.showsSnippet = false,
    this.confirmBeforeRunning,
    this.returns,
    this.androidShortcut = true,
    this.androidCapability,
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

  /// Whether this intent can answer with an [IntentResult.snippet] card.
  ///
  /// Opt-in because Swift fixes `perform()`'s return type at compile time,
  /// while the decision to return a card is made at run time. Declaring it
  /// always would attach an empty card to every plain answer.
  ///
  /// With this false, an `IntentResult.snippet` still speaks its `spoken` text
  /// — the card is simply not shown.
  final bool showsSnippet;

  /// Ask the user before running anything, showing this as the prompt.
  ///
  /// For the actions where getting it wrong is expensive — sending, paying,
  /// deleting. The system asks; your handler is not called at all unless the
  /// user agrees, and a refusal is not an error.
  ///
  /// ```dart
  /// @AppIntent(
  ///   title: 'Delete all completed',
  ///   confirmBeforeRunning: 'Delete every completed task?',
  /// )
  /// ```
  ///
  /// A compile-time property of the action, not something a handler decides.
  /// That is the whole reason the earlier `IntentResult.needsConfirmation`
  /// could not work: by the time a handler returns anything it has already
  /// run, so "ask first" cannot be expressed as a return value.
  ///
  /// The prompt itself needs iOS 18. On 16 and 17 the system still asks, in its
  /// own words — the generated Swift picks the richer call where it exists, so
  /// the guarantee holds on every version this package supports.
  final String? confirmBeforeRunning;

  /// The type this action hands back, so a Shortcut can use it as input to its
  /// next step.
  ///
  /// ```dart
  /// @AppIntent(title: 'Count tasks', returns: int)
  /// Future<IntentResult> countTasks() async =>
  ///     IntentResult.value(await TaskRepo.instance.count());
  /// ```
  ///
  /// Declared rather than inferred, because there is nothing to infer it from:
  /// every handler returns `Future<IntentResult>`, and what is inside is not in
  /// the signature. Swift needs it at compile time — `perform()`'s return type
  /// carries `ReturnsValue<T>` — so it has to be known when the code is
  /// generated, not when the handler runs.
  ///
  /// `String`, `int`, `double`, `bool` and `DateTime`. Anything else is
  /// rejected by the generator rather than compiled into Swift that will not
  /// build.
  ///
  /// Without this, an [IntentResult.value] has nowhere to go: the intent still
  /// runs and still speaks its dialog, but the value is dropped. Nothing can
  /// warn about that — what a handler returns is decided when it runs, and
  /// this is decided when the code is generated.
  ///
  /// iOS only so far. On Android an AppFunction answers with a fixed reply
  /// object, so a declared return type changes nothing there; the handler's
  /// spoken text still arrives.
  final Type? returns;

  /// Android: offer this action as a launcher shortcut.
  ///
  /// On by default, since an action nobody can reach is not worth declaring.
  /// Turn it off for actions that only make sense to an assistant, or to keep
  /// a long list from crowding the launcher — how many it shows is the
  /// launcher's decision, and the order here is the order it ranks them in.
  final bool androidShortcut;

  /// Android: the built-in intent this action fulfils, for example
  /// `actions.intent.CREATE_TASK`.
  ///
  /// This is what lets Assistant invoke the action by voice, and it is the
  /// Android counterpart of [phrases] — but it cannot be derived from them.
  /// Android matches an app action against Google's fixed catalogue of
  /// built-in intents rather than against wording the app chooses, so the right
  /// name is a lookup, not a translation.
  ///
  /// Without one, the action still gets a launcher shortcut; it just has no
  /// spoken trigger.
  final String? androidCapability;
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
    this.androidCapabilityParameter,
  });

  final String title;
  final String? description;

  /// Prompt spoken when the user triggered the intent without this value.
  /// Leaving it null makes the parameter effectively required up front.
  final String? requestValueDialog;

  final Object? defaultValue;

  /// Android: the built-in intent parameter this value comes from, for example
  /// `task.name`.
  ///
  /// Only meaningful on an intent that sets `androidCapability`, and only these
  /// parameters can be filled by voice: Assistant supplies what the built-in
  /// intent defines and nothing else. A parameter without one is still passed
  /// when the action is opened from a launcher shortcut, just never spoken.
  final String? androidCapabilityParameter;
}
