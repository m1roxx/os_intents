import 'dart:convert';

import 'package:os_intents_cli/src/actions_data.dart';
import 'package:os_intents_cli/src/doctor.dart';
import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:test/test.dart';

// ── what Dart declared ───────────────────────────────────────────────────────

Manifest declared({
  List<IntentSpec> intents = const [],
  List<EntitySpec> entities = const [],
}) => Manifest(
  source: 'os_intents_example|lib/intents.dart',
  intents: intents,
  entities: entities,
);

IntentSpec intent({
  String id = 'addTask',
  String title = 'Add task',
  List<String> phrases = const [],
  ExecutionMode execution = ExecutionMode.foreground,
  List<ParamSpec> params = const [],
  bool showsInSpotlight = true,
}) => IntentSpec(
  id: id,
  functionName: id,
  title: title,
  execution: execution,
  phrases: phrases,
  params: params,
  showsInSpotlight: showsInSpotlight,
);

ParamSpec param(String name, {bool required = true}) =>
    ParamSpec(name: name, title: name, type: ParamType.string, isRequired: required);

EntitySpec entity({String typeName = 'Project', bool hasQuery = true}) =>
    EntitySpec(
      typeName: typeName,
      dartClassName: '${typeName}Entity',
      idProperty: 'id',
      hasQuery: hasQuery,
      properties: [
        EntityPropertySpec(name: 'name', type: ParamType.string, isTitle: true),
      ],
    );

// ── what the bundle carries ──────────────────────────────────────────────────

/// Builds metadata the way Xcode writes it, so these tests exercise the real
/// parser rather than a hand-built model that could drift from it.
AppIntentsMetadata shipped({
  List<Map<String, Object?>> actions = const [],
  List<String> entities = const [],
  Map<String, List<String>> shortcuts = const {},
  String? provider = '6Runner18OsIntentsShortcutsV',
  bool entitiesHaveQueries = true,
}) => AppIntentsMetadata.parse(
  jsonEncode({
    'actions': {for (final a in actions) a['identifier']!: a},
    'entities': {
      for (final e in entities)
        e: {
          'typeName': e,
          if (entitiesHaveQueries) 'defaultQueryIdentifier': 'Runner.${e}Query',
        },
    },
    'queries': {
      if (entitiesHaveQueries)
        for (final e in entities)
          '${e}Query': {'identifier': '${e}Query', 'entityType': e},
    },
    'autoShortcuts': [
      for (final e in shortcuts.entries)
        {
          'actionIdentifier': e.key,
          'phraseTemplates': [for (final p in e.value) {'key': p}],
        },
    ],
    'autoShortcutProviderMangledName': ?provider,
  }),
);

Map<String, Object?> action(
  String identifier, {
  List<Map<String, Object?>> params = const [],
  bool opensApp = false,
  bool discoverable = true,
}) => {
  'identifier': identifier,
  'openAppWhenRun': opensApp,
  'visibilityMetadata': {'isDiscoverable': discoverable},
  'parameters': params,
};

Map<String, Object?> shippedParam(String name, {bool optional = false}) => {
  'name': name,
  'isOptional': optional,
  'valueType': {
    'primitive': {
      'wrapper': {'typeIdentifier': 0},
    },
  },
};

// ── helpers ──────────────────────────────────────────────────────────────────

List<Finding> errorsIn(List<Finding> findings) =>
    findings.where((f) => f.severity == Severity.error).toList();

Matcher saysAll(List<String> fragments) => predicate<List<Finding>>(
  (findings) {
    final text = findings.map((f) => '${f.summary} ${f.detail ?? ''}').join('\n');
    return fragments.every(text.contains);
  },
  'mentions ${fragments.join(", ")}',
);

