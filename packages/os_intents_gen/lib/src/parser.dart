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

  Manifest get manifest =>
      Manifest(source: source, intents: _intents, entities: _entities);

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
        : ExecutionMode.parse(_enumName(executionRaw.objectValue));

    final phrasesReader = annotation.read('phrases');
    final phrases = phrasesReader.isNull
        ? const <String>[]
        : [for (final v in phrasesReader.listValue) v.toStringValue() ?? ''];

    final spotlight = annotation.read('showsInSpotlight');
    final snippet = annotation.read('showsSnippet');
    final androidShortcut = annotation.read('androidShortcut');

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
        androidShortcut: androidShortcut.isNull
            ? true
            : androidShortcut.boolValue,
        androidCapability: _stringOrNull(annotation, 'androidCapability'),
        params: _params(element, id),
      ),
    );
  }

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
      final (type, entityTypeName) = _paramType(
        p.type,
        p.displayName,
        intentId,
      );
      specs.add(
        ParamSpec(
          name: p.displayName,
          title: reader.read('title').stringValue,
          type: type,
          entityTypeName: entityTypeName,
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
    }

    throw ParseFailure(
      'Parameter "$pName" of intent "$iId" has unsupported type $display. '
      'Use String, int, double, bool, DateTime, or a class annotated with '
      '@AppEntity.',
    );
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
      if (field.isStatic || field.isSynthetic) continue;

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
String _enumName(DartObject value) {
  final name = value.getField('_name')?.toStringValue();
  if (name != null) return name;
  final match = RegExp(r'\bExecution\.(\w+)').firstMatch(value.toString());
  if (match != null) return match.group(1)!;
  throw ParseFailure('Could not read the Execution value from $value.');
}
