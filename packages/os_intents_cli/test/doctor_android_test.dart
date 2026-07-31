import 'package:os_intents_cli/src/app_functions_xml.dart';
import 'package:os_intents_cli/src/doctor.dart';
import 'package:os_intents_cli/src/doctor_android.dart';
import 'package:os_intents_cli/src/dumpsys_shortcuts.dart';
import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:test/test.dart';

/// The APK reports "everything is fine" on a healthy build, which proves the
/// reader works and nothing else. What doctor is for is the disagreements, and
/// those are cheaper to construct than to build.
ApkInspection apk(String xml, {bool shortcuts = true}) => ApkInspection(
  appFunctions: parseAppFunctionsXml(xml),
  hasShortcutsXml: shortcuts,
  appFunctionsError: null,
);

String metadata(String functions, [String dataTypes = '']) =>
    '<?xml version="1.0"?><appfunctions>$functions'
    '<AppFunctionComponentMetadataDocument>$dataTypes'
    '</AppFunctionComponentMetadataDocument></appfunctions>';

String function(String name, {String description = 'Adds a task'}) =>
    '<appfunction>'
    '<id>com.example.Svc#$name</id>'
    '<enabledByDefault>true</enabledByDefault>'
    '<description>$description</description>'
    '<parameters><dataTypeMetadata>'
    '<dataTypeReference>com.example.${name}Params</dataTypeReference>'
    '</dataTypeMetadata></parameters>'
    '</appfunction>';

String paramsType(String name, {required bool nullable}) =>
    '<dataTypes><dataTypeMetadata>'
    '<objectQualifiedName>com.example.${name}Params</objectQualifiedName>'
    '<properties>'
    '<dataTypeMetadata><isNullable>$nullable</isNullable><type>8</type>'
    '</dataTypeMetadata><name>title</name></properties>'
    '<required>title</required>'
    '</dataTypeMetadata><name>com.example.${name}Params</name></dataTypes>';

Manifest manifestWith(List<IntentSpec> intents) =>
    Manifest(source: 'app|lib/intents.dart', intents: intents);

IntentSpec intent({
  String id = 'addTask',
  String? description = 'Adds a task',
  ExecutionMode execution = ExecutionMode.background,
  List<ParamSpec> params = const [],
  bool androidShortcut = true,
}) => IntentSpec(
  id: id,
  functionName: id,
  title: 'Add task',
  description: description,
  execution: execution,
  androidShortcut: androidShortcut,
  params: params,
);

ParamSpec param(String name, {bool required = true}) => ParamSpec(
  name: name,
  title: name,
  type: ParamType.string,
  isRequired: required,
);

List<Finding> errorsOf(List<Finding> f) =>
    f.where((x) => x.severity == Severity.error).toList();

