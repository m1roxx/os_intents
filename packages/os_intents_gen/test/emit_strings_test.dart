/// The catalogue is the one generated file that is not ours to overwrite.
///
/// Every other emitter here writes what the manifest says and replaces
/// whatever was on disk. A String Catalogue holds translations that came from a
/// person — often a paid one — so the merge is the whole feature, and losing a
/// translation is the failure this file exists to make impossible.
library;

import 'dart:convert';

import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:test/test.dart';

Manifest manifest({
  List<IntentSpec> intents = const [],
  List<EnumSpec> enums = const [],
  List<EntitySpec> entities = const [],
}) => Manifest(
  source: 'app|lib/intents.dart',
  intents: intents,
  enums: enums,
  entities: entities,
);

IntentSpec intent({
  String id = 'addTask',
  String title = 'Add task',
  String? description,
  String? confirmBeforeRunning,
  List<String> phrases = const [],
  List<ParamSpec> params = const [],
}) => IntentSpec(
  id: id,
  functionName: id,
  title: title,
  description: description,
  confirmBeforeRunning: confirmBeforeRunning,
  phrases: phrases,
  params: params,
  execution: ExecutionMode.background,
);

Map<String, Object?> strings(String json) =>
    ((jsonDecode(json) as Map)['strings'] as Map).cast<String, Object?>();

String? valueOf(String json, String key, String language) {
  final entry = strings(json)[key] as Map?;
  final localization = (entry?['localizations'] as Map?)?[language] as Map?;
  return (localization?['stringUnit'] as Map?)?['value'] as String?;
}

String? stateOf(String json, String key, String language) {
  final entry = strings(json)[key] as Map?;
  final localization = (entry?['localizations'] as Map?)?[language] as Map?;
  return (localization?['stringUnit'] as Map?)?['state'] as String?;
}

