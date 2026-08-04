import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:source_gen/source_gen.dart';

import 'model.dart';

/// A problem in the user's own source. Surfaced by the builder as a build
/// error naming the offending element.
class ParseFailure implements Exception {
  ParseFailure(this.message, {this.element});

  final String message;
  final Element? element;

  @override
  String toString() => message;
}

/// Turns annotated elements into [Manifest] entries.
///
/// Annotations are matched by simple name rather than by resolved library, so
/// the parser does not care how `package:os_intents` was imported.
class SpecParser {
  SpecParser({required this.source});

  final String source;

  final List<IntentSpec> _intents = [];
  final List<EntitySpec> _entities = [];
  final List<EnumSpec> _enums = [];

  Manifest get manifest => Manifest(
    source: source,
    intents: _intents,
    entities: _entities,
    enums: _enums,
  );

  // ── intents ────────────────────────────────────────────────────────────────

  void addIntent(Element element, ConstantReader annotation) {
    if (element is! TopLevelFunctionElement) {
      throw ParseFailure(
        '@AppIntent can only annotate a top-level function; '
        '"${element.displayName}" is not one.',
        element: element,
      );
    }
    final fnName = element.displayName;
    final identifier = annotation.read('identifier');
    final id = identifier.isNull ? fnName : identifier.stringValue;

    _requireFutureOfIntentResult(element, id);

    final executionRaw = annotation.read('execution');
    final execution = executionRaw.isNull
        ? ExecutionMode.foreground
        : ExecutionMode.parse(_dartEnumName(executionRaw.objectValue));

    final phrasesReader = annotation.read('phrases');
    final phrases = phrasesReader.isNull
        ? const <String>[]
        : [for (final v in phrasesReader.listValue) v.toStringValue() ?? ''];

    final spotlight = annotation.read('showsInSpotlight');
    final snippet = annotation.read('showsSnippet');
    final androidShortcut = annotation.read('androidShortcut');
    final returnType = _returnType(annotation, id);

    _intents.add(
      IntentSpec(
        id: id,
        functionName: fnName,
        title: annotation.read('title').stringValue,
        description: _stringOrNull(annotation, 'description'),
        phrases: phrases,
        execution: execution,
        systemImageName: _stringOrNull(annotation, 'systemImageName'),
        showsInSpotlight: spotlight.isNull ? true : spotlight.boolValue,
        showsSnippet: snippet.isNull ? false : snippet.boolValue,
        confirmBeforeRunning: _stringOrNull(annotation, 'confirmBeforeRunning'),
        returnType: returnType,
        androidShortcut: androidShortcut.isNull
            ? true
            : androidShortcut.boolValue,
        androidCapability: _stringOrNull(annotation, 'androidCapability'),
        params: _params(element, id),
      ),
    );
  }

  /// Reads `returns:`, which is a `Type` literal rather than an enum.
  ///
  /// Written as `returns: String` so it reads like ordinary Dart, which means
  /// anything at all can be written there — and App Intents can express only a
  /// handful of types. Refusing here beats emitting Swift that will not build,
  /// and the message can name what is allowed.
  ParamType? _returnType(ConstantReader annotation, String id) {
    final reader = annotation.read('returns');
    if (reader.isNull) return null;

    final name = reader.typeValue.getDisplayString();
    final type = ParamType.fromDart(name);
    if (type == null || !type.canReturn) {
      throw ParseFailure(
        'Intent "$id" declares `returns: $name`, which cannot cross to the '
        'system. A returned value becomes the input of the next Shortcut step, '
        'and only ${_returnableTypes.join(', ')} can be handed over that way. '
        'A Measurement cannot: its Swift type depends on a dimension, and '
        '`returns:` has nowhere to put one.',
      );
    }
    return type;
  }

  static final List<String> _returnableTypes = [
    for (final t in ParamType.values)
      if (t.canReturn) t.dart,
  ];

  void _requireFutureOfIntentResult(TopLevelFunctionElement fn, String id) {
    final name = fn.returnType.getDisplayString();
    if (!name.startsWith('Future<') || !name.contains('IntentResult')) {
      throw ParseFailure(
        'Intent "$id" must return Future<IntentResult>, but returns $name. '
        'The OS waits for the result, so the handler has to be async.',
        element: fn,
      );
    }
  }