void main() {
  group('when everything arrived', () {
    test('a matching bundle produces no findings at all', () {
      final findings = diagnose(
        declared: declared(
          intents: [
            intent(
              phrases: [r'Add a task to $app'],
              params: [param('title')],
            ),
          ],
          entities: [entity()],
        ),
        shipped: shipped(
          actions: [
            action('AddTaskOsIntent', params: [shippedParam('title')]),
          ],
          entities: ['ProjectEntity'],
          shortcuts: {
            'AddTaskOsIntent': [r'Add a task to ${applicationName}'],
          },
        ),
        hasSpokenPhraseFile: true,
      );
      expect(findings, isEmpty);
    });
  });

  group('the generated Swift never reached the target', () {
    test('an intent missing from the bundle is an error that says why', () {
      final findings = diagnose(
        declared: declared(intents: [intent()]),
        shipped: shipped(),
        hasSpokenPhraseFile: false,
      );
      expect(errorsIn(findings), hasLength(1));
      expect(findings, saysAll(['addTask', 'Runner target']));
    });

    test('phrases with no provider selected point at the Xcode step', () {
      final findings = diagnose(
        declared: declared(intents: [intent(phrases: [r'Add a task to $app'])]),
        shipped: shipped(
          actions: [action('AddTaskOsIntent')],
          provider: null,
        ),
        hasSpokenPhraseFile: false,
      );
      expect(
        findings,
        saysAll(['No AppShortcutsProvider was selected', 'os_intents install']),
      );
    });
  });

  group('a rival AppShortcutsProvider', () {
    test('is named, because iOS drops the loser in silence', () {
      final findings = diagnose(
        declared: declared(intents: [intent(phrases: [r'Add a task to $app'])]),
        shipped: shipped(
          actions: [action('AddTaskOsIntent')],
          provider: '6Runner11MyShortcutsV',
        ),
        hasSpokenPhraseFile: true,
      );
      expect(errorsIn(findings), isNotEmpty);
      expect(findings, saysAll(['Runner.MyShortcuts', 'exactly one provider']));
    });

    test('is not reported when the app declares no phrases of its own', () {
      final findings = diagnose(
        declared: declared(intents: [intent()]),
        shipped: shipped(
          actions: [action('AddTaskOsIntent')],
          provider: '6Runner11MyShortcutsV',
        ),
        hasSpokenPhraseFile: false,
      );
      expect(errorsIn(findings), isEmpty);
    });
  });

  group('phrases', () {
    test(r'$app is compared against what the extractor writes', () {
      final findings = diagnose(
        declared: declared(intents: [intent(phrases: [r'New $app task'])]),
        shipped: shipped(
          actions: [action('AddTaskOsIntent')],
          shortcuts: {
            'AddTaskOsIntent': [r'New ${applicationName} task'],
          },
        ),
        hasSpokenPhraseFile: true,
      );
      expect(findings, isEmpty);
    });

    test('one phrase reaching the bundle and another not is still an error', () {
      final findings = diagnose(
        declared: declared(
          intents: [
            intent(phrases: [r'Add a task to $app', r'New $app task']),
          ],
        ),
        shipped: shipped(
          actions: [action('AddTaskOsIntent')],
          shortcuts: {
            'AddTaskOsIntent': [r'Add a task to ${applicationName}'],
          },
        ),
        hasSpokenPhraseFile: true,
      );
      expect(errorsIn(findings), hasLength(1));
      expect(findings, saysAll([r'New $app task']));
    });

    test('no root.ssu.yaml means Siri got nothing, and it is reported once', () {
      final findings = diagnose(
        declared: declared(
          intents: [
            intent(id: 'addTask', phrases: [r'Add a task to $app']),
            intent(id: 'dueToday', phrases: [r'What is due in $app']),
          ],
        ),
        shipped: shipped(
          actions: [action('AddTaskOsIntent'), action('DueTodayOsIntent')],
          shortcuts: {
            'AddTaskOsIntent': [r'Add a task to ${applicationName}'],
            'DueTodayOsIntent': [r'What is due in ${applicationName}'],
          },
        ),
        hasSpokenPhraseFile: false,
      );
      expect(
        findings.where((f) => f.summary.contains('root.ssu.yaml')),
        hasLength(1),
      );
    });

    test('an app without phrases does not need root.ssu.yaml', () {
      final findings = diagnose(
        declared: declared(intents: [intent()]),
        shipped: shipped(actions: [action('AddTaskOsIntent')], provider: null),
        hasSpokenPhraseFile: false,
      );
      expect(findings, isEmpty);
    });
  });

  group('entities', () {
    test('an entity that did not ship is an error', () {
      final findings = diagnose(
        declared: declared(entities: [entity()]),
        shipped: shipped(),
        hasSpokenPhraseFile: false,
      );
      expect(findings, saysAll(['Project', 'cannot be resolved']));
    });

    test('an entity that shipped without its query is an error', () {
      final findings = diagnose(
        declared: declared(entities: [entity()]),
        shipped: shipped(
          entities: ['ProjectEntity'],
          entitiesHaveQueries: false,
        ),
        hasSpokenPhraseFile: false,
      );
      expect(findings, saysAll(['@EntityQuery', 'ProjectEntity']));
    });
  });

  group('the bundle disagreeing with the manifest', () {
    test('a background intent that opens the app is an error', () {
      final findings = diagnose(
        declared: declared(
          intents: [intent(execution: ExecutionMode.background)],
        ),
        shipped: shipped(
          actions: [action('AddTaskOsIntent', opensApp: true)],
        ),
        hasSpokenPhraseFile: false,
      );
      expect(errorsIn(findings), hasLength(1));
      expect(findings, saysAll(['opens the app']));
    });

    test('a parameter missing from the bundle is an error', () {
      final findings = diagnose(
        declared: declared(intents: [intent(params: [param('title')])]),
        shipped: shipped(actions: [action('AddTaskOsIntent')]),
        hasSpokenPhraseFile: false,
      );
      expect(findings, saysAll(['title', 'os_intents sync']));
    });

    test('an optionality mismatch is a warning, not an error', () {
      final findings = diagnose(
        declared: declared(
          intents: [
            intent(params: [param('title', required: true)]),
          ],
        ),
        shipped: shipped(
          actions: [
            action(
              'AddTaskOsIntent',
              params: [shippedParam('title', optional: true)],
            ),
          ],
        ),
        hasSpokenPhraseFile: false,
      );
      expect(errorsIn(findings), isEmpty);
      expect(findings.single.severity, Severity.warning);
    });
  });

  group('intents os_intents did not generate', () {
    test('are a note, since an app may write its own', () {
      final findings = diagnose(
        declared: declared(intents: [intent()]),
        shipped: shipped(
          actions: [action('AddTaskOsIntent'), action('HandWrittenIntent')],
        ),
        hasSpokenPhraseFile: false,
      );
      expect(errorsIn(findings), isEmpty);
      expect(findings.single.severity, Severity.note);
      expect(findings, saysAll(['HandWrittenIntent']));
    });
  });

  group('outside a Flutter project', () {
    test('the bundle is described, and nothing is claimed about Dart', () {
      final findings = diagnose(
        declared: null,
        shipped: shipped(actions: [action('AddTaskOsIntent')]),
        hasSpokenPhraseFile: false,
      );
      expect(errorsIn(findings), isEmpty);
      expect(findings.single.severity, Severity.note);
      expect(findings, saysAll(['not a comparison']));
    });
  });
}