void main() {
  group('a catalogue built from nothing', () {
    test('has a key for every string a user could read', () {
      final out = StringCatalogEmitter(
        manifest(
          intents: [
            intent(
              description: 'Creates a task',
              confirmBeforeRunning: 'Sure?',
              params: [
                ParamSpec(
                  name: 'title',
                  title: 'Title',
                  type: ParamType.string,
                  isRequired: true,
                  description: 'What to call it',
                  requestValueDialog: 'What should it be called?',
                ),
              ],
            ),
          ],
        ),
      ).merge();

      expect(strings(out.catalog).keys, [
        'addTask.confirm',
        'addTask.description',
        'addTask.title',
        'addTask.title.ask',
        'addTask.title.description',
        'addTask.title.title',
      ]);
      expect(valueOf(out.catalog, 'addTask.title', 'en'), 'Add task');
      expect(
        valueOf(out.catalog, 'addTask.title.ask', 'en'),
        'What should it be called?',
      );
    });

    test('keys enums and entities by their type name', () {
      final out = StringCatalogEmitter(
        manifest(
          enums: [
            EnumSpec(
              typeName: 'Priority',
              dartClassName: 'Priority',
              displayName: 'Priority',
              values: [EnumValueSpec(name: 'whenever', title: 'Whenever')],
            ),
          ],
          entities: [
            EntitySpec(
              typeName: 'Project',
              dartClassName: 'ProjectEntity',
              idProperty: 'id',
              displayName: 'Project',
            ),
          ],
        ),
      ).merge();

      expect(
        strings(out.catalog).keys,
        containsAll([
          'enum.Priority',
          'enum.Priority.whenever',
          'entity.Project',
        ]),
      );
    });

    test('is valid JSON with the shape Xcode reads', () {
      final out = StringCatalogEmitter(manifest(intents: [intent()])).merge();
      final decoded = jsonDecode(out.catalog) as Map;
      expect(decoded['version'], '1.0');
      expect(decoded['sourceLanguage'], 'en');
      expect(
        (strings(out.catalog)['addTask.title']! as Map)['extractionState'],
        'manual',
      );
    });

    test('puts phrases in their own table, keyed by the English', () {
      // Not a choice: AppShortcutPhrase is ExpressibleByStringInterpolation
      // over a plain String, with no LocalizedStringResource initialiser in the
      // SDK at all, so the phrase is its own key. The file name is Apple's and
      // is what makes it a phrase table.
      final out = StringCatalogEmitter(
        manifest(
          intents: [
            intent(phrases: [r'Add a task to $app']),
          ],
        ),
      ).merge();

      expect(strings(out.catalog).keys, isNot(contains(r'Add a task to $app')));
      expect(strings(out.phrases).keys, [r'Add a task to $app']);
      expect(StringCatalogEmitter.phrasesFileName, 'AppShortcuts.xcstrings');
    });
  });

  group('merging into a catalogue somebody has translated', () {
    String withGerman({String english = 'Add task'}) =>
        StringCatalogEmitter(manifest(intents: [intent(title: english)]))
            .merge(
              existing: jsonEncode({
                'sourceLanguage': 'en',
                'strings': {
                  'addTask.title': {
                    'extractionState': 'manual',
                    'localizations': {
                      'en': {
                        'stringUnit': {
                          'state': 'translated',
                          'value': 'Add task',
                        },
                      },
                      'de': {
                        'stringUnit': {
                          'state': 'translated',
                          'value': 'Aufgabe hinzufügen',
                        },
                      },
                    },
                  },
                },
                'version': '1.0',
              }),
            )
            .catalog;

    test('the translation survives', () {
      expect(
        valueOf(withGerman(), 'addTask.title', 'de'),
        'Aufgabe hinzufügen',
      );
    });

    test('an unchanged English text leaves it translated', () {
      expect(stateOf(withGerman(), 'addTask.title', 'de'), 'translated');
    });

    test('a changed English text marks it for review, and keeps it', () {
      // What Xcode itself does in the same situation. Silently leaving a
      // translation of wording that no longer exists is the failure worth
      // avoiding — it is invisible in the editor and wrong in the app.
      final out = withGerman(english: 'Create task');
      expect(valueOf(out, 'addTask.title', 'en'), 'Create task');
      expect(valueOf(out, 'addTask.title', 'de'), 'Aufgabe hinzufügen');
      expect(stateOf(out, 'addTask.title', 'de'), 'needs_review');
    });

    test('a key nothing declares any more is kept, not deleted', () {
      final existing = jsonEncode({
        'sourceLanguage': 'en',
        'strings': {
          'removedTask.title': {
            'localizations': {
              'de': {
                'stringUnit': {'state': 'translated', 'value': 'Alt'},
              },
            },
          },
        },
        'version': '1.0',
      });
      final emitter = StringCatalogEmitter(manifest(intents: [intent()]));
      final out = emitter.merge(existing: existing).catalog;

      expect(valueOf(out, 'removedTask.title', 'de'), 'Alt');
      // Reported instead, so a person decides.
      expect(emitter.orphans(existing), ['removedTask.title']);
    });

    test('a second run changes nothing', () {
      // What makes --check meaningful: the merge has to be a fixed point, or
      // CI reports drift on every build.
      final e = StringCatalogEmitter(manifest(intents: [intent()]));
      final once = e.merge().catalog;
      expect(e.merge(existing: once).catalog, once);
    });

    test('a file that is not a catalogue is refused, not replaced', () {
      expect(
        () => StringCatalogEmitter(
          manifest(intents: [intent()]),
        ).merge(existing: '{"nope": true}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('a source language other than English is honoured', () {
      final out = StringCatalogEmitter(manifest(intents: [intent()])).merge(
        existing: jsonEncode({
          'sourceLanguage': 'de',
          'strings': <String, Object?>{},
          'version': '1.0',
        }),
      );
      expect(valueOf(out.catalog, 'addTask.title', 'de'), 'Add task');
      expect((jsonDecode(out.catalog) as Map)['sourceLanguage'], 'de');
    });
  });
}
