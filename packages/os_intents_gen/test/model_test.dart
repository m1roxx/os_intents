import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:test/test.dart';

IntentSpec spec({
  String id = 'addTask',
  String title = 'Add task',
  List<String> phrases = const [],
  ExecutionMode execution = ExecutionMode.foreground,
  List<ParamSpec> params = const [],
}) => IntentSpec(
  id: id,
  functionName: id,
  title: title,
  execution: execution,
  phrases: phrases,
  params: params,
);

ParamSpec param(
  String name, {
  ParamType type = ParamType.string,
  bool required = true,
}) => ParamSpec(
  name: name,
  title: name,
  type: type,
  isRequired: required,
);

void main() {
  group('intent validation', () {
    test('accepts a phrase naming the app', () {
      expect(spec(phrases: [r'Add a task to $app']).validate(), isEmpty);
    });

    test(r'rejects a phrase without the $app placeholder', () {
      // Apple rejects these, but only at App Review — far too late to find out.
      final problems = spec(phrases: ['Add a task']).validate();
      expect(problems, hasLength(1));
      expect(problems.single, contains(r'$app'));
    });

    test('reports every bad phrase, not just the first', () {
      final problems = spec(
        phrases: ['Add a task', r'New $app task', 'Make a task'],
      ).validate();
      expect(problems, hasLength(2));
    });

    test('rejects an empty title', () {
      expect(spec(title: '   ').validate(), hasLength(1));
    });

    test('rejects duplicate parameter names', () {
      final problems = spec(
        params: [param('title'), param('title')],
      ).validate();
      expect(problems.single, contains('twice'));
    });

    test('rejects parameters on a static intent', () {
      // Nothing runs in Dart for a static intent, so there is nowhere for an
      // argument to go.
      final problems = spec(
        execution: ExecutionMode.static_,
        params: [param('title')],
      ).validate();
      expect(problems.single, contains('static'));
    });
  });

  group('manifest', () {
    test('catches duplicate intent ids across libraries', () {
      final merged = Manifest.merge([
        Manifest(source: 'a.dart', intents: [spec()]),
        Manifest(source: 'b.dart', intents: [spec()]),
      ]);
      final problems = merged.validateGlobal();
      expect(problems.single, contains('Duplicate intent id "addTask"'));
    });

    test('round-trips through JSON', () {
      final original = Manifest(
        source: 'lib/intents.dart',
        intents: [
          spec(
            phrases: [r'Add a task to $app'],
            execution: ExecutionMode.background,
            params: [param('title'), param('due', type: ParamType.dateTime)],
          ),
        ],
        entities: [
          EntitySpec(
            typeName: 'Project',
            dartClassName: 'ProjectEntity',
            idProperty: 'id',
            properties: [
              EntityPropertySpec(name: 'name', type: ParamType.string, isTitle: true),
            ],
          ),
        ],
      );

      final restored = Manifest.decode(original.encode());
      expect(restored.intents.single.id, 'addTask');
      expect(restored.intents.single.execution, ExecutionMode.background);
      expect(restored.intents.single.params.map((p) => p.name), [
        'title',
        'due',
      ]);
      expect(restored.entities.single.typeName, 'Project');
      expect(restored.entities.single.properties.single.isTitle, isTrue);
    });

    test('refuses a manifest from a different format version', () {
      const stale = '{"formatVersion": 0, "intents": [], "entities": []}';
      expect(() => Manifest.decode(stale), throwsFormatException);
    });
  });

  group('entity validation', () {
    EntitySpec entity(List<EntityPropertySpec> props) => EntitySpec(
      typeName: 'Project',
      dartClassName: 'ProjectEntity',
      idProperty: 'id',
      properties: props,
    );

    test('requires a title property', () {
      final problems = entity([
        EntityPropertySpec(name: 'name', type: ParamType.string),
      ]).validate();
      expect(problems.single, contains('title'));
    });

    test('rejects two title properties', () {
      final problems = entity([
        EntityPropertySpec(name: 'a', type: ParamType.string, isTitle: true),
        EntityPropertySpec(name: 'b', type: ParamType.string, isTitle: true),
      ]).validate();
      expect(problems.single, contains('more than one'));
    });
  });
}
