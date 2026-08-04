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
///
/// Every Swift mapping here was type-checked against the real SDK before it was
/// written down, not read off documentation: `swift_compiles_test` puts one of
/// each through `swiftc -typecheck`, so a type App Intents does not actually
/// accept fails a test rather than a user's build.
enum ParamType {
  string('String', 'String', 'String'),
  int_('int', 'Int', 'Long'),
  double_('double', 'Double', 'Double'),
  bool_('bool', 'Bool', 'Boolean'),
  dateTime('DateTime', 'Date', 'Long'),
  // A link. `URL` is a first-class App Intents parameter, and Android has an
  // `AppFunctionUri` serialisable proxy for `android.net.Uri` — but nothing has
  // built an APK through it here, so the Kotlin side stays a String, which is
  // what crosses the wire either way. See docs/android.md.
  uri('Uri', 'URL', 'String'),
  // A length of time, which is not the same thing as a moment in time. Swift
  // has no Duration in App Intents' vocabulary; the system's own shape for
  // "how long" is a Measurement over UnitDuration, with a unit picker.
  duration('Duration', 'Measurement<UnitDuration>', 'Long'),
  // A quantity with a dimension. The Swift type depends on which dimension,
  // which is why this one is `<measurement>` here and resolved through
  // [ParamSpec.swiftType].
  measurement('Measurement', '<measurement>', 'Double'),
  // A file the system hands over. iOS only: `androidx.appfunctions` has no
  // counterpart — its model is a content URI plus a grant, not an inline file
  // — so an intent taking one is left out of the AppFunctions surface.
  file('IntentFile', 'IntentFile', '<unsupported>'),
  entity('<entity>', '<entity>', '<entity>'),
  // A Dart enum crosses as its constant name, so the Kotlin side is a plain
  // String narrowed by @AppFunctionStringValueConstraint. Swift gets a real
  // AppEnum, which is the only place the two platforms differ in kind.
  enum_('<enum>', '<enum>', 'String');

  const ParamType(this.dart, this.swift, this.kotlin);

  final String dart;
  final String swift;
  final String kotlin;

  /// Whether an intent may declare `returns:` this type.
  ///
  /// A returned value becomes the input of the next Shortcut step, so it has to
  /// be something `ReturnsValue<T>` can carry. Entities and enums cannot: the
  /// generated type is only known to the app target, and `perform()`'s
  /// signature is fixed before it exists. A measurement cannot either — its
  /// Swift type depends on a dimension, and `returns:` is a bare `Type` with
  /// nowhere to put one.
  bool get canReturn => switch (this) {
    ParamType.entity || ParamType.enum_ || ParamType.measurement => false,
    _ => true,
  };

  /// Whether `androidx.appfunctions` can express this at all.
  bool get hasAndroidCounterpart => this != ParamType.file;

  static ParamType? fromDart(String name) {
    for (final t in values) {
      if (t == ParamType.entity || t == ParamType.enum_) continue;
      if (t.dart == name) return t;
    }
    return null;
  }
}

/// What a [ParamType.measurement] parameter measures.
///
/// App Intents does not have one `Measurement` parameter — it has one per
/// dimension, each with its own unit picker, and the dimension is part of the
/// Swift type. So it cannot be inferred from a Dart value at run time; it is
/// declared on `@Param` and fixed when the code is generated.
///
/// `IntentParameter` has an overload for 22 dimensions, and **seven of them are
/// iOS 16**: the other fifteen — every electrical and optical one, plus area,
/// angle, frequency, pressure, power, information storage and the rest —
/// arrived in iOS 17. Measured, not read off documentation: the 22-dimension
/// case in `swift_compiles_test` is what found it, with fifteen
/// "only available in iOS 17.0 or newer".
///
/// So this is the seven, and the floor stays where the rest of the package's
/// is. Adding the others means either raising the floor for everyone or
/// version-gating a struct that three other generated files refer to by name —
/// a real cost for dimensions almost nothing ships. What is here is what an app
/// actually asks for: how far, how heavy, how long, how fast, how hot, how
/// much, how many calories.
///
/// [baseUnit] is the SI base unit in each, which is the unit the wire carries.
enum MeasurementDimension {
  duration('UnitDuration', 'seconds'),
  energy('UnitEnergy', 'joules'),
  length('UnitLength', 'meters'),
  mass('UnitMass', 'kilograms'),
  speed('UnitSpeed', 'metersPerSecond'),
  temperature('UnitTemperature', 'kelvin'),
  volume('UnitVolume', 'liters');

  const MeasurementDimension(this.swiftUnitType, this.baseUnit);

