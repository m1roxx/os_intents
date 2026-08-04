import 'package:meta/meta.dart';

import 'wire.dart';

/// A launcher shortcut the app publishes itself, while it is running.
///
/// **Android only.** The counterpart of `OsIntents.donate` on iOS, and
/// deliberately under its own name rather than behind the same call, because
/// the two are not the same thing. A donation is a hint to a ranking model:
/// iOS decides whether the action is ever shown. A dynamic shortcut is an entry
/// the app puts on the launcher and is then responsible for — it has a rank, an
/// icon, and a cap of a few per app. Pretending one was the other would mean
/// deciding when to evict somebody else's shortcut, which is the app's call.
///
/// What it is for is the same thing, though: the actions declared by
/// `@AppIntent` are *available*, and these are *particular* — "Complete Buy
/// milk", not "Complete task". Push one when the user does something worth
/// offering back:
///
/// ```dart
/// await OsIntents.pushShortcut(
///   DynamicShortcut(
///     id: 'task-${task.id}',
///     intentId: 'completeTask',
///     shortLabel: task.title,
///     args: {'taskId': task.id},
///   ),
/// );
/// ```
///
/// Tapping it runs the named intent through the same path a generated app
/// shortcut uses, so the handler sees the values in [args] exactly as if the
/// system had filled them in.
@immutable
class DynamicShortcut {
  const DynamicShortcut({
    required this.id,
    required this.intentId,
    required this.shortLabel,
    this.longLabel,
    this.args = const {},
    this.iconResource,
    this.rank = 0,
  });

  /// This shortcut's own identity, unique within the app.
  ///
  /// Not the intent's id — several shortcuts commonly run the same intent with
  /// different values. Pushing the same id again replaces the entry rather than
  /// adding a second, which is what makes "most recent five" easy to keep.
  final String id;

  /// Which `@AppIntent` it runs, by the same id `IntentHarness` uses.
  final String intentId;

  /// What the launcher shows. Android truncates it to about ten characters, so
  /// this is a name, not a sentence.
  final String shortLabel;

  /// Shown where there is room for it, in the long-press menu.
  final String? longLabel;

  /// The values the handler receives, converted the same way a donation's are:
  /// a `DateTime` or an enum constant as itself, an entity as its identifier.
  ///
  /// Only primitives survive: they cross as Intent extras, and anything else
  /// would be a Parcelable no generated handler has a parameter for.
  final Map<String, Object?> args;

  /// An Android drawable or mipmap, by resource name — `ic_task`,
  /// `@mipmap/ic_launcher`.
  ///
  /// Resolved in the app's own resources, so it must be something the app
  /// ships. Without one the launcher uses the app icon.
  final String? iconResource;

  /// Where it sits among the app's own shortcuts, lower first.
  ///
  /// Also what the system evicts by when the app is at its cap — see
  /// `OsIntents.maxShortcuts`.
  final int rank;

  Map<String, Object?> toWire() => {
    'id': id,
    'intentId': intentId,
    'shortLabel': shortLabel,
    if (longLabel != null) 'longLabel': longLabel,
    if (iconResource != null) 'iconResource': iconResource,
    'rank': rank,
    'args': {for (final e in args.entries) e.key: wireValue(e.value)},
  };
}
