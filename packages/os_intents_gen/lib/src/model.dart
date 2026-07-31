/// Platform-neutral description of the annotated code, produced by the parser
/// and consumed by every emitter.
///
/// Serialised to `*.os_intents.json` next to the generated Dart, because
/// `build_runner` can only write outputs whose paths derive from their inputs —
/// it cannot reach `ios/`. The CLI picks the manifests up and emits Swift.
library;

import 'dart:convert';

/// How a handler body is run. Mirrors `Execution` in `package:os_intents`.
enum ExecutionMode {
  foreground,
  background,
  static_;

  static ExecutionMode parse(String raw) => switch (raw) {
    'foreground' => ExecutionMode.foreground,
    'background' => ExecutionMode.background,
    'static_' || 'static' => ExecutionMode.static_,
    _ => throw ArgumentError.value(raw, 'execution', 'unknown execution mode'),
  };

  String get wire => this == ExecutionMode.static_ ? 'static' : name;
}

/// Dart types a parameter may have, and how each maps onto the platforms.
enum ParamType {
  string('String', 'String', 'String'),
  int_('int', 'Int', 'Long'),
  double_('double', 'Double', 'Double'),
  bool_('bool', 'Bool', 'Boolean'),
  dateTime('DateTime', 'Date', 'Long'),
  entity('<entity>', '<entity>', '<entity>');

  const ParamType(this.dart, this.swift, this.kotlin);

  final String dart;
  final String swift;
  final String kotlin;

  static ParamType? fromDart(String name) {
    for (final t in values) {
      if (t != ParamType.entity && t.dart == name) return t;
    }
    return null;
  }
}

class ParamSpec {
  ParamSpec({
    required this.name,
    required this.title,
    required this.type,
    required this.isRequired,
    this.entityTypeName,
    this.description,
    this.requestValueDialog,
    this.androidCapabilityParameter,
  });

  final String name;
  final String title;
  final ParamType type;

  /// Set when [type] is [ParamType.entity]; names the `@AppEntity` typeName.
  final String? entityTypeName;

  final bool isRequired;
  final String? description;
  final String? requestValueDialog;

  /// Android: the built-in intent parameter that fills this, e.g. `task.name`.
  final String? androidCapabilityParameter;

  /// Swift type used in the generated `@Parameter` declaration.
  String get swiftType =>
      type == ParamType.entity ? '${entityTypeName}Entity' : type.swift;

  Map<String, Object?> toJson() => {
    'name': name,
    'title': title,
    'type': type.name,
    if (entityTypeName != null) 'entityTypeName': entityTypeName,
    'isRequired': isRequired,
    if (description != null) 'description': description,
    if (requestValueDialog != null) 'requestValueDialog': requestValueDialog,
    if (androidCapabilityParameter != null)
      'androidCapabilityParameter': androidCapabilityParameter,
  };

  static ParamSpec fromJson(Map<String, Object?> j) => ParamSpec(
    name: j['name']! as String,
    title: j['title']! as String,
    type: ParamType.values.byName(j['type']! as String),
    entityTypeName: j['entityTypeName'] as String?,
    isRequired: j['isRequired']! as bool,
    description: j['description'] as String?,
    requestValueDialog: j['requestValueDialog'] as String?,
    androidCapabilityParameter: j['androidCapabilityParameter'] as String?,
  );
}

class IntentSpec {
  IntentSpec({
    required this.id,
    required this.functionName,
    required this.title,
    required this.execution,
    this.description,
    this.phrases = const [],
    this.systemImageName,
    this.showsInSpotlight = true,
    this.showsSnippet = false,
    this.androidShortcut = true,
    this.androidCapability,
    this.params = const [],
  });

  final String id;
  final String functionName;
  final String title;
  final String? description;
  final List<String> phrases;
  final ExecutionMode execution;
  final String? systemImageName;
  final bool showsInSpotlight;
  final bool showsSnippet;

  /// Android: offer this as a launcher shortcut.
  final bool androidShortcut;

  /// Android: the built-in intent this fulfils, e.g. `actions.intent.CREATE_TASK`.
  final String? androidCapability;

