/// Reader for `Metadata.appintents/extract.actionsdata` — the file Xcode's
/// metadata processor leaves in a built bundle, and the only place that says
/// what the OS will actually see.
///
/// Kept pure and separate from the command so it can be tested against a
/// captured fixture rather than a device, the same way the emitters are.
///
/// The format is Apple's and undocumented; every field read here was observed
/// in a real bundle (`version: 1`, tools 17A324). Anything unrecognised is
/// carried through as-is rather than guessed at, so a format change degrades
/// into a vaguer report instead of a wrong one.
library;

import 'dart:convert';

/// What one `AppIntent` looks like once extracted.
class ActionInfo {
  ActionInfo({
    required this.identifier,
    required this.title,
    required this.description,
    required this.opensApp,
    required this.isDiscoverable,
    required this.params,
    required this.mangledTypeName,
  });

  final String identifier;
  final String? title;
  final String? description;

  /// `openAppWhenRun` — the difference between "Siri answers" and "the app
  /// launches", and the single most common surprise in a report.
  final bool opensApp;

  /// False hides the intent from Shortcuts and Spotlight while leaving it
  /// runnable by an assistant.
  final bool isDiscoverable;

  final List<ActionParamInfo> params;
  final String? mangledTypeName;
}

class ActionParamInfo {
  ActionParamInfo({
    required this.name,
    required this.title,
    required this.isOptional,
    required this.typeLabel,
    required this.entityTypeName,
  });

  final String name;
  final String? title;
  final bool isOptional;

  /// Human-readable type, or `type #N` when the identifier is one this reader
  /// has never seen in a real bundle. See [_primitiveNames].
  final String typeLabel;

  /// Set when the parameter takes an `AppEntity`, which is the case that has to
  /// line up with a query for resolution to work at all.
  final String? entityTypeName;
}

class EntityInfo {
  EntityInfo({
    required this.typeName,
    required this.displayName,
    required this.defaultQueryIdentifier,
  });

  final String typeName;
  final String? displayName;

  /// Fully qualified, e.g. `Runner.ProjectQuery`. Null means the entity has no
  /// default query and the system cannot resolve one from a spoken name.
  final String? defaultQueryIdentifier;
}

class QueryInfo {
  QueryInfo({required this.identifier, required this.entityType});

  final String identifier;
  final String? entityType;
}

/// One entry of the app's `AppShortcutsProvider` — a phrase set bound to an
/// action. No entry here means no spoken phrase reaches that intent.
class AutoShortcutInfo {
  AutoShortcutInfo({
    required this.actionIdentifier,
    required this.phrases,
    required this.shortTitle,
    required this.systemImageName,
  });

  final String actionIdentifier;
  final List<String> phrases;
  final String? shortTitle;
  final String? systemImageName;
}

class AppIntentsMetadata {
  AppIntentsMetadata({
    required this.actions,
    required this.entities,
    required this.queries,
    required this.autoShortcuts,
    required this.providerMangledName,
    required this.generator,
    required this.formatVersion,
  });

  final List<ActionInfo> actions;
  final List<EntityInfo> entities;
  final List<QueryInfo> queries;
  final List<AutoShortcutInfo> autoShortcuts;

  /// `autoShortcutProviderMangledName` — the one provider iOS selected. Apple
  /// picks exactly one per app and drops the rest without a word, so this
  /// naming someone else's type is the whole explanation for phrases that
  /// vanished.
  final String? providerMangledName;

  final String? generator;
  final int? formatVersion;

  ActionInfo? action(String identifier) {
    for (final a in actions) {
      if (a.identifier == identifier) return a;
    }
    return null;
  }

  AutoShortcutInfo? shortcutFor(String actionIdentifier) {
    for (final s in autoShortcuts) {
      if (s.actionIdentifier == actionIdentifier) return s;
    }
    return null;
  }

  bool hasEntity(String typeName) =>
      entities.any((e) => e.typeName == typeName);

  QueryInfo? queryFor(String entityTypeName) {
    for (final q in queries) {
      if (q.entityType == entityTypeName) return q;
    }
    return null;
  }