void main() {
  test('a headless intent missing from the APK is an error', () {
    final findings = diagnoseAndroid(
      declared: manifestWith([intent()]),
      apk: apk(metadata('')),
    );
    expect(errorsOf(findings), hasLength(1));
    expect(errorsOf(findings).single.summary, contains('addTask'));
  });

  test('no AppFunctions metadata at all is a note, not an error', () {
    // The default path: AppFunctions is opt-in behind `sync --android`, so an
    // APK without it is the normal state, not a broken one.
    final findings = diagnoseAndroid(
      declared: manifestWith([intent()]),
      apk: ApkInspection(
        appFunctions: null,
        hasShortcutsXml: true,
        appFunctionsError: null,
      ),
    );
    expect(errorsOf(findings), isEmpty);
    expect(findings.single.severity, Severity.note);
    expect(findings.single.detail, contains('sync --android'));
  });

  test('a foreground intent is not expected in the metadata', () {
    // Foreground intents are deliberately left out of the Kotlin emitter, so
    // their absence must not be reported as a fault.
    final findings = diagnoseAndroid(
      declared: manifestWith([intent(execution: ExecutionMode.foreground)]),
      apk: apk(metadata('')),
    );
    expect(findings, isEmpty);
  });

  test('a description that did not survive the build is a warning', () {
    final findings = diagnoseAndroid(
      declared: manifestWith([intent(description: 'Creates a task')]),
      apk: apk(
        metadata(
          function('addTask', description: 'Adds a task'),
          paramsType('addTask', nullable: false),
        ),
      ),
    );
    expect(errorsOf(findings), isEmpty);
    final warning = findings.single;
    expect(warning.severity, Severity.warning);
    expect(warning.detail, contains('Creates a task'));
  });

  test(
    'an optionality mismatch is reported from what the runtime enforces',
    () {
      // Dart says required; the APK property is nullable, which the runtime
      // treats as optional however <required> lists it.
      final findings = diagnoseAndroid(
        declared: manifestWith([
          intent(params: [param('title')]),
        ]),
        apk: apk(
          metadata(function('addTask'), paramsType('addTask', nullable: true)),
        ),
      );
      expect(
        findings.single.summary,
        allOf(contains('required in Dart'), contains('optional in the APK')),
      );
    },
  );

  test('a leftover function from an earlier build is a warning', () {
    final findings = diagnoseAndroid(
      declared: manifestWith([intent()]),
      apk: apk(
        metadata(
          '${function('addTask')}${function('deleteEverything')}',
          paramsType('addTask', nullable: false),
        ),
      ),
    );
    final leftover = findings.singleWhere(
      (f) => f.summary.contains('deleteEverything'),
    );
    expect(leftover.severity, Severity.warning);
    expect(leftover.detail, contains('clean rebuild'));
  });

  test('shortcuts XML missing while intents ask for one is an error', () {
    final findings = diagnoseAndroid(
      declared: manifestWith([intent(execution: ExecutionMode.foreground)]),
      apk: apk(metadata(''), shortcuts: false),
    );
    expect(errorsOf(findings), hasLength(1));
    expect(errorsOf(findings).single.summary, contains('shortcuts'));
  });

  test('unreadable metadata says so instead of reporting nothing', () {
    final findings = diagnoseAndroid(
      declared: manifestWith([intent()]),
      apk: ApkInspection(
        appFunctions: null,
        hasShortcutsXml: true,
        appFunctionsError: 'root element is <functions>',
      ),
    );
    expect(errorsOf(findings), hasLength(1));
    expect(errorsOf(findings).single.detail, contains('alpha'));
  });

  test('no manifests is an error, not a clean bill of health', () {
    final findings = diagnoseAndroid(declared: null, apk: apk(metadata('')));
    expect(errorsOf(findings), hasLength(1));
    expect(errorsOf(findings).single.detail, contains('build_runner'));
  });

  group('what the device says', () {
    DumpsysShortcuts device(List<RegisteredShortcut> shortcuts) =>
        DumpsysShortcuts(packageFound: true, shortcuts: shortcuts);

    RegisteredShortcut live(
      String id, {
      String? label = 'Add task',
      bool enabled = true,
    }) => RegisteredShortcut(
      id: id,
      shortLabel: label,
      longLabel: label,
      activity: 'com.example/.MainActivity',
      isEnabled: enabled,
    );

    test('an app that is not installed is not a broken app', () {
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([intent()]),
        device: DumpsysShortcuts(packageFound: false, shortcuts: const []),
        packageName: 'com.example',
      );
      expect(findings.single.severity, Severity.error);
      expect(findings.single.detail, contains('not installed'));
    });

    test('a shortcut the system silently dropped is an error', () {
      // ShortcutManager rejects what it cannot accept without saying so, and
      // caps how many it holds. The APK cannot tell you this happened.
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([intent()]),
        device: device(const []),
        packageName: 'com.example',
      );
      expect(errorsOf(findings), hasLength(1));
      expect(errorsOf(findings).single.detail, contains('drops'));
    });

    test('a label that never resolved is an error, not a mismatch', () {
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([intent()]),
        device: device([
          live('addTask', label: 'os_intents_addTask_label_short'),
        ]),
        packageName: 'com.example',
      );
      expect(errorsOf(findings), hasLength(1));
      expect(errorsOf(findings).single.detail, contains('string resource'));
    });

    test('an intent with a required parameter is expected to be absent', () {
      // The emitter leaves it out of the launcher on purpose, so its absence
      // must not be reported as a fault.
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([
          intent(params: [param('title')]),
        ]),
        device: device(const []),
        packageName: 'com.example',
      );
      expect(findings, isEmpty);
    });

    test('but its presence is, since a tap cannot supply the value', () {
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([
          intent(params: [param('title')]),
        ]),
        device: device([live('addTask')]),
        packageName: 'com.example',
      );
      expect(findings.single.severity, Severity.warning);
      expect(findings.single.detail, contains('required parameter'));
    });

    test('a disabled shortcut is a warning', () {
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([intent()]),
        device: device([live('addTask', enabled: false)]),
        packageName: 'com.example',
      );
      expect(findings.single.summary, contains('disabled'));
    });

    test('a stale install shows as a label that disagrees with Dart', () {
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([intent()]),
        device: device([live('addTask', label: 'Add a task')]),
        packageName: 'com.example',
      );
      expect(findings.single.severity, Severity.warning);
      expect(findings.single.detail, contains('stale install'));
    });

    test('a leftover shortcut from an earlier install is a warning', () {
      final findings = diagnoseDeviceShortcuts(
        declared: manifestWith([intent()]),
        device: device([live('addTask'), live('gone', label: 'Gone')]),
        packageName: 'com.example',
      );
      final leftover = findings.singleWhere((f) => f.summary.contains('gone'));
      expect(leftover.detail, contains('Uninstall'));
    });
  });
}