  final List<ParamSpec> params;

  /// Whether a launcher shortcut for this would actually work.
  ///
  /// A tap from the launcher carries no values — there is nowhere in
  /// `shortcuts.xml` to put one and nobody to ask. So an intent with a required
  /// parameter cannot be offered there: the shortcut would appear, and fail the
  /// moment it was used. A capability is different, because Assistant fills the
  /// built-in intent's parameters before it launches anything.
  bool get canBeLauncherShortcut =>
      androidShortcut && params.every((p) => !p.isRequired);

  /// Whether anything is emitted for this intent into `shortcuts.xml`.
  bool get hasAndroidShortcut =>
      canBeLauncherShortcut || androidCapability != null;

  /// Required parameters that keep this out of the launcher, for reporting.
  List<String> get androidShortcutBlockers => androidShortcut
      ? [for (final p in params) if (p.isRequired) p.name]
      : const [];

  /// Resource name for this intent's label strings.
  ///
  /// `shortcutShortLabel` will not take a literal, so every shortcut drags a
  /// `values` entry along with it and the two files have to agree on the name.
  String get androidLabelResource => 'os_intents_${id}_label';

  /// Whether this intent can end up needing the headless Dart engine.
  ///
  /// True for background, and also for static: a static intent whose value has
  /// not been published yet falls back to running the handler rather than
  /// answering with silence.
  bool get needsHeadlessEngine => execution != ExecutionMode.foreground;

  /// PascalCase name of the generated Swift struct.
  String get swiftTypeName =>
      '${id[0].toUpperCase()}${id.substring(1)}OsIntent';

  /// Apple rejects shortcut phrases that don't name the app, and the failure
  /// surfaces only at App Review. Catch it at build time instead.
  List<String> validate() {
    final problems = <String>[];
    if (title.trim().isEmpty) {
      problems.add('Intent "$id" has an empty title.');
    }
    for (final p in phrases) {
      if (!p.contains(r'$app')) {
        problems.add(
          'Phrase "$p" on intent "$id" is missing the \$app placeholder. '
          'Apple requires every phrase to name the app.',
        );
      }
    }
    final seen = <String>{};
    for (final p in params) {
      if (!seen.add(p.name)) {
        problems.add('Intent "$id" declares parameter "${p.name}" twice.');
      }
    }
    if (execution == ExecutionMode.static_ && params.isNotEmpty) {
      problems.add(
        'Intent "$id" is Execution.static_ but takes parameters. A static '
        'intent is answered by generated native code with no Dart running, so '
        'it cannot receive arguments.',
      );
    }
    return problems;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'functionName': functionName,
    'title': title,
    if (description != null) 'description': description,
    'phrases': phrases,
    'execution': execution.wire,
    if (systemImageName != null) 'systemImageName': systemImageName,
    'showsInSpotlight': showsInSpotlight,
    'showsSnippet': showsSnippet,
    'androidShortcut': androidShortcut,
    if (androidCapability != null) 'androidCapability': androidCapability,
    'params': [for (final p in params) p.toJson()],
  };

  static IntentSpec fromJson(Map<String, Object?> j) => IntentSpec(
    id: j['id']! as String,
    functionName: j['functionName']! as String,
    title: j['title']! as String,
    description: j['description'] as String?,
    phrases: (j['phrases'] as List? ?? const []).cast<String>(),
    execution: ExecutionMode.parse(j['execution']! as String),
    systemImageName: j['systemImageName'] as String?,
    showsInSpotlight: j['showsInSpotlight'] as bool? ?? true,
    showsSnippet: j['showsSnippet'] as bool? ?? false,
    androidShortcut: j['androidShortcut'] as bool? ?? true,
    androidCapability: j['androidCapability'] as String?,
    params: [
      for (final p in (j['params'] as List? ?? const []))
        ParamSpec.fromJson((p as Map).cast<String, Object?>()),
    ],
  );
}

class EntityPropertySpec {
  EntityPropertySpec({
    required this.name,
    required this.type,
    this.isTitle = false,
    this.isSubtitle = false,
  });

  final String name;
  final ParamType type;
  final bool isTitle;
  final bool isSubtitle;