  /// Foundation's unit class, e.g. `UnitLength`.
  final String swiftUnitType;

  /// The unit the value crosses the wire in, e.g. `meters`.
  ///
  /// A measurement travels as one double rather than a value-and-unit pair:
  /// the dimension is already fixed by the declaration, so a unit on the wire
  /// would be a second source of truth for the same fact.
  final String baseUnit;

  String get swiftType => 'Measurement<$swiftUnitType>';

  static MeasurementDimension? byName(String name) {
    for (final d in values) {
      if (d.name == name) return d;
    }
    return null;
  }
}

/// One user-visible string, with the key the generated Swift looks it up by.
///
/// The key is derived rather than stored, so the emitter and the catalogue
/// builder cannot drift: both ask the spec. And it is derived from *ids*, not
/// from the English text — a key whose identity is the copy loses every
/// translation the moment somebody improves the wording.
class LocalisableString {
  const LocalisableString({
    required this.key,
    required this.value,
    required this.comment,
  });

  final String key;

  /// What the Dart annotation says, which is the source language's value.
  final String value;

  /// Where it appears, for whoever ends up translating it with no other
  /// context than this file.
  final String comment;
}

class ParamSpec {
  ParamSpec({
    required this.name,
    required this.title,
    required this.type,
    required this.isRequired,
    this.entityTypeName,
    this.enumTypeName,
    this.dimension,
    this.description,
    this.requestValueDialog,
    this.androidCapabilityParameter,
  });

  final String name;
  final String title;
  final ParamType type;

  /// Set when [type] is [ParamType.entity]; names the `@AppEntity` typeName.
  final String? entityTypeName;

  /// Set when [type] is [ParamType.enum_]; names the `@AppEnum` typeName.
  final String? enumTypeName;

  /// Set when [type] is [ParamType.measurement]; what is being measured.
  final MeasurementDimension? dimension;

  final bool isRequired;
  final String? description;
  final String? requestValueDialog;

  /// Android: the built-in intent parameter that fills this, e.g. `task.name`.
  final String? androidCapabilityParameter;

  String titleKey(String intentId) => '$intentId.$name.title';
  String descriptionKey(String intentId) => '$intentId.$name.description';
  String requestValueDialogKey(String intentId) => '$intentId.$name.ask';

  List<LocalisableString> localisableStrings(String intentId) => [
    LocalisableString(
      key: titleKey(intentId),
      value: title,
      comment: 'Name of the "$name" parameter of the "$intentId" action.',
    ),
    if (description case final d?)
      LocalisableString(
        key: descriptionKey(intentId),
        value: d,
        comment: 'Explanation of the "$name" parameter of "$intentId".',
      ),
    if (requestValueDialog case final d?)
      LocalisableString(
        key: requestValueDialogKey(intentId),
        value: d,
        comment:
            'Spoken when "$intentId" was triggered without a value for '
            '"$name". A question.',
      ),
  ];

  /// Swift type used in the generated `@Parameter` declaration.
  String get swiftType => switch (type) {
    ParamType.entity => '${entityTypeName}Entity',
    ParamType.enum_ => '${enumTypeName}Enum',
    ParamType.measurement => dimension!.swiftType,
    _ => type.swift,
  };

  /// That the type name is in the slot every emitter reads it from.
  ///
  /// Not a theoretical check. The parser once returned an enum's name in
  /// [entityTypeName], so [enumTypeName] stayed null and `swiftType`, the
  /// Kotlin value constraint and the Dart decode each interpolated the word
  /// "null" into a real source file. Nothing failed: the Swift named a type
  /// that did not exist, the Dart called `.values` on `null`, and both were
  /// found by building the example rather than by any test.
  List<String> validate(String intentId) => switch (type) {
    ParamType.entity when entityTypeName == null => [
      _wrongSlot(intentId, 'an entity', 'entityTypeName'),
    ],
    ParamType.enum_ when enumTypeName == null => [
      _wrongSlot(intentId, 'an enum', 'enumTypeName'),
    ],
    // Same shape, and it fails the same way: `swiftType` would name the type
    // `Measurement<null>`, which is a compile error in a file the user cannot
    // edit rather than a message here.
    ParamType.measurement when dimension == null => [
      _wrongSlot(intentId, 'a measurement', 'dimension'),
    ],
    ParamType.entity || ParamType.enum_ || ParamType.measurement => const [],
    _
        when entityTypeName != null ||
            enumTypeName != null ||
            dimension != null =>
      [
        'Parameter "$name" of intent "$intentId" is a ${type.name} but carries '
            'a type name or dimension, which nothing downstream will read.',
      ],
    _ => const [],
  };