  List<ParamSpec> _params(TopLevelFunctionElement fn, String intentId) {
    final specs = <ParamSpec>[];
    for (final p in fn.formalParameters) {
      if (!p.isNamed) {
        throw ParseFailure(
          'Parameter "${p.displayName}" of intent "$intentId" is positional. '
          'Intent parameters must be named — the OS supplies them by name and '
          'in any order.',
          element: p,
        );
      }
      final ann = _annotationNamed(p, 'Param');
      if (ann == null) {
        throw ParseFailure(
          'Parameter "${p.displayName}" of intent "$intentId" has no @Param. '
          'Every parameter needs a title the system can show the user.',
          element: p,
        );
      }
      final reader = ConstantReader(ann);
      final (type, refTypeName) = _paramType(p.type, p.displayName, intentId);
      specs.add(
        ParamSpec(
          name: p.displayName,
          title: reader.read('title').stringValue,
          type: type,
          dimension: _dimension(reader, type, p.displayName, intentId),
          // The two names go in different slots, and putting an enum's into
          // entityTypeName was not a cosmetic mistake: swiftType, the Kotlin
          // value constraint and the Dart decode all read enumTypeName, so all
          // three emitted the word `null` into real source files.
          entityTypeName: type == ParamType.entity ? refTypeName : null,
          enumTypeName: type == ParamType.enum_ ? refTypeName : null,
          isRequired: p.isRequiredNamed,
          description: _stringOrNull(reader, 'description'),
          requestValueDialog: _stringOrNull(reader, 'requestValueDialog'),
          androidCapabilityParameter: _stringOrNull(
            reader,
            'androidCapabilityParameter',
          ),
        ),
      );
    }
    return specs;
  }

  /// Reads `dimension:` off `@Param`, and insists on it exactly where it is
  /// needed.
  ///
  /// A `Measurement` parameter has no Swift type without one — App Intents has
  /// no generic measurement, only one overload per dimension — so this is the
  /// one place the annotation carries something the Dart type cannot.
  MeasurementDimension? _dimension(
    ConstantReader param,
    ParamType type,
    String pName,
    String iId,
  ) {
    final reader = param.read('dimension');
    final declared = reader.isNull
        ? null
        : MeasurementDimension.byName(_dartEnumName(reader.objectValue));

    if (type == ParamType.measurement && declared == null) {
      throw ParseFailure(
        'Parameter "$pName" of intent "$iId" is a Measurement but declares no '
        'dimension. The system asks for a quantity with a unit picker, and '
        'which picker is fixed when the code is generated — write '
        "@Param(title: …, dimension: Dimension.length).",
      );
    }
    if (type != ParamType.measurement && declared != null) {
      throw ParseFailure(
        'Parameter "$pName" of intent "$iId" declares a dimension but is a '
        '${type.dart}, not a Measurement. Nothing downstream would read it.',
      );
    }
    return declared;
  }

  (ParamType, String?) _paramType(DartType type, String pName, String iId) {
    final display = type
        .getDisplayString()
        .replaceAll('?', '')
        .split('<')
        .first
        .trim();

    final primitive = ParamType.fromDart(display);
    if (primitive != null) return (primitive, null);

    if (type is InterfaceType) {
      final entityAnn = _annotationNamed(type.element, 'AppEntity');
      if (entityAnn != null) {
        return (
          ParamType.entity,
          ConstantReader(entityAnn).read('typeName').stringValue,
        );
      }
      final enumAnn = _annotationNamed(type.element, 'AppEnum');
      if (enumAnn != null) {
        _collectEnum(type.element, ConstantReader(enumAnn));
        return (
          ParamType.enum_,
          ConstantReader(enumAnn).read('typeName').stringValue,
        );
      }
      // A bare Dart enum is the mistake worth naming, because it looks like it
      // should just work and the fix is one annotation.
      if (type.element is EnumElement) {
        throw ParseFailure(
          'Parameter "$pName" of intent "$iId" takes the enum $display, which '
          'is not annotated. Add @AppEnum(typeName: \'$display\') to it so '
          'the system knows what the choices are called.',
        );
      }
    }

    throw ParseFailure(
      'Parameter "$pName" of intent "$iId" has unsupported type $display. '
      'Use ${_plainTypes.join(', ')}, a class annotated with @AppEntity, or an '
      'enum annotated with @AppEnum.',
    );
  }

  static final List<String> _plainTypes = [
    for (final t in ParamType.values)
      if (t != ParamType.entity && t != ParamType.enum_) t.dart,
  ];

  // ── enums ──────────────────────────────────────────────────────────────────

  /// Records an `@AppEnum` the first time a parameter refers to it.
  ///
  /// Collected from use rather than from a separate builder pass: an enum with
  /// no parameter taking it has nothing to appear in, and emitting a type
  /// nobody can choose would just be noise in the Shortcuts editor.
  void _collectEnum(InterfaceElement element, ConstantReader annotation) {
    final typeName = annotation.read('typeName').stringValue;
    if (_enums.any((e) => e.typeName == typeName)) return;

    final values = <EnumValueSpec>[];
    for (final field in element.fields) {
      if (!field.isEnumConstant) continue;
      final valueAnn = _annotationNamed(field, 'AppEnumValue');
      values.add(
        EnumValueSpec(
          name: field.displayName,
          title: valueAnn == null
              ? _humanise(field.displayName)
              : ConstantReader(valueAnn).read('title').stringValue,
        ),
      );
    }

    _enums.add(
      EnumSpec(
        typeName: typeName,
        dartClassName: element.displayName,
        displayName: _stringOrNull(annotation, 'displayName'),
        values: values,
      ),
    );
  }

