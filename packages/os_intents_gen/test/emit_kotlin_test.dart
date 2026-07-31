import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:test/test.dart';

IntentSpec intent({
  String id = 'addTask',
  String title = 'Add task',
  String? description,
  ExecutionMode execution = ExecutionMode.background,
  List<ParamSpec> params = const [],
}) => IntentSpec(
  id: id,
  functionName: id,
  title: title,
  description: description,
  execution: execution,
  params: params,
);

ParamSpec param(
  String name, {
  ParamType type = ParamType.string,
  bool required = true,
  String? entityTypeName,
  String? enumTypeName,
  String? description,
}) => ParamSpec(
  name: name,
  title: name,
  type: type,
  isRequired: required,
  entityTypeName: entityTypeName,
  enumTypeName: enumTypeName,
  description: description,
);

Manifest manifest(
  List<IntentSpec> intents, {
  String source = 'my_app|lib/intents.dart',
}) => Manifest(source: source, intents: intents);

KotlinEmitter emitter(List<IntentSpec> intents) =>
    KotlinEmitter(manifest(intents), packageName: 'com.example.app');

String serviceFor(List<IntentSpec> intents) =>
    emitter(intents).emit()['OsIntentsAppFunctions.kt']!;

void main() {
  group('what gets exposed', () {
    test('foreground intents are left out', () {
      // An AppFunctionService has no Activity to bring forward, so offering a
      // foreground intent to an agent would produce an action that always fails.
      final out = emitter([intent(execution: ExecutionMode.foreground)]).emit();
      expect(out, isEmpty);
    });

    test('background and static intents are exposed', () {
      expect(
        emitter([intent(execution: ExecutionMode.background)]).emit(),
        isNotEmpty,
      );
      expect(
        emitter([intent(execution: ExecutionMode.static_)]).emit(),
        isNotEmpty,
      );
    });

    test('a static intent reads the store before starting anything', () {
      // The whole point of Execution.static_ — and the only Android path that
      // can collect on it, since a shortcut starts an Activity regardless.
      final out = serviceFor([
        intent(id: 'dueToday', execution: ExecutionMode.static_),
      ]);
      expect(out, contains('OsIntentsBridge.staticResult('));
      expect(out, contains('if (stored != null) {'));
      // And still falls through: nothing published yet is a first run, where
      // running the handler beats answering with silence.
      expect(out, contains('OsIntentsBridge.invoke('));
      expect(
        out.indexOf('staticResult('),
        lessThan(out.indexOf('OsIntentsBridge.invoke(')),
      );
    });

    test('a background intent does not read the store', () {
      expect(
        serviceFor([
          intent(id: 'addTask', execution: ExecutionMode.background),
        ]),
        isNot(contains('staticResult(')),
      );
    });

    test('a mixed manifest exposes only the headless ones', () {
      final out = serviceFor([
        intent(id: 'addTask'),
        intent(id: 'openScreen', execution: ExecutionMode.foreground),
      ]);
      expect(out, contains('suspend fun addTask('));
      expect(out, isNot(contains('openScreen')));
    });
  });

  group('service shape', () {
    test('every intent is a method on one service class', () {
      // Unlike iOS, where each intent is its own struct: alpha10 requires
      // @AppFunction to be a member of an @AppFunctionServiceEntryPoint class.
      final out = serviceFor([
        intent(id: 'addTask'),
        intent(id: 'completeTask'),
      ]);
      expect(
        'abstract class BaseOsIntentsAppFunctionService'.allMatches(out).length,
        1,
      );
      expect(out, contains('suspend fun addTask('));
      expect(out, contains('suspend fun completeTask('));
    });

    test('the entry point names the service and its xml', () {
      final out = serviceFor([intent()]);
      expect(out, contains('@AppFunctionServiceEntryPoint('));
      expect(out, contains('serviceName = "OsIntentsAppFunctionService"'));
      expect(
        out,
        contains('appFunctionXmlFileName = "os_intents_app_functions"'),
      );
    });

    test('the service is gated on API 36', () {
      expect(serviceFor([intent()]), contains('@RequiresApi(36)'));
    });

    test('the engine is torn down with the service', () {
      final out = serviceFor([intent()]);
      expect(out, contains('override fun onDestroy()'));
      expect(out, contains('OsIntentsBridge.shutdown()'));
    });
  });

  group('descriptions come from KDoc', () {
    test('the function description is KDoc, not an annotation argument', () {
      // alpha10 reads prose from KDoc; a description = "..." argument would be
      // silently ignored.
      final out = serviceFor([
        intent(description: 'Creates a new task in the Inbox'),
      ]);
      expect(out, contains('* Creates a new task in the Inbox'));
      expect(out, contains('@AppFunction(isDescribedByKDoc = true)'));
      expect(out, isNot(contains('description =')));
    });

    test('the title stands in when there is no description', () {
      expect(serviceFor([intent(title: 'Add task')]), contains('* Add task'));
    });

    test('properties carry inline KDoc', () {
      // Class-level @param tags are explicitly not read, so each property needs
      // its own comment.
      final out = serviceFor([
        intent(params: [param('title', description: 'The title of the task')]),
      ]);
      expect(out, contains('/** The title of the task */'));
    });

    test('a comment terminator inside prose cannot close the KDoc early', () {
      final out = serviceFor([intent(description: 'Ends the block */ here')]);
      expect(out, isNot(contains('*/ here')));
      expect(out, contains('* / here'));
    });
  });

  group('parameters', () {
    test('each intent gets its own serializable params class', () {
      // A function takes a single object, not loose arguments.
      final out = serviceFor([
        intent(params: [param('title')]),
      ]);
      expect(
        out,
        contains('@AppFunctionSerializable(isDescribedByKDoc = true)'),
      );
      expect(out, contains('data class AddTaskParams('));
      expect(out, contains('val title: String,'));
      expect(out, contains('suspend fun addTask(params: AddTaskParams)'));
    });

    test('an intent with no parameters still gets a data class', () {
      // Kotlin data classes need a property, and the platform needs an object.
      final out = serviceFor([intent()]);
      expect(out, contains('data class AddTaskParams('));
      expect(out, contains('val unused: Boolean = true,'));
      expect(out, contains('args = emptyMap(),'));
    });

    test('optional parameters are nullable', () {
      final out = serviceFor([
        intent(params: [param('title'), param('note', required: false)]),
      ]);
      expect(out, contains('val title: String,'));
      expect(out, contains('val note: String?,'));
    });

    test('dates and entities use the same wire shapes as iOS', () {
      final out = serviceFor([
        intent(
          params: [
            param('due', type: ParamType.dateTime),
            param('project', type: ParamType.entity, entityTypeName: 'Project'),
          ],
        ),
      ]);
      // Epoch millis and an identifier, matching the Swift side.
      expect(out, contains('val due: Long,'));
      expect(out, contains('val project: String,'));
    });

    test('arguments are forwarded to the bridge by name', () {
      final out = serviceFor([
        intent(params: [param('title')]),
      ]);
      expect(out, contains('"title" to params.title,'));
      expect(out, contains('id = "addTask",'));
    });
  });

  group('setup file', () {
    test('carries the entrypoint library and the registrant', () {
      final out = emitter([intent()]).emit()['OsIntentsSetup.kt']!;
      expect(
        out,
        contains('entrypointLibraryUri = "package:my_app/intents.dart"'),
      );
      expect(out, contains('GeneratedPluginRegistrant.registerWith(engine)'));
    });

    test('is generated into the app package, so the manifest can see it', () {
      final out = emitter([intent()]).emit()['OsIntentsSetup.kt']!;
      expect(out, contains('package com.example.app'));
    });
  });

  group('enum parameters', () {
    Manifest withPriority() => Manifest(
      source: 'app|lib/intents.dart',
      intents: [
        intent(
          params: [
            param('priority', type: ParamType.enum_, enumTypeName: 'Priority'),
          ],
        ),
      ],
      enums: [
        EnumSpec(
          typeName: 'Priority',
          dartClassName: 'Priority',
          values: [
            EnumValueSpec(name: 'whenever', title: 'Whenever'),
            EnumValueSpec(name: 'veryUrgent', title: 'Very urgent'),
          ],
        ),
      ],
    );

    String kotlin(Manifest m) => KotlinEmitter(
      m,
      packageName: 'com.example.app',
    ).emit()['OsIntentsAppFunctions.kt']!;

    test('become a String narrowed by a value constraint', () {
      // The only parameter narrowing Android offers — a fixed set decided at
      // compile time. Nothing here asks the app anything; see docs/android.md.
      final out = kotlin(withPriority());
      expect(
        out,
        contains(
          '@AppFunctionStringValueConstraint('
          'enumValues = ["whenever", "veryUrgent"])',
        ),
      );
      expect(out, contains('val priority: String,'));
    });

    test('the constraint carries constant names, not display titles', () {
      // The wire value is the Dart constant's own name on both platforms. Send
      // the title instead and the handler would fail to decode it.
      final out = kotlin(withPriority());
      expect(out, isNot(contains('"Very urgent"')));
    });

    test('the import it needs is emitted', () {
      expect(
        kotlin(withPriority()),
        contains(
          'import androidx.appfunctions.AppFunctionStringValueConstraint',
        ),
      );
    });

    test('a parameter of another type gets no constraint', () {
      final out = kotlin(
        Manifest(
          source: 'app|lib/intents.dart',
          intents: [
            intent(params: [param('title')]),
          ],
        ),
      );
      expect(out, isNot(contains('AppFunctionStringValueConstraint(')));
    });
  });
}