  static AppIntentsMetadata parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw FormatException(
        'extract.actionsdata is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException(
        'extract.actionsdata does not hold a JSON object.',
      );
    }

    final actions = <ActionInfo>[];
    for (final e in _objectMap(decoded['actions']).entries) {
      actions.add(_action(e.key, e.value));
    }
    actions.sort((a, b) => a.identifier.compareTo(b.identifier));

    final entities = <EntityInfo>[];
    for (final e in _objectMap(decoded['entities']).entries) {
      entities.add(
        EntityInfo(
          typeName: e.value['typeName'] as String? ?? e.key,
          displayName: _localized(e.value['displayTypeName']),
          defaultQueryIdentifier: e.value['defaultQueryIdentifier'] as String?,
        ),
      );
    }
    entities.sort((a, b) => a.typeName.compareTo(b.typeName));

    final queries = <QueryInfo>[];
    for (final e in _objectMap(decoded['queries']).entries) {
      queries.add(
        QueryInfo(
          identifier: e.value['identifier'] as String? ?? e.key,
          entityType: e.value['entityType'] as String?,
        ),
      );
    }
    queries.sort((a, b) => a.identifier.compareTo(b.identifier));

    final shortcuts = <AutoShortcutInfo>[];
    for (final raw in _objectList(decoded['autoShortcuts'])) {
      shortcuts.add(
        AutoShortcutInfo(
          actionIdentifier: raw['actionIdentifier'] as String? ?? '<unknown>',
          phrases: [
            for (final p in _objectList(raw['phraseTemplates']))
              if (p['key'] case final String k) k,
          ],
          shortTitle: _localized(raw['shortTitle']),
          systemImageName: raw['systemImageName'] as String?,
        ),
      );
    }

    final generator = _object(decoded['generator']);

    return AppIntentsMetadata(
      actions: actions,
      entities: entities,
      queries: queries,
      autoShortcuts: shortcuts,
      providerMangledName: switch (decoded['autoShortcutProviderMangledName']) {
        final String s when s.isNotEmpty => s,
        _ => null,
      },
      generator: switch (generator['name']) {
        final String n => [
          n,
          generator['version'],
        ].whereType<String>().join(' '),
        _ => null,
      },
      formatVersion: decoded['version'] as int?,
    );
  }

  static ActionInfo _action(String key, Map<String, Object?> raw) {
    final params = <ActionParamInfo>[];
    for (final p in _objectList(raw['parameters'])) {
      final valueType = _object(p['valueType']);
      params.add(
        ActionParamInfo(
          name: p['name'] as String? ?? '<unnamed>',
          title: _localized(p['title']),
          isOptional: p['isOptional'] as bool? ?? false,
          typeLabel: _typeLabel(valueType),
          entityTypeName: _entityTypeName(valueType),
        ),
      );
    }

    // `isDiscoverable` sits in two places and they have been seen to agree;
    // the nested one is the newer spelling, so it wins when present.
    final visibility = _object(raw['visibilityMetadata']);

    return ActionInfo(
      identifier: raw['identifier'] as String? ?? key,
      title: _localized(raw['title']),
      description: _localized(
        _object(raw['descriptionMetadata'])['descriptionText'],
      ),
      opensApp: raw['openAppWhenRun'] as bool? ?? false,
      isDiscoverable:
          visibility['isDiscoverable'] as bool? ??
          raw['isDiscoverable'] as bool? ??
          true,
      params: params,
      mangledTypeName: raw['mangledTypeName'] as String?,
    );
  }

  /// Primitive type identifiers, listed only where a real bundle has shown one.
  ///
  /// Deliberately incomplete: an unproven guess here would print a confident
  /// wrong type, which is worse than printing the number. Extend it when a
  /// build produces new evidence.
  static const _primitiveNames = <int, String>{0: 'String', 8: 'Date'};

  static String _typeLabel(Map<String, Object?> valueType) {
    final entity = _entityTypeName(valueType);
    if (entity != null) return entity;

    final primitive = _object(_object(valueType['primitive'])['wrapper']);
    if (primitive['typeIdentifier'] case final int id) {
      return _primitiveNames[id] ?? 'type #$id';
    }
    if (valueType.keys.firstOrNull case final String kind) return kind;
    return 'unknown';
  }

  static String? _entityTypeName(Map<String, Object?> valueType) =>
      _object(_object(valueType['entity'])['wrapper'])['typeName'] as String?;

  /// Titles and descriptions are `{"key": "...", "alternatives": []}`, where
  /// `key` is the authored string rather than a lookup key.
  static String? _localized(Object? raw) => switch (_object(raw)['key']) {
    final String s when s.isNotEmpty => s,
    _ => null,
  };

  static Map<String, Object?> _object(Object? raw) =>
      raw is Map<String, Object?> ? raw : const {};

  static Map<String, Map<String, Object?>> _objectMap(Object? raw) => {
    for (final e in _object(raw).entries)
      if (e.value is Map<String, Object?>)
        e.key: e.value! as Map<String, Object?>,
  };

  static List<Map<String, Object?>> _objectList(Object? raw) => [
    if (raw is List)
      for (final e in raw)
        if (e is Map<String, Object?>) e,
  ];
}

/// Turns `6Runner18OsIntentsShortcutsV` into `Runner.OsIntentsShortcuts`.
///
/// Only the length-prefixed nominal form is handled — that is all a provider,
/// entity or intent type name ever is here. Anything else comes back unchanged,
/// because a half-demangled name would be harder to search for than the raw one.
String demangleSwiftTypeName(String mangled) {
  final parts = <String>[];
  var i = 0;
  while (i < mangled.length) {
    var digits = 0;
    while (i + digits < mangled.length &&
        _isDigit(mangled.codeUnitAt(i + digits))) {
      digits++;
    }
    if (digits == 0) break;
    final len = int.parse(mangled.substring(i, i + digits));
    final start = i + digits;
    if (start + len > mangled.length) return mangled;
    parts.add(mangled.substring(start, start + len));
    i = start + len;
  }
  if (parts.isEmpty) return mangled;
  return parts.join('.');
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