  /// `veryUrgent` reads badly in a picker; `Very urgent` does not.
  static String _humanise(String name) {
    final spaced = name.replaceAllMapped(
      RegExp('([a-z0-9])([A-Z])'),
      (m) => '${m[1]} ${m[2]!.toLowerCase()}',
    );
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  // ── entities ───────────────────────────────────────────────────────────────

  void addEntity(Element element, ConstantReader annotation) {
    if (element is! ClassElement) {
      throw ParseFailure(
        '@AppEntity can only annotate a class.',
        element: element,
      );
    }
    final typeName = annotation.read('typeName').stringValue;

    String? idProperty;
    final props = <EntityPropertySpec>[];

    for (final field in element.fields) {
      // Synthetic fields — the ones a bare getter or setter induces — are not
      // filtered out here: they carry no metadata of their own, so the two
      // annotation lookups below skip them anyway. `isSynthetic` is spelled
      // differently in each analyzer major, and the dependency spans several.
      if (field.isStatic) continue;

      if (_annotationNamed(field, 'EntityId') != null) {
        if (idProperty != null) {
          throw ParseFailure(
            'Entity "$typeName" marks more than one property with @EntityId.',
            element: field,
          );
        }
        idProperty = field.displayName;
        continue;
      }

      final display = _annotationNamed(field, 'EntityDisplay');
      if (display == null) continue;
      final reader = ConstantReader(display);
      props.add(
        EntityPropertySpec(
          name: field.displayName,
          type:
              ParamType.fromDart(
                field.type.getDisplayString().replaceAll('?', ''),
              ) ??
              ParamType.string,
          isTitle: _boolOr(reader, 'title', false),
          isSubtitle: _boolOr(reader, 'subtitle', false),
        ),
      );
    }

    if (idProperty == null) {
      throw ParseFailure(
        'Entity "$typeName" has no @EntityId property. The system needs a '
        'stable identifier to refer to the object later.',
        element: element,
      );
    }

    _entities.add(
      EntitySpec(
        typeName: typeName,
        dartClassName: element.displayName,
        idProperty: idProperty,
        displayName: _stringOrNull(annotation, 'displayName'),
        properties: props,
      ),
    );
  }

  /// Links an `@EntityQuery(Foo)` class to the entity it resolves.
  ///
  /// Must run after every [addEntity] for the same library.
  void addQuery(Element element, ConstantReader annotation) {
    if (element is! ClassElement) {
      throw ParseFailure(
        '@EntityQuery can only annotate a class.',
        element: element,
      );
    }
    final targetReader = annotation.read('entityType');
    final targetName = targetReader.isNull
        ? '<null>'
        : targetReader.typeValue.getDisplayString();

    final idx = _entities.indexWhere((e) => e.dartClassName == targetName);
    if (idx < 0) {
      throw ParseFailure(
        '@EntityQuery($targetName) on "${element.displayName}" does not match '
        'any @AppEntity class in this library.',
        element: element,
      );
    }
    final e = _entities[idx];
    _entities[idx] = EntitySpec(
      typeName: e.typeName,
      dartClassName: e.dartClassName,
      idProperty: e.idProperty,
      displayName: e.displayName,
      properties: e.properties,
      hasQuery: true,
      queryClassName: element.displayName,
    );
  }
}

// ── helpers ──────────────────────────────────────────────────────────────────

DartObject? _annotationNamed(Element element, String name) {
  for (final a in element.metadata.annotations) {
    final value = a.computeConstantValue();
    if (value?.type?.getDisplayString() == name) return value;
  }
  return null;
}

String? _stringOrNull(ConstantReader r, String field) {
  final v = r.read(field);
  return v.isNull ? null : v.stringValue;
}

bool _boolOr(ConstantReader r, String field, bool fallback) {
  final v = r.read(field);
  return v.isNull ? fallback : v.boolValue;
}

/// Reads the name of an enum constant without depending on analyzer internals
/// beyond the synthetic `_name` field every enum value carries.
String _dartEnumName(DartObject value) {
  final name = value.getField('_name')?.toStringValue();
  if (name != null) return name;
  // `_name` is synthetic and its spelling has moved between analyzer majors,
  // which this package deliberately spans. The printed form carries the
  // constant as the last dotted identifier in it.
  final matches = RegExp(r'\.(\w+)').allMatches(value.toString());
  if (matches.isNotEmpty) return matches.last.group(1)!;
  throw ParseFailure('Could not read an enum constant from $value.');
}
