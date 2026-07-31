import 'package:meta/meta.dart';

/// What a handler hands back to the system.
///
/// Mirrors the shapes `IntentResult` can take on iOS; the Android side maps
/// what it can and degrades the rest to a plain value.
@immutable
sealed class IntentResult {
  const IntentResult();

  /// Succeeded, nothing to say or show.
  const factory IntentResult.done() = DoneResult;

  /// Succeeded, with something for Siri to speak.
  const factory IntentResult.dialog(String spoken, {String? displayed}) =
      DialogResult;

  /// Succeeded, returning a value that can feed the next step of a Shortcut.
  const factory IntentResult.value(Object value) = ValueResult;

  /// Succeeded, with a card to render.
  const factory IntentResult.snippet(SnippetSpec spec, {String? spoken}) =
      SnippetResult;

  /// Ask the user to confirm before the action is treated as done.
  const factory IntentResult.needsConfirmation(String prompt) =
      ConfirmationResult;

  /// Give up on running headless and open the app instead.
  const factory IntentResult.openApp({String? deepLink}) = OpenAppResult;

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
  const ValueResult(this.value);
  final Object value;
  @override
  Map<String, Object?> toWire() => {'kind': 'value', 'value': value};
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

final class ConfirmationResult extends IntentResult {
  const ConfirmationResult(this.prompt);
  final String prompt;
  @override
  Map<String, Object?> toWire() => {'kind': 'confirm', 'prompt': prompt};
}

final class OpenAppResult extends IntentResult {
  const OpenAppResult({this.deepLink});
  final String? deepLink;
  @override
  Map<String, Object?> toWire() => {'kind': 'openApp', 'deepLink': deepLink};
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
