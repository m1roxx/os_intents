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
  });

  final String title;
  final String? subtitle;
  final List<SnippetRow> rows;
  final String? imageSystemName;

  Map<String, Object?> toWire() => {
    'title': title,
    'subtitle': subtitle,
    'imageSystemName': imageSystemName,
    'rows': [
      for (final r in rows) {'label': r.label, 'value': r.value},
    ],
  };
}

@immutable
class SnippetRow {
  const SnippetRow(this.label, this.value);
  final String label;
  final String value;
}
