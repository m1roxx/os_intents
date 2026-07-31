import 'dart:io';

import 'package:os_intents_cli/src/pbxproj.dart';
import 'package:test/test.dart';

/// A project.pbxproj straight out of `flutter create`, so the parser is tested
/// against the real thing rather than a reduction of it.
final _pristine = File(
  'test/fixtures/pristine_project.pbxproj',
).readAsStringSync();

void main() {
  group('parsing a template project', () {
    final project = Pbxproj.parse(_pristine);

    test('reads the object version', () {
      expect(project.objectVersion, 54);
    });

    test('finds both native targets by name', () {
      expect(project.nativeTargetNames, containsAll(['Runner', 'RunnerTests']));
      expect(project.nativeTargetNamed('Runner'), isNotNull);
      expect(project.nativeTargetNamed('Nope'), isNull);
    });

    test('resolves a target to its own Sources phase', () {
      final runner = project.sourcesPhaseOf(project.nativeTargetNamed('Runner')!);
      final tests = project.sourcesPhaseOf(
        project.nativeTargetNamed('RunnerTests')!,
      );
      expect(runner, isNotNull);
      expect(tests, isNotNull);
      // The distinction the old id-based approach could not make: putting the
      // generated Swift in the test target compiles it where iOS never looks.
      expect(runner, isNot(tests));
      expect(project.isaOf(runner!), 'PBXSourcesBuildPhase');
    });

    test('finds the Runner group under the main group', () {
      final group = project.childGroupNamed(project.mainGroupId!, 'Runner');
      expect(group, isNotNull);
      expect(project.object(group)!['path'], 'Runner');
    });

    test('a template project uses no synchronized folders', () {
      expect(project.usesSynchronizedFolders, isFalse);
    });

    test('reads nested dictionaries and quoted strings', () {
      final id = project.idsWithIsa('PBXProject').single;
      final attributes = project.object(id)!['attributes'];
      expect(attributes, isA<Map<String, Object?>>());
      expect(project.object(id)!['compatibilityVersion'], 'Xcode 9.3');
    });

    test('drops the comments that annotate ids', () {
      final group = project.childGroupNamed(project.mainGroupId!, 'Runner')!;
      // `AppDelegate.swift` is written as `ID /* AppDelegate.swift */,` and
      // must read back as the id alone.
      expect(
        project.childIds(group, 'children'),
        everyElement(isNot(contains('/*'))),
      );
    });
  });

  group('a file it cannot read', () {
    test('is refused rather than half-understood', () {
      expect(() => Pbxproj.parse('nonsense'), throwsA(isA<PbxprojException>()));
      expect(
        () => Pbxproj.parse('{ objects = { A = { isa = X; }; '),
        throwsA(isA<PbxprojException>()),
      );
    });
  });

  group('the shapes Xcode writes', () {
    test('paths with slashes are one word, comments are not', () {
      final project = Pbxproj.parse('''
// !\$*UTF8*\$!
{
  objects = {
    A /* thing */ = {
      isa = PBXBuildFile;
      path = Runner/Info.plist;
      flags = "\$(inherited)";
      empty = (
      );
    };
  };
  rootObject = A /* Project object */;
}
''');
      final a = project.object('A')!;
      expect(a['path'], 'Runner/Info.plist');
      expect(a['flags'], r'$(inherited)');
      expect(a['empty'], isEmpty);
      expect(project.root['rootObject'], 'A');
    });
  });
}
