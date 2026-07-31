/// Reads the AppFunction metadata an Android build leaves inside the APK.
///
/// The counterpart of [actions_data.dart] for the other platform, and a much
/// kinder one: where Apple's `extract.actionsdata` is an undocumented binary
/// blob, KSP writes `assets/os_intents_app_functions.xml` as plain XML, stored
/// uncompiled because assets are copied verbatim. So this is real parsing
/// rather than reverse-engineering — but the same rule applies, and for the
/// same reason: the schema belongs to `androidx.appfunctions`, which is alpha
/// and moves. Anything unrecognised is reported as itself rather than guessed
/// at, so a format that has moved on says so instead of quietly reading as
/// something else.
library;

import 'package:xml/xml.dart';

/// Where KSP puts the file. `assets/`, not `res/xml/` — which is why it
/// survives into the APK as text.
const appFunctionsAssetPath = 'assets/os_intents_app_functions.xml';

/// One `@AppFunction` as the agent will see it.
class AppFunctionEntry {
  AppFunctionEntry({
    required this.id,
    required this.description,
    required this.enabledByDefault,
    required this.parameterTypeRef,
    required this.responseTypeRef,
  });

  /// `com.example.app.BaseOsIntentsAppFunctionService#addTask`.
  final String id;

  /// Comes from the KDoc the emitter wrote, which came from Dart.
  final String? description;

  final bool enabledByDefault;

  /// Qualified name of the single params object the function takes.
  final String? parameterTypeRef;

  final String? responseTypeRef;

  /// The bare method name — the part after `#`, which is the intent id.
  String get functionName {
    final hash = id.lastIndexOf('#');
    return hash < 0 ? id : id.substring(hash + 1);
  }
}

/// One property of a serializable object, with its effective optionality.
class AppFunctionProperty {
  AppFunctionProperty({
    required this.name,
    required this.typeCode,
    required this.isNullable,
    required this.listedRequired,
    this.description,
  });

  final String name;
  final int? typeCode;
  final bool isNullable;

  /// Whether the enclosing object lists this property in `<required>`.
  final bool listedRequired;

  final String? description;

  /// What the runtime will actually enforce.
  ///
  /// `AppFunctionDataSpec.isRequired` treats a property as required only when
  /// it is both listed in `<required>` **and** non-nullable — a nullable
  /// required field is optional as far as validation is concerned. The
  /// generated Kotlin lists every property, so reading `<required>` alone
  /// would report optional parameters as mandatory.
  bool get isEffectivelyRequired => listedRequired && !isNullable;

  /// Human name for the type code, or null when the code is not one we have
  /// seen a build produce.
  String? get typeName => appFunctionTypeNames[typeCode];

  String get typeLabel => typeName ?? 'type #$typeCode';
}

/// One `@AppFunctionSerializable` class.
class AppFunctionDataType {
  AppFunctionDataType({
    required this.qualifiedName,
    required this.description,
    required this.properties,
  });

  final String qualifiedName;
  final String? description;
  final List<AppFunctionProperty> properties;
}

/// Type codes, as observed in metadata from a real build.
///
/// Deliberately partial. Only codes seen coming out of a build this toolchain
/// produced are named; everything else prints as `type #N`, which is a signal
/// that either the schema moved or the emitter grew a type this reader has not
/// caught up with.
const appFunctionTypeNames = <int, String>{
  1: 'Boolean',
  3: 'object',
  6: 'Long',
  8: 'String',
  11: 'object reference',
};

/// What the APK says an agent will be offered.
class AppFunctionsMetadata {
  AppFunctionsMetadata({required this.functions, required this.dataTypes});

  final List<AppFunctionEntry> functions;
  final Map<String, AppFunctionDataType> dataTypes;

  /// The params object of [entry], when the metadata describes one.
  AppFunctionDataType? parametersOf(AppFunctionEntry entry) =>
      entry.parameterTypeRef == null ? null : dataTypes[entry.parameterTypeRef];
}