  Map<String, Object?> toJson() => {
    'name': name,
    'type': type.name,
    'isTitle': isTitle,
    'isSubtitle': isSubtitle,
  };

  static EntityPropertySpec fromJson(Map<String, Object?> j) =>
      EntityPropertySpec(
        name: j['name']! as String,
        type: ParamType.values.byName(j['type']! as String),
        isTitle: j['isTitle'] as bool? ?? false,
        isSubtitle: j['isSubtitle'] as bool? ?? false,
      );
}

class EntitySpec {
  EntitySpec({
    required this.typeName,
    required this.dartClassName,
    required this.idProperty,
    this.displayName,
    this.properties = const [],
    this.hasQuery = false,
    this.queryClassName,
  });

  final String typeName;
  final String dartClassName;
  final String idProperty;
  final String? displayName;
  final List<EntityPropertySpec> properties;
  final bool hasQuery;
  final String? queryClassName;

  String get swiftTypeName => '${typeName}Entity';

  List<String> validate() {
    final problems = <String>[];
    if (!properties.any((p) => p.isTitle)) {
      problems.add(
        'Entity "$typeName" has no @EntityDisplay(title: true) property. '
        'Without one the system has nothing to show or speak when it offers '
        'the entity to the user.',
      );
    }
    if (properties.where((p) => p.isTitle).length > 1) {
      problems.add('Entity "$typeName" marks more than one property as title.');
    }
    return problems;
  }

  Map<String, Object?> toJson() => {
    'typeName': typeName,
    'dartClassName': dartClassName,
    'idProperty': idProperty,
    if (displayName != null) 'displayName': displayName,
    'properties': [for (final p in properties) p.toJson()],
    'hasQuery': hasQuery,
    if (queryClassName != null) 'queryClassName': queryClassName,
  };

  static EntitySpec fromJson(Map<String, Object?> j) => EntitySpec(
    typeName: j['typeName']! as String,
    dartClassName: j['dartClassName']! as String,
    idProperty: j['idProperty']! as String,
    displayName: j['displayName'] as String?,
    properties: [
      for (final p in (j['properties'] as List? ?? const []))
        EntityPropertySpec.fromJson((p as Map).cast<String, Object?>()),
    ],
    hasQuery: j['hasQuery'] as bool? ?? false,
    queryClassName: j['queryClassName'] as String?,
  );
}

/// Everything found in one library, written to `*.os_intents.json`.
class Manifest {
  Manifest({
    required this.source,
    this.intents = const [],
    this.entities = const [],
    String? libraryUri,
  }) : libraryUri = libraryUri ?? _uriFromSource(source);

  /// `package:` URI of the library these specs came from.
  ///
  /// Kept as a field rather than derived on demand because [merge] throws the
  /// individual sources away, and the background engine needs this to find the
  /// generated entrypoint.
  final String? libraryUri;

  static String? _uriFromSource(String source) {
    final parts = source.split('|');
    if (parts.length != 2) return null;
    final path = parts[1];
    if (!path.startsWith('lib/')) return null;
    return 'package:${parts[0]}/${path.substring('lib/'.length)}';
  }

  bool get hasBackgroundIntents => intents.any((i) => i.needsHeadlessEngine);

  /// Asset path of the library the specs came from, for error messages.
  final String source;
  final List<IntentSpec> intents;
  final List<EntitySpec> entities;

  static const int formatVersion = 1;

  /// Library the background engine must start, or null when nothing needs it.
  ///
  /// `FlutterEngine.run(withEntrypoint:libraryURI:)` needs this: the entrypoint
  /// is not in `main.dart`, and without the URI the engine looks only there and
  /// fails to start with nothing but a `false`.
  String? get entrypointLibraryUri =>
      hasBackgroundIntents ? libraryUri : null;

  List<String> validate() => [
    for (final i in intents) ...i.validate(),
    for (final e in entities) ...e.validate(),
  ];

