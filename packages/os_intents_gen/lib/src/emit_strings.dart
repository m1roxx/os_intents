import 'dart:convert';

import 'model.dart';

/// Builds the String Catalogues the generated Swift looks its text up in.
///
/// The one emitter here that does **not** own its output file. Everything else
/// writes what the manifest says and overwrites whatever was there; a catalogue
/// holds translations that came from a person, and no build step gets to throw
/// those away. So this merges: the manifest decides which keys exist and what
/// the source language says, and everything else on disk is left alone.
///
/// Two files, because Apple localises the two halves by different mechanisms:
///
///   * **`OsIntents.xcstrings`** — titles, descriptions, prompts, choices.
///     Keyed, and the key is derived from ids so that improving the English
///     copy does not orphan every translation of it.
///   * **`AppShortcuts.xcstrings`** — spoken phrases. Not keyed, and not by
///     choice: `AppShortcutPhrase` is `ExpressibleByStringInterpolation` over a
///     plain `String` with no `LocalizedStringResource` initialiser anywhere in
///     the SDK, so the English phrase *is* the key. The file name is Apple's
///     and is the only thing that makes it a phrase table, which is why it is
///     fixed here rather than configurable.
class StringCatalogEmitter {
  StringCatalogEmitter(this.manifest);

  final Manifest manifest;

  /// The table the generated Swift names. Also the catalogue's file stem.
  static const tableName = 'OsIntents';

  /// Apple's, not ours. Renaming it stops it being a phrase table.
  static const phrasesTableName = 'AppShortcuts';

  static const fileName = '$tableName.xcstrings';
  static const phrasesFileName = '$phrasesTableName.xcstrings';

  /// Merges the manifest into whatever is already on disk.
  ///
  /// [existing] is the file's current contents, or null the first time.
  MergedCatalog merge({String? existing, String? existingPhrases}) => (
    catalog: _merge(existing, [for (final s in manifest.localisableStrings) s]),
    phrases: _merge(existingPhrases, [
      for (final p in manifest.phrases)
        LocalisableString(
          key: p,
          value: p,
          comment:
              'A phrase the user can say. Keep the \${applicationName} '
              'token — Apple requires every phrase to name the app.',
        ),
    ]),
  );

  /// Keys a catalogue holds that no intent declares any more.
  ///
  /// Reported rather than removed. A key nothing references is usually a
  /// renamed intent, and the translations under it are the expensive half —
  /// deleting them to tidy up a generated file is not a trade this can make on
  /// somebody's behalf.
  List<String> orphans(String? existing) {
    if (existing == null) return const [];
    final declared = {for (final s in manifest.localisableStrings) s.key};
    return [
      for (final key in _strings(existing).keys)
        if (!declared.contains(key)) key,
    ]..sort();
  }

  static String _merge(String? existing, List<LocalisableString> declared) {
    final source = _sourceLanguage(existing);
    final before = _strings(existing);
    final after = <String, Object?>{};

    for (final s in declared) {
      final prior = before[s.key];
      after[s.key] = prior == null
          ? _fresh(s, source)
          : _updated(prior, s, source);
    }
    // Anything the manifest no longer declares is carried through untouched;
    // `orphans` reports it so a person can decide.
    for (final entry in before.entries) {
      after.putIfAbsent(entry.key, () => entry.value);
    }

    final sorted = after.keys.toList()..sort();
    return '${const JsonEncoder.withIndent('  ').convert({
      'sourceLanguage': source,
      'strings': {for (final k in sorted) k: after[k]},
      'version': '1.0',
    })}\n';
  }

  static Map<String, Object?> _fresh(LocalisableString s, String source) => {
    'comment': s.comment,
    // "manual" rather than "extracted_with_value": these keys are not what
    // Xcode's own extractor would find in the source, and letting it think it
    // owns them makes it mark every one stale on the next build.
    'extractionState': 'manual',
    'localizations': {
      source: {
        'stringUnit': {'state': 'translated', 'value': s.value},
      },
    },
  };

  /// Keeps every translation, and says which ones the English moved out from
  /// under.
  ///
  /// Dart is the source of truth for the source language, so its value always
  /// wins. When that value actually changed, the other languages are marked
  /// `needs_review` — which is exactly what Xcode does in the same situation,
  /// and what makes the change visible in the editor the user will open this
  /// in rather than silently leaving a translation of the old wording.
  static Map<String, Object?> _updated(
    Object? prior,
    LocalisableString s,
    String source,
  ) {
    final entry = <String, Object?>{
      ...?(prior as Map?)?.cast<String, Object?>(),
    };
    entry['comment'] = s.comment;
    entry['extractionState'] = 'manual';

    final localizations = <String, Object?>{
      ...?(entry['localizations'] as Map?)?.cast<String, Object?>(),
    };
    final wasValue = _valueOf(localizations[source]);
    final changed = wasValue != null && wasValue != s.value;

    localizations[source] = {
      'stringUnit': {'state': 'translated', 'value': s.value},
    };

    if (changed) {
      for (final language in localizations.keys.toList()) {
        if (language == source) continue;
        final unit = <String, Object?>{
          ...?((localizations[language] as Map?)?['stringUnit'] as Map?)
              ?.cast<String, Object?>(),
        };
        if (unit.isEmpty) continue;
        unit['state'] = 'needs_review';
        localizations[language] = {'stringUnit': unit};
      }
    }

    entry['localizations'] = localizations;
    return entry;
  }

  static String? _valueOf(Object? localization) =>
      ((localization as Map?)?['stringUnit'] as Map?)?['value'] as String?;

  static String _sourceLanguage(String? existing) {
    if (existing == null) return 'en';
    try {
      final decoded = jsonDecode(existing);
      if (decoded is Map && decoded['sourceLanguage'] is String) {
        return decoded['sourceLanguage'] as String;
      }
    } on FormatException {
      // A catalogue nobody can parse is handled by `_strings`, which reports
      // it; falling back here keeps the two answers consistent.
    }
    return 'en';
  }

  static Map<String, Object?> _strings(String? existing) {
    if (existing == null) return {};
    final decoded = jsonDecode(existing);
    if (decoded is! Map || decoded['strings'] is! Map) {
      throw const FormatException(
        'This does not look like a String Catalogue: no "strings" object. '
        'os_intents merges into it rather than overwriting it, so it will not '
        'replace a file it cannot read.',
      );
    }
    return (decoded['strings'] as Map).cast<String, Object?>();
  }
}

/// The two catalogues, as they should now read on disk.
typedef MergedCatalog = ({String catalog, String phrases});