/// Thrown when the file is not something this reader recognises at all.
class AppFunctionsFormatException implements Exception {
  AppFunctionsFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parses the contents of `os_intents_app_functions.xml`.
///
/// Pure: takes the text, returns the model. The caller does the unzipping, so
/// this stays testable against a captured file with no APK in the loop.
AppFunctionsMetadata parseAppFunctionsXml(String source) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(source);
  } on XmlException catch (e) {
    throw AppFunctionsFormatException(
      'not valid XML — the metadata file is corrupt or is not the file it '
      'claims to be: $e',
    );
  }

  final root = doc.rootElement;
  if (root.name.local != 'appfunctions') {
    throw AppFunctionsFormatException(
      'root element is <${root.name.local}>, expected <appfunctions>. The '
      'androidx.appfunctions schema has moved and this reader has not.',
    );
  }

  final functions = [
    for (final e in root.findElements('appfunction'))
      AppFunctionEntry(
        id: _text(e, 'id') ?? _text(e, 'functionId') ?? '(unnamed)',
        description: _text(e, 'description'),
        // Absent reads as enabled: that is the annotation's own default, and
        // reporting "disabled" for a field the schema simply stopped writing
        // would be the wrong kind of wrong.
        enabledByDefault: _text(e, 'enabledByDefault') != 'false',
        parameterTypeRef: e
            .findElements('parameters')
            .expand((p) => p.findElements('dataTypeMetadata'))
            .map((d) => _text(d, 'dataTypeReference'))
            .firstWhere((r) => r != null, orElse: () => null),
        responseTypeRef: e
            .findElements('response')
            .expand((r) => r.findElements('valueType'))
            .map((v) => _text(v, 'dataTypeReference'))
            .firstWhere((r) => r != null, orElse: () => null),
      ),
  ];

  final dataTypes = <String, AppFunctionDataType>{};
  for (final doc_ in root.findElements(
    'AppFunctionComponentMetadataDocument',
  )) {
    for (final entry in doc_.findElements('dataTypes')) {
      final meta = entry.findElements('dataTypeMetadata').firstOrNull;
      if (meta == null) continue;
      final name =
          _text(meta, 'objectQualifiedName') ?? _text(entry, 'name') ?? '';
      if (name.isEmpty) continue;

      final required = meta
          .findElements('required')
          .map((r) => r.innerText.trim())
          .toSet();

      dataTypes[name] = AppFunctionDataType(
        qualifiedName: name,
        description: _text(meta, 'description'),
        properties: [
          for (final prop in meta.findElements('properties'))
            if (_text(prop, 'name') case final propName?)
              AppFunctionProperty(
                name: propName,
                typeCode: _propertyMeta(prop, 'type'),
                isNullable: _propertyMetaText(prop, 'isNullable') == 'true',
                listedRequired: required.contains(propName),
                description: _propertyMetaText(prop, 'description')?.trim(),
              ),
        ],
      );
    }
  }

  return AppFunctionsMetadata(functions: functions, dataTypes: dataTypes);
}

String? _text(XmlElement parent, String tag) {
  final e = parent.findElements(tag).firstOrNull;
  final raw = e?.innerText;
  if (raw == null) return null;
  final trimmed = raw.trim();
  // `unused` is what KSP writes into every id slot it does not populate;
  // surfacing it would be noise dressed up as information.
  return trimmed.isEmpty || trimmed == 'unused' ? null : trimmed;
}

/// A property's own attributes live one level down, in its `dataTypeMetadata`.
String? _propertyMetaText(XmlElement property, String tag) {
  final meta = property.findElements('dataTypeMetadata').firstOrNull;
  if (meta == null) return null;
  return meta.findElements(tag).firstOrNull?.innerText.trim();
}

int? _propertyMeta(XmlElement property, String tag) {
  final raw = _propertyMetaText(property, tag);
  return raw == null ? null : int.tryParse(raw);
}
