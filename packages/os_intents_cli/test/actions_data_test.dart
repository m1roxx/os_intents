import 'dart:io';

import 'package:os_intents_cli/src/actions_data.dart';
import 'package:test/test.dart';

/// Captured from a real build of the example app (Xcode tools 17A324). The
/// format is Apple's and undocumented, so a fixture taken from a bundle that
/// iOS itself indexed is the only trustworthy specification of it.
final _example = AppIntentsMetadata.parse(
  File('test/fixtures/example_extract.actionsdata').readAsStringSync(),
);

void main() {
  group('reading a real bundle', () {
    test('finds every extracted intent', () {
      expect(
        _example.actions.map((a) => a.identifier),
        ['AddTaskOsIntent', 'CompleteTaskOsIntent', 'DueTodayOsIntent'],
      );
    });

    test('reads the authored title and description', () {
      final add = _example.action('AddTaskOsIntent')!;
      expect(add.title, 'Add task');
      expect(add.description, 'Creates a new task in the Inbox');
    });

    test('an intent with no description reports none rather than empty', () {
      expect(_example.action('DueTodayOsIntent')!.description, isNull);
    });

    test('background intents do not open the app', () {
      expect(_example.action('AddTaskOsIntent')!.opensApp, isFalse);
      expect(_example.action('AddTaskOsIntent')!.isDiscoverable, isTrue);
    });

    test('parameters keep their order, optionality and type', () {
      final params = _example.action('AddTaskOsIntent')!.params;
      expect(params.map((p) => p.name), ['title', 'dueDate', 'project']);
      expect(params[0].typeLabel, 'String');
      expect(params[0].isOptional, isFalse);
      expect(params[1].typeLabel, 'Date');
      expect(params[1].isOptional, isTrue);
      expect(params[2].typeLabel, 'ProjectEntity');
      expect(params[2].entityTypeName, 'ProjectEntity');
    });

    test('entities carry the query that resolves them', () {
      final entity = _example.entities.single;
      expect(entity.typeName, 'ProjectEntity');
      expect(entity.displayName, 'Project');
      expect(entity.defaultQueryIdentifier, 'Runner.ProjectQuery');
      expect(_example.queryFor('ProjectEntity')!.identifier, 'ProjectQuery');
    });

    test('phrases are grouped under the intent they invoke', () {
      final add = _example.shortcutFor('AddTaskOsIntent')!;
      expect(add.phrases, [
        r'Add a task to ${applicationName}',
        r'New ${applicationName} task',
      ]);
      expect(add.systemImageName, 'plus.circle');
      // The intent that declares no phrases gets no entry at all — this is
      // exactly what doctor looks for when phrases go missing.
      expect(_example.shortcutFor('CompleteTaskOsIntent'), isNull);
    });

    test('names the provider iOS selected', () {
      expect(_example.providerMangledName, '6Runner18OsIntentsShortcutsV');
      expect(
        demangleSwiftTypeName(_example.providerMangledName!),
        'Runner.OsIntentsShortcuts',
      );
    });
  });

  group('demangling', () {
    test('splits a length-prefixed nominal name', () {
      expect(demangleSwiftTypeName('6Runner13ProjectEntityV'), 'Runner.ProjectEntity');
    });

    test('leaves anything it cannot read alone', () {
      expect(demangleSwiftTypeName('\$sSSN'), '\$sSSN');
      expect(demangleSwiftTypeName('99Runner'), '99Runner');
    });
  });

  group('a format that has moved on', () {
    test('unknown primitive types are reported, not guessed', () {
      final meta = AppIntentsMetadata.parse('''
{"actions":{"X":{"identifier":"X","parameters":[
  {"name":"n","valueType":{"primitive":{"wrapper":{"typeIdentifier":404}}}}]}}}
''');
      expect(meta.action('X')!.params.single.typeLabel, 'type #404');
    });

    test('missing sections read as empty rather than throwing', () {
      final meta = AppIntentsMetadata.parse('{}');
      expect(meta.actions, isEmpty);
      expect(meta.entities, isEmpty);
      expect(meta.autoShortcuts, isEmpty);
      expect(meta.providerMangledName, isNull);
    });

    test('an empty provider name means no provider', () {
      final meta = AppIntentsMetadata.parse(
        '{"autoShortcutProviderMangledName":""}',
      );
      expect(meta.providerMangledName, isNull);
    });

    test('non-JSON fails with a message that names the file', () {
      expect(
        () => AppIntentsMetadata.parse('not json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('extract.actionsdata'),
          ),
        ),
      );
    });
  });
}
