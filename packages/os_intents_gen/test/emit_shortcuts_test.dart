import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:xml/xml.dart';
import 'package:test/test.dart';

Manifest manifest(List<IntentSpec> intents) =>
    Manifest(source: 'app|lib/intents.dart', intents: intents);

IntentSpec intent({
  String id = 'addTask',
  String title = 'Add task',
  String? description,
  bool androidShortcut = true,
  String? androidCapability,
  List<ParamSpec> params = const [],
}) => IntentSpec(
  id: id,
  functionName: id,
  title: title,
  description: description,
  execution: ExecutionMode.background,
  androidShortcut: androidShortcut,
  androidCapability: androidCapability,
  params: params,
);

ParamSpec param(
  String name, {
  String? capabilityParameter,
  bool required = true,
}) => ParamSpec(
  name: name,
  title: name,
  type: ParamType.string,
  isRequired: required,
  androidCapabilityParameter: capabilityParameter,
);

Map<String, String> emit(Manifest m) => ShortcutsEmitter(
  m,
  applicationId: 'dev.osintents.example',
  activityClass: 'dev.osintents.example.MainActivity',
).emit();

String shortcuts(Manifest m) => emit(m)[ShortcutsEmitter.shortcutsFile]!;
String strings(Manifest m) => emit(m)[ShortcutsEmitter.stringsFile]!;

