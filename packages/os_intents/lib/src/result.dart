import 'package:meta/meta.dart';

/// What a handler hands back to the system.
///
/// Every shape here is one the generated native code actually acts on. Three
/// others were modelled before they were wired — a returned value, a
/// confirmation prompt, and a request to open the app — and are not in this
/// release, because a factory whose name promises something the system never
/// does is worse than its absence. What each needs is in
/// `docs/verified.md`; they will come back as additions, not as replacements.
@immutable
sealed class IntentResult {
  const IntentResult();

  /// Succeeded, nothing to say or show.
  const factory IntentResult.done() = DoneResult;

  /// Succeeded, with something for Siri to speak.
  const factory IntentResult.dialog(String spoken, {String? displayed}) =
      DialogResult;

  /// Succeeded, with a card to render.
  ///
  /// Needs `showsSnippet: true` on the intent: Swift fixes `perform()`'s
  /// return type at compile time, so whether a card can be attached is decided
  /// when the code is generated, not when the handler runs.
  const factory IntentResult.snippet(SnippetSpec spec, {String? spoken}) =
      SnippetResult;

  /// Succeeded, returning a value the next step of a Shortcut can use.
  ///
  /// Needs `returns:` on the intent, for the same reason as a snippet — the
  /// type is part of `perform()`'s signature, so it has to be known when the
  /// code is generated. Without it the value is dropped, and the generator
  /// says so rather than letting it happen quietly.
  const factory IntentResult.value(Object value, {String? spoken}) =
      ValueResult;

  Map<String, Object?> toWire();
}

final class DoneResult extends IntentResult {
  const DoneResult();
  @override
  Map<String, Object?> toWire() => const {'kind': 'done'};
}

final class DialogResult extends IntentResult {
  const DialogResult(this.spoken, {this.displayed});
  final String spoken;
  final String? displayed;
  @override
  Map<String, Object?> toWire() => {
    'kind': 'dialog',
    'spoken': spoken,
    'displayed': displayed,
  };
}

final class ValueResult extends IntentResult {
  const ValueResult(this.value, {this.spoken});
  final Object value;

  /// What Siri says while handing the value on. Optional: a Shortcut step that
  /// feeds another step usually has nothing worth saying.
  final String? spoken;

  @override
  Map<String, Object?> toWire() => {
    'kind': 'value',
    'value': value,
    'spoken': spoken,
  };
}

final class SnippetResult extends IntentResult {
  const SnippetResult(this.spec, {this.spoken});
  final SnippetSpec spec;
  final String? spoken;
  @override
  Map<String, Object?> toWire() => {
    'kind': 'snippet',
    'spoken': spoken,
    'spec': spec.toWire(),
  };
}

/// A declarative card.
///
/// Deliberately not a Flutter widget: Siri and Shortcuts render SwiftUI, and
/// there is no way to host a Flutter view there. This spec compiles to a real
/// SwiftUI view at build time. Small and predictable beats expressive and
/// broken.
@immutable
class SnippetSpec {
  const SnippetSpec({
    required this.title,
    this.subtitle,
    this.rows = const [],
    this.imageSystemName,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<SnippetRow> rows;
  final String? imageSystemName;

  /// Buttons on the card, each running another one of your intents.
  ///
  /// Needs iOS 17: below that the card renders without them rather than not at
  /// all. Only intents declared in this app can be named — the button has to be
  /// built from a real type when the code is generated, which is why an action
  /// carries an id and not a callback.
  final List<SnippetAction> actions;

  Map<String, Object?> toWire() => {
    'title': title,
    'subtitle': subtitle,
    'imageSystemName': imageSystemName,
    'rows': [
      for (final r in rows) {'label': r.label, 'value': r.value},
    ],
    if (actions.isNotEmpty) 'actions': [for (final a in actions) a.toWire()],
  };
}

/// A button on a snippet card, and the intent it runs.
///
/// The values are ordinary wire values — a `DateTime` or an enum constant as
/// itself, an entity as its identifier — so they can come from whatever the
/// handler just computed. The *action* cannot: `Button(intent:)` needs a
/// concrete type, so which intents a button may run is fixed when the code is
/// generated. Naming an id nothing declares leaves the button out.
@immutable
class SnippetAction {
  const SnippetAction({
    required this.label,
    required this.intentId,
    this.args = const {},
    this.systemImageName,
  });

  /// What the button says.
  final String label;

  /// Which of your intents it runs — the same id `IntentHarness` uses.
  final String intentId;

  final Map<String, Object?> args;

  /// SF Symbol shown beside the label.
  final String? systemImageName;

  Map<String, Object?> toWire() => {
    'label': label,
    'intentId': intentId,
    if (systemImageName != null) 'systemImageName': systemImageName,
    'args': {for (final e in args.entries) e.key: wireValue(e.value)},
  };
}

@immutable
class SnippetRow {
  const SnippetRow(this.label, this.value);
  final String label;
  final String value;
}

/// Puts a value into the form the generated native code decodes.
///
/// The method channel carries neither a `DateTime` nor an enum, and both are
/// what a handler deals in — so converting here keeps the wire format an
/// implementation detail rather than something a caller has to know. The same
/// shape a generated `perform()` writes on the way in: epoch milliseconds UTC
/// for a date, the constant's own name for an enum.
///
/// Shared by `OsIntents.donate` and [SnippetAction], which hand values to the
/// same decoders from opposite ends of the package.
@internal
Object? wireValue(Object? value) => switch (value) {
  final DateTime d => d.toUtc().millisecondsSinceEpoch,
  final Enum e => e.name,
  _ => value,
};
