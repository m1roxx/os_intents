import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'emit_dart.dart';
import 'parser.dart';

/// Entry point referenced from `build.yaml`.
Builder osIntentsBuilder(BuilderOptions options) => OsIntentsBuilder();

/// Produces two outputs per annotated library:
///
///   `*.os_intents.g.dart`  the registry `OsIntents.install()` consumes
///   `*.os_intents.json`    the manifest `os_intents_cli sync` turns into Swift
///
/// The split exists because `build_runner` derives output paths from input
/// paths and therefore cannot write into `ios/`. The CLI bridges that gap.
class OsIntentsBuilder implements Builder {
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.os_intents.g.dart', '.os_intents.json'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (!await buildStep.resolver.isLibrary(buildStep.inputId)) return;

    final library = LibraryReader(await buildStep.inputLibrary);
    final parser = SpecParser(source: buildStep.inputId.toString());

    // Entities first: a parameter typed as an entity, and every @EntityQuery,
    // resolve against what has already been parsed.
    final annotated = library.allElements.toList();

    try {
      for (final element in annotated) {
        final entity = _readAnnotation(element, 'AppEntity');
        if (entity != null) parser.addEntity(element, entity);
      }
      for (final element in annotated) {
        final query = _readAnnotation(element, 'EntityQuery');
        if (query != null) parser.addQuery(element, query);
      }
      for (final element in annotated) {
        final intent = _readAnnotation(element, 'AppIntent');
        if (intent != null) parser.addIntent(element, intent);
      }
    } on ParseFailure catch (e) {
      throw InvalidGenerationSourceError(e.message, element: e.element);
    }

    final manifest = parser.manifest;
    if (manifest.intents.isEmpty && manifest.entities.isEmpty) return;

    // Entity use is checked here as well as in the CLI, because an entity and
    // the intent taking it almost always sit in the same library — failing at
    // build time beats failing later with a type error in generated code.
    final problems = [...manifest.validate(), ...manifest.validateEntityUse()];
    if (problems.isNotEmpty) {
      throw InvalidGenerationSourceError(
        'os_intents found ${problems.length} problem(s) in '
        '${buildStep.inputId.path}:\n  ${problems.join('\n  ')}',
      );
    }

    final part = buildStep.inputId.pathSegments.last;
    final dart = StringBuffer()
      ..writeln('// dart format off')
      ..writeln('// ignore_for_file: type=lint, unused_element')
      ..writeln()
      ..writeln("part of '$part';")
      ..writeln()
      ..write(emitDartRegistry(manifest))
      ..write(emitBackgroundEntrypoint(manifest))
      ..write(emitDartHelpers(manifest));

    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.os_intents.g.dart'),
      dart.toString(),
    );
    await buildStep.writeAsString(
      buildStep.inputId.changeExtension('.os_intents.json'),
      manifest.encode(),
    );

    log.info(
      'os_intents: ${manifest.intents.length} intent(s), '
      '${manifest.entities.length} entity(ies) from ${buildStep.inputId.path}',
    );
  }
}

/// Reads an annotation off [element] by simple name.
///
/// Matching by name rather than by resolved type keeps the builder working no
/// matter how the user imported `package:os_intents`.
ConstantReader? _readAnnotation(Element element, String name) {
  for (final annotation in element.metadata.annotations) {
    final value = annotation.computeConstantValue();
    if (value?.type?.getDisplayString() == name) {
      return ConstantReader(value);
    }
  }
  return null;
}