void main() {
  group('a plain intent', () {
    final xml = shortcuts(manifest([intent()]));

    test('becomes a launcher shortcut keyed by its id', () {
      expect(xml, contains('android:shortcutId="addTask"'));
      expect(xml, contains('android:enabled="true"'));
    });

    test('carries the id in the data URI', () {
      // Measured in probe/android_shortcuts: a data URI survives into the Intent
      // the system builds, which is what the runtime reads it back out of.
      expect(xml, contains('android:data="osintents://intent/addTask"'));
    });

    test('names the action and the activity it starts', () {
      expect(xml, contains('android:action="dev.osintents.action.RUN"'));
      expect(xml, contains('android:targetPackage="dev.osintents.example"'));
      expect(
        xml,
        contains('android:targetClass="dev.osintents.example.MainActivity"'),
      );
    });

    test('points its labels at resources, since a literal is refused', () {
      expect(
        xml,
        contains('android:shortcutShortLabel="@string/os_intents_addTask_label_short"'),
      );
      expect(
        xml,
        contains('android:shortcutLongLabel="@string/os_intents_addTask_label_long"'),
      );
    });

    test('declares no capability of its own', () {
      expect(xml, isNot(contains('<capability')));
    });
  });

  group('the strings that go with it', () {
    test('carry the title and the description', () {
      final xml = strings(
        manifest([intent(title: 'Add task', description: 'Creates a task')]),
      );
      expect(
        xml,
        contains('<string name="os_intents_addTask_label_short">Add task</string>'),
      );
      expect(
        xml,
        contains(
          '<string name="os_intents_addTask_label_long">Creates a task</string>',
        ),
      );
    });

    test('fall back to the title when there is no description', () {
      expect(
        strings(manifest([intent(title: 'Add task')])),
        contains('<string name="os_intents_addTask_label_long">Add task</string>'),
      );
    });

    test('escape what a resource file cannot take raw', () {
      // An unescaped apostrophe is an error from aapt, not a warning, and
      // "Bob's inbox" is an ordinary thing to write in a title.
      final xml = strings(
        manifest([intent(title: "Bob's inbox", description: 'A & "B"')]),
      );
      expect(xml, contains(r"Bob\'s inbox"));
      expect(xml, contains(r'A &amp; \"B\"'));
    });
  });

  group('a capability', () {
    final xml = shortcuts(
      manifest([
        intent(
          androidCapability: 'actions.intent.CREATE_TASK',
          params: [
            param('title', capabilityParameter: 'task.name', required: false),
            param('note', required: false),
          ],
        ),
      ]),
    );

    test('is declared, and bound from the shortcut', () {
      expect(xml, contains('<capability android:name="actions.intent.CREATE_TASK">'));
      expect(
        xml,
        contains('<capability-binding android:key="actions.intent.CREATE_TASK" />'),
      );
    });

    test('maps only the parameters a built-in intent can fill', () {
      expect(xml, contains('android:name="task.name"'));
      expect(xml, contains('android:key="title"'));
      // "note" has no built-in intent parameter, so Assistant has nothing to
      // put in it and offering it would be a lie.
      expect(xml, isNot(contains('android:key="note"')));
    });
  });

  group('what is left out', () {
    test('androidShortcut: false drops the shortcut but keeps the capability', () {
      final xml = shortcuts(
        manifest([
          intent(
            androidShortcut: false,
            androidCapability: 'actions.intent.CREATE_TASK',
          ),
        ]),
      );
      expect(xml, isNot(contains('android:shortcutId')));
      expect(xml, contains('<capability android:name="actions.intent.CREATE_TASK">'));
    });

    test('an intent that wants neither is absent entirely', () {
      final xml = shortcuts(
        manifest([intent(), intent(id: 'hidden', androidShortcut: false)]),
      );
      expect(xml, contains('android:shortcutId="addTask"'));
      expect(xml, isNot(contains('hidden')));
    });

    test('nothing at all is emitted when no intent wants either', () {
      expect(emit(manifest([intent(androidShortcut: false)])), isEmpty);
    });

    test('a required parameter keeps it out of the launcher', () {
      // A tap carries no values: there is nowhere in shortcuts.xml to put one
      // and nobody to ask. The shortcut would appear and then fail on use.
      final m = manifest([intent(params: [param('title')])]);
      expect(emit(m), isEmpty);
      expect(m.intents.single.androidShortcutBlockers, ['title']);
    });

    test('but not out of a capability, which Assistant fills first', () {
      final xml = shortcuts(
        manifest([
          intent(
            androidCapability: 'actions.intent.CREATE_TASK',
            params: [param('title', capabilityParameter: 'task.name')],
          ),
        ]),
      );
      expect(xml, isNot(contains('android:shortcutId')));
      expect(xml, contains('<capability android:name="actions.intent.CREATE_TASK">'));
    });
  });

  group('the file itself', () {
    test('says it is generated', () {
      expect(shortcuts(manifest([intent()])), contains('GENERATED BY os_intents'));
      expect(strings(manifest([intent()])), contains('GENERATED BY os_intents'));
    });

    test('parses as XML, with the structure Android expects', () {
      // Parsed rather than pattern-matched: a string emitter that loses a
      // closing tag still passes every `contains` assertion above, and the next
      // thing to read the file is aapt.
      final doc = XmlDocument.parse(
        shortcuts(
          manifest([
            intent(
              androidCapability: 'actions.intent.CREATE_TASK',
              params: [
                param('title', capabilityParameter: 'task.name', required: false),
              ],
            ),
            intent(id: 'dueToday', title: 'Due today'),
          ]),
        ),
      );

      final root = doc.rootElement;
      expect(root.name.local, 'shortcuts');
      expect(root.findElements('shortcut').length, 2);
      expect(root.findElements('capability').length, 1);

      final shortcut = root.findElements('shortcut').first;
      expect(shortcut.getAttribute('android:shortcutId'), 'addTask');
      expect(shortcut.findElements('intent').single.getAttribute('android:data'),
          'osintents://intent/addTask');
      expect(
        shortcut.findElements('capability-binding').single
            .getAttribute('android:key'),
        'actions.intent.CREATE_TASK',
      );

      final parameter = root
          .findElements('capability')
          .single
          .findElements('intent')
          .single
          .findElements('parameter')
          .single;
      expect(parameter.getAttribute('android:name'), 'task.name');
      expect(parameter.getAttribute('android:key'), 'title');
    });

    test('the strings file parses too', () {
      final doc = XmlDocument.parse(strings(manifest([intent()])));
      expect(doc.rootElement.name.local, 'resources');
      expect(doc.rootElement.findElements('string').length, 2);
    });
  });
}
