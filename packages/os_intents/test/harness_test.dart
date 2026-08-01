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

    test('a card with no buttons carries no actions key', () {
      // Every card before this had none, and the Swift side reads the key as
      // absent-or-list — an empty list would be a second way to say the same
      // thing.
      const r = IntentResult.snippet(SnippetSpec(title: 'Due today'));
      final spec = r.toWire()['spec']! as Map<String, Object?>;
      expect(spec.containsKey('actions'), isFalse);
    });

    test('a button carries its intent id and values, converted', () {
      // The values go to the same generated decoder a donation feeds, so they
      // are converted the same way: millis UTC for a date, the constant's own
      // name for an enum.
      final r = IntentResult.snippet(
        SnippetSpec(
          title: 'Due today',
          actions: [
            SnippetAction(
              label: 'Complete',
              intentId: 'completeTask',
              systemImageName: 'checkmark',
              args: {
                'taskId': 't1',
                'when': DateTime.utc(2026, 8, 1),
                'priority': _Priority.high,
              },
            ),
          ],
        ),
      );
      final spec = r.toWire()['spec']! as Map<String, Object?>;
      final action = (spec['actions']! as List).single as Map<String, Object?>;
      expect(action['label'], 'Complete');
      expect(action['intentId'], 'completeTask');
      expect(action['systemImageName'], 'checkmark');
      final args = action['args']! as Map<String, Object?>;
      expect(args['taskId'], 't1');
      expect(args['when'], DateTime.utc(2026, 8, 1).millisecondsSinceEpoch);
      expect(args['priority'], 'high');
    });
  });
}

enum _Priority { high }