  String _wrongSlot(String intentId, String kind, String field) =>
      'Parameter "$name" of intent "$intentId" is $kind but has no $field. '
      'The generated code would name a type called "null".';

  Map<String, Object?> toJson() => {
    'name': name,
    'title': title,
    'type': type.name,
    if (entityTypeName != null) 'entityTypeName': entityTypeName,
    if (enumTypeName != null) 'enumTypeName': enumTypeName,
    if (dimension != null) 'dimension': dimension!.name,
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
    enumTypeName: j['enumTypeName'] as String?,
    dimension: switch (j['dimension']) {
      final String name => MeasurementDimension.values.byName(name),
      _ => null,
    },
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
    this.confirmBeforeRunning,
    this.returnType,
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

  /// Prompt the system shows before running anything, when set.
  ///
  /// Compile-time, like [openAppWhenRun] and unlike anything a handler could
  /// return: `perform()` asks before it calls into Dart, so a refusal means the
  /// handler never ran.
  final String? confirmBeforeRunning;

  /// What the handler hands back for the next step of a Shortcut, if anything.
  ///
  /// Part of `perform()`'s Swift signature, which is why it is declared rather
  /// than inferred — see [AppIntent.returns].
  final ParamType? returnType;

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
      ? [
          for (final p in params)
            if (p.isRequired) p.name,
        ]
      : const [];

  /// Resource name for this intent's label strings.
  ///
  /// `shortcutShortLabel` will not take a literal, so every shortcut drags a
  /// `values` entry along with it and the two files have to agree on the name.
  String get androidLabelResource => 'os_intents_${id}_label';

  /// Parameters `androidx.appfunctions` has no way to express.
  ///
  /// Only files so far, and it is not an oversight on either side: Android
  /// hands an agent a content URI and a grant rather than the bytes, which is a
  /// different model rather than a missing feature. Reported rather than
  /// silently coerced — a `String` parameter called `document` would look like
  /// it worked.
  List<String> get androidUnsupportedParams => [
    for (final p in params)
      if (!p.type.hasAndroidCounterpart) p.name,
  ];

  /// Whether this intent can be offered to an on-device agent.
  ///
  /// Two conditions, both hard: it must not need an Activity, and every
  /// parameter must be expressible. Either one failing leaves it out of the
  /// AppFunctions surface entirely — the app shortcut layer is unaffected.
  bool get canBeAppFunction =>
      needsHeadlessEngine && androidUnsupportedParams.isEmpty;

  /// Whether this intent can end up needing the headless Dart engine.
  ///
  /// True for background, and also for static: a static intent whose value has
  /// not been published yet falls back to running the handler rather than
  /// answering with silence.
  bool get needsHeadlessEngine => execution != ExecutionMode.foreground;

  /// PascalCase name of the generated Swift struct.
  String get swiftTypeName =>
      '${id[0].toUpperCase()}${id.substring(1)}OsIntent';

  String get titleKey => '$id.title';
  String get descriptionKey => '$id.description';
  String get confirmKey => '$id.confirm';

  /// Everything about this action a user could read or hear, except its
  /// phrases.
  ///
  /// Phrases are not here because they cannot be keyed: `AppShortcutPhrase` is
  /// `ExpressibleByStringInterpolation` over a plain `String`, with no
  /// `LocalizedStringResource` initialiser at all. Apple localises them through
  /// a table named `AppShortcuts` whose keys *are* the English phrases, which is
  /// a different mechanism and gets a different file.
  List<LocalisableString> get localisableStrings => [
    LocalisableString(
      key: titleKey,
      value: title,
      comment: 'Name of the "$id" action, shown in Shortcuts and Spotlight.',
    ),
    if (description case final d?)
      LocalisableString(
        key: descriptionKey,
        value: d,
        comment:
            'Explanation of the "$id" action, shown in the Shortcuts '
            'editor.',
      ),
    if (confirmBeforeRunning case final c?)
      LocalisableString(
        key: confirmKey,
        value: c,
        comment: 'Asked before "$id" runs at all. The user may say no.',
      ),
    for (final p in params) ...p.localisableStrings(id),
  ];

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
    if (execution == ExecutionMode.static_ && confirmBeforeRunning != null) {
      problems.add(
        'Intent "$id" is Execution.static_ but asks for confirmation. A static '
        'intent exists to answer instantly from published state with nothing '
        'running, and it has no side effect to guard — the prompt would cost '
        'the only thing that mode buys.',
      );
    }
    if (returnType != null && !returnType!.canReturn) {
      problems.add(
        'Intent "$id" declares `returns: ${returnType!.dart}`, which cannot be '
        'handed to the next Shortcut step.',
      );
    }
    for (final p in params) {
      problems.addAll(p.validate(id));
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
    if (confirmBeforeRunning != null)
      'confirmBeforeRunning': confirmBeforeRunning,
    if (returnType != null) 'returnType': returnType!.name,
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
    confirmBeforeRunning: j['confirmBeforeRunning'] as String?,
    returnType: switch (j['returnType']) {
      final String name => ParamType.values.byName(name),
      _ => null,
    },
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

/// One case of an `@AppEnum`.
class EnumValueSpec {
  EnumValueSpec({required this.name, required this.title});

  /// The Dart constant's own name. This is what crosses the wire, so renaming
  /// a constant breaks shortcuts users already built — same rule as an intent
  /// id.
  final String name;

  /// What the system shows for it.
  final String title;

  Map<String, Object?> toJson() => {'name': name, 'title': title};

  static EnumValueSpec fromJson(Map<String, Object?> j) =>
      EnumValueSpec(name: j['name']! as String, title: j['title']! as String);
}

/// A Dart enum offered to the system as a fixed set of choices.
///
/// The closed counterpart of [EntitySpec]: no query, no callback, no running
/// app, because every case is known when the code is generated.
class EnumSpec {
  EnumSpec({
    required this.typeName,
    required this.dartClassName,
    required this.values,
    this.displayName,
  });

  final String typeName;
  final String dartClassName;
  final String? displayName;
  final List<EnumValueSpec> values;

  String get swiftTypeName => '${typeName}Enum';

  String get displayNameKey => 'enum.$typeName';
  String valueKey(EnumValueSpec v) => 'enum.$typeName.${v.name}';

  List<LocalisableString> get localisableStrings => [
    LocalisableString(
      key: displayNameKey,
      value: displayName ?? typeName,
      comment: 'Name of the "$typeName" set of choices.',
    ),
    for (final v in values)
      LocalisableString(
        key: valueKey(v),
        value: v.title,
        comment: 'One choice in "$typeName".',
      ),
  ];

  List<String> validate() => [
    if (values.isEmpty)
      'Enum "$typeName" has no values, so nothing could ever be chosen.',
  ];

  Map<String, Object?> toJson() => {
    'typeName': typeName,
    'dartClassName': dartClassName,
    if (displayName != null) 'displayName': displayName,
    'values': [for (final v in values) v.toJson()],
  };

  static EnumSpec fromJson(Map<String, Object?> j) => EnumSpec(
    typeName: j['typeName']! as String,
    dartClassName: j['dartClassName']! as String,
    displayName: j['displayName'] as String?,
    values: [
      for (final v in (j['values'] as List? ?? const []))
        EnumValueSpec.fromJson((v as Map).cast<String, Object?>()),
    ],
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

  String get displayNameKey => 'entity.$typeName';

  List<LocalisableString> get localisableStrings => [
    LocalisableString(
      key: displayNameKey,
      value: displayName ?? typeName,
      comment: 'Name of the "$typeName" kind of object.',
    ),
  ];

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
    this.enums = const [],
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

  /// Fixed sets of choices. Closed, so unlike [entities] they need no query.
  final List<EnumSpec> enums;

  static const int formatVersion = 1;

  /// Library the background engine must start, or null when nothing needs it.
  ///
  /// `FlutterEngine.run(withEntrypoint:libraryURI:)` needs this: the entrypoint
  /// is not in `main.dart`, and without the URI the engine looks only there and
  /// fails to start with nothing but a `false`.
  String? get entrypointLibraryUri => hasBackgroundIntents ? libraryUri : null;

  /// Every string the generated Swift looks up by key, in a stable order.
  ///
  /// Not the phrases — see [IntentSpec.localisableStrings] for why they cannot
  /// be keyed and [phrases] for where they go instead.
  List<LocalisableString> get localisableStrings => [
    for (final i in intents) ...i.localisableStrings,
    for (final e in enums) ...e.localisableStrings,
    for (final e in entities) ...e.localisableStrings,
  ];

  /// Spoken phrases, which are their own table keyed by the English text.
  List<String> get phrases => [for (final i in intents) ...i.phrases];

  List<String> validate() => [
    for (final i in intents) ...i.validate(),
    for (final e in entities) ...e.validate(),
    for (final e in enums) ...e.validate(),
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
    if (enums.isNotEmpty) 'enums': [for (final e in enums) e.toJson()],
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
      enums: [
        for (final e in (j['enums'] as List? ?? const []))
          EnumSpec.fromJson((e as Map).cast<String, Object?>()),
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
      enums: [for (final p in list) ...p.enums],
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
