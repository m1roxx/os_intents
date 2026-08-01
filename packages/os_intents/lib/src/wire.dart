/// Values on their way to the generated native decoders.
///
/// Not exported from `os_intents.dart` on purpose. Marking the helper
/// `@internal` inside an exported library is not enough — the analyzer reports
/// `invalid_export_of_internal_element`, and it is right: a hidden member of a
/// public API is still in the public API. A file nobody exports is.
library;

/// Puts a value into the form the generated native code decodes.
///
/// The method channel carries neither a `DateTime` nor an enum, and both are
/// what a handler deals in — so converting here keeps the wire format an
/// implementation detail rather than something a caller has to know. The same
/// shape a generated `perform()` writes on the way in: epoch milliseconds UTC
/// for a date, the constant's own name for an enum.
///
/// Shared by `OsIntents.donate` and `SnippetAction`, which hand values to the
/// same generated decoder from opposite ends of the package.
Object? wireValue(Object? value) => switch (value) {
  final DateTime d => d.toUtc().millisecondsSinceEpoch,
  final Enum e => e.name,
  _ => value,
};