  /// An entity used as a parameter must be resolvable, or the generated Dart
  /// would have no way to turn the identifier the OS supplies back into an
  /// object.
  List<String> validateEntityUse() {
    final problems = <String>[];
    final byType = {for (final e in entities) e.typeName: e};
    for (final intent in intents) {
      for (final p in intent.params) {
        if (p.type != ParamType.entity) continue;
        final entity = byType[p.entityTypeName];
        if (entity == null) {
          problems.add(
            'Parameter "${p.name}" of intent "${intent.id}" refers to entity '
            '"${p.entityTypeName}", which is not declared anywhere in this '
            'project.',
          );
        } else if (!entity.hasQuery) {
          problems.add(
            'Parameter "${p.name}" of intent "${intent.id}" takes entity '
            '"${entity.typeName}", but no @EntityQuery(${entity.dartClassName}) '
            'class exists. Without one there is no way to turn the identifier '
            'the system supplies back into a ${entity.dartClassName}.',
          );
        }
      }
    }
    return problems;
  }

  String encode() => const JsonEncoder.withIndent('  ').convert({
    'formatVersion': formatVersion,
    'source': source,
    if (libraryUri != null) 'libraryUri': libraryUri,
    'intents': [for (final i in intents) i.toJson()],
    'entities': [for (final e in entities) e.toJson()],
  });

  static Manifest decode(String json) {
    final j = jsonDecode(json) as Map<String, Object?>;
    final v = j['formatVersion'] as int?;
    if (v != formatVersion) {
      throw FormatException(
        'Manifest format version $v, expected $formatVersion. Re-run '
        'build_runner so the manifests match this version of os_intents_cli.',
      );
    }
    return Manifest(
      source: j['source'] as String? ?? '<unknown>',
      libraryUri: j['libraryUri'] as String?,
      intents: [
        for (final i in (j['intents'] as List? ?? const []))
          IntentSpec.fromJson((i as Map).cast<String, Object?>()),
      ],
      entities: [
        for (final e in (j['entities'] as List? ?? const []))
          EntitySpec.fromJson((e as Map).cast<String, Object?>()),
      ],
    );
  }

  /// Merges manifests from every library in a project.
  ///
  /// Carries the background library through, since iOS starts exactly one Dart
  /// entrypoint and [merge] would otherwise discard the only clue to where it
  /// lives. Conflicts are reported by [validateGlobal] rather than resolved
  /// arbitrarily here.
  static Manifest merge(Iterable<Manifest> parts) {
    final list = parts.toList();
    final backgroundUris = <String>{
      for (final p in list)
        if (p.hasBackgroundIntents && p.libraryUri != null) p.libraryUri!,
    };
    return Manifest(
      source: '<merged>',
      libraryUri: backgroundUris.length == 1 ? backgroundUris.first : null,
      intents: [for (final p in list) ...p.intents],
      entities: [for (final p in list) ...p.entities],
    ).._backgroundUris = backgroundUris;
  }

  Set<String> _backgroundUris = const {};

  /// Ids must be unique across the whole app: they are the wire contract with
  /// the OS, and a collision silently shadows one handler.
  List<String> validateGlobal() {
    final problems = validate();
    problems.addAll(validateEntityUse());

    // iOS runs a single background entrypoint, and the generated one is a part
    // of whichever library declared the intents. Spread them across two
    // libraries and only one set could ever be reached.
    if (_backgroundUris.length > 1) {
      problems.add(
        'Execution.background intents are declared in more than one library '
        '(${(_backgroundUris.toList()..sort()).join(', ')}). iOS starts exactly '
        'one Dart entrypoint for headless work, so they must all live in the '
        'same library.',
      );
    }
    final seenIntents = <String, String>{};
    for (final i in intents) {
      final prev = seenIntents[i.id];
      if (prev != null) {
        problems.add(
          'Duplicate intent id "${i.id}" (functions $prev and '
          '${i.functionName}). Ids are the contract with the OS — set an '
          'explicit identifier on one of them.',
        );
      }
      seenIntents[i.id] = i.functionName;
    }
    final seenEntities = <String>{};
    for (final e in entities) {
      if (!seenEntities.add(e.typeName)) {
        problems.add('Duplicate entity typeName "${e.typeName}".');
      }
    }
    return problems;
  }
}
