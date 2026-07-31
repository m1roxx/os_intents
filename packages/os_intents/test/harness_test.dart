import 'package:flutter_test/flutter_test.dart';
import 'package:os_intents/os_intents.dart';

/// Stands in for what `os_intents_gen` will emit.
final registry = IntentRegistry({
  'addTask': IntentBinding(
    id: 'addTask',
    invoke: (args) async {
      final title = args['title'] as String?;
      if (title == null || title.isEmpty) {
        throw ArgumentError('title is required');
      }
      return IntentResult.dialog('Added "$title"');
    },
  ),
  'dueToday': IntentBinding(
    id: 'dueToday',
    invoke: (_) async => const IntentResult.snippet(
      SnippetSpec(title: 'Due today', subtitle: '3 tasks'),
    ),
  ),
});

void main() {
  late IntentHarness harness;

  setUp(() => harness = IntentHarness(registry));

  test('invokes a handler and returns its result', () async {
    final result = await harness.invoke('addTask', {'title': 'Buy milk'});
    expect(result, isA<DialogResult>());
    expect((result as DialogResult).spoken, 'Added "Buy milk"');
  });

  test('exposes registered ids so renames fail CI', () {
    // A renamed handler silently orphans shortcuts users already built; nothing
    // else in the toolchain warns about it.
    expect(harness.registeredIds, ['addTask', 'dueToday']);
  });

  test('unknown id names the ids that do exist', () {
    expect(
      () => harness.invoke('nope'),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('addTask'),
        ),
      ),
    );
  });

  test('handler errors propagate to the caller', () {
    expect(
      () => harness.invoke('addTask', {'title': ''}),
      throwsA(isA<ArgumentError>()),
    );
  });

  group('wire format', () {
    test('dialog carries both spoken and displayed text', () {
      const r = IntentResult.dialog('spoken', displayed: 'shown');
      expect(r.toWire(), {
        'kind': 'dialog',
        'spoken': 'spoken',
        'displayed': 'shown',
      });
    });

    test('value carries what the generated Swift reads back', () {
      // The Swift side pulls `value` out of this map and coerces it to the
      // type the annotation declared. Rename the key here and nothing fails
      // until a Shortcut hands the next step an empty string.
      expect(const IntentResult.value(3).toWire(), {
        'kind': 'value',
        'value': 3,
        'spoken': null,
      });
      expect(
        const IntentResult.value('done', spoken: 'All set').toWire()['spoken'],
        'All set',
      );
    });

    test('snippet flattens rows', () {
      const r = IntentResult.snippet(
        SnippetSpec(title: 'Due today', rows: [SnippetRow('Open', '3')]),
      );
      final wire = r.toWire();
      expect(wire['kind'], 'snippet');
      final spec = wire['spec']! as Map<String, Object?>;
      expect(spec['title'], 'Due today');
      expect(spec['rows'], [
        {'label': 'Open', 'value': '3'},
      ]);
    });
  });
}
