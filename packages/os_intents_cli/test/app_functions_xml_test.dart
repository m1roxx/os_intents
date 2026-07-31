import 'dart:io';

import 'package:os_intents_cli/src/app_functions_xml.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Captured from an APK the Android probe actually built, not hand-written.
/// The schema is androidx.appfunctions', and it is alpha — a fixture from a
/// real build is the only thing that keeps this reader honest.
String get _fixture => File(
  p.join('test', 'fixtures', 'example_app_functions.xml'),
).readAsStringSync();

void main() {
  group('reading a real build', () {
    late AppFunctionsMetadata meta;

    setUpAll(() => meta = parseAppFunctionsXml(_fixture));

    test('finds every function the agent will be offered', () {
      expect(
        meta.functions.map((f) => f.functionName),
        containsAll(['addTask', 'dueToday']),
      );
    });

    test('carries the description written in Dart all the way through', () {
      // This is the whole point of the check: the prose starts as a Dart
      // annotation, becomes KDoc, and only the APK can say it arrived.
      final addTask = meta.functions.firstWhere(
        (f) => f.functionName == 'addTask',
      );
      expect(addTask.description, 'Creates a new task in the Inbox');
      expect(addTask.enabledByDefault, isTrue);
    });

    test('resolves the params object a function takes', () {
      final addTask = meta.functions.firstWhere(
        (f) => f.functionName == 'addTask',
      );
      final params = meta.parametersOf(addTask);
      expect(params, isNotNull);
      expect(params!.properties.map((p) => p.name), ['title', 'dueDate']);
    });

    test('names the types it has seen a build produce', () {
      final params = meta.parametersOf(
        meta.functions.firstWhere((f) => f.functionName == 'addTask'),
      )!;
      final byName = {for (final p in params.properties) p.name: p};
      expect(byName['title']!.typeLabel, 'String');
      // DateTime crosses as epoch milliseconds, so Long on this side.
      expect(byName['dueDate']!.typeLabel, 'Long');
    });

    test('an optional parameter is not reported as required', () {
      // The generated Kotlin lists every property in <required>, so reading
      // that element alone would call dueDate mandatory. The runtime does not:
      // a nullable field is optional however it is listed.
      final params = meta.parametersOf(
        meta.functions.firstWhere((f) => f.functionName == 'addTask'),
      )!;
      final byName = {for (final p in params.properties) p.name: p};

      expect(byName['dueDate']!.listedRequired, isTrue);
      expect(byName['dueDate']!.isNullable, isTrue);
      expect(byName['dueDate']!.isEffectivelyRequired, isFalse);

      expect(byName['title']!.isEffectivelyRequired, isTrue);
    });

    test('drops the placeholder KSP writes into unpopulated slots', () {
      // Every <id> in the file reads "unused"; surfacing it would be noise
      // dressed up as information.
      final dueToday = meta.functions.firstWhere(
        (f) => f.functionName == 'dueToday',
      );
      expect(dueToday.id, isNot(contains('unused')));
    });
  });

  group('a format that has moved on', () {
    test('an unknown type code is reported, not guessed', () {
      final meta = parseAppFunctionsXml('''
<?xml version="1.0" encoding="UTF-8"?>
<appfunctions>
  <AppFunctionComponentMetadataDocument>
    <dataTypes>
      <dataTypeMetadata>
        <objectQualifiedName>com.example.Params</objectQualifiedName>
        <properties>
          <dataTypeMetadata><isNullable>false</isNullable><type>97</type></dataTypeMetadata>
          <name>mystery</name>
        </properties>
        <required>mystery</required>
      </dataTypeMetadata>
      <name>com.example.Params</name>
    </dataTypes>
  </AppFunctionComponentMetadataDocument>
</appfunctions>
''');
      final prop = meta.dataTypes['com.example.Params']!.properties.single;
      expect(prop.typeName, isNull);
      expect(prop.typeLabel, 'type #97');
    });

    test('a different root element fails with a message that says so', () {
      expect(
        () => parseAppFunctionsXml('<?xml version="1.0"?><functions/>'),
        throwsA(
          isA<AppFunctionsFormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('<functions>'), contains('appfunctions')),
          ),
        ),
      );
    });

    test('non-XML fails with a message that names the problem', () {
      expect(
        () => parseAppFunctionsXml('not xml at all'),
        throwsA(isA<AppFunctionsFormatException>()),
      );
    });

    test('no functions at all parses as empty rather than throwing', () {
      final meta = parseAppFunctionsXml(
        '<?xml version="1.0"?><appfunctions></appfunctions>',
      );
      expect(meta.functions, isEmpty);
      expect(meta.dataTypes, isEmpty);
    });
  });
}
