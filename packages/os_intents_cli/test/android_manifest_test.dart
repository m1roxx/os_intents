import 'dart:io';

import 'package:os_intents_cli/src/android_manifest.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

final _pristine = File(
  'test/fixtures/pristine_AndroidManifest.xml',
).readAsStringSync();

/// A manifest with [body] as the contents of `<application>`.
String manifest(String body, {String prefix = 'android'}) =>
    '<manifest xmlns:$prefix="http://schemas.android.com/apk/res/android">\n'
    '    <application $prefix:label="tasks">\n'
    '$body\n'
    '    </application>\n'
    '</manifest>\n';

String launcher({
  String name = '.MainActivity',
  String extra = '',
  String prefix = 'android',
  String element = 'activity',
}) =>
    '        <$element $prefix:name="$name">\n'
    '            <intent-filter>\n'
    '                <action $prefix:name="android.intent.action.MAIN"/>\n'
    '                <category $prefix:name="android.intent.category.LAUNCHER"/>\n'
    '            </intent-filter>\n'
    '$extra'
    '        </$element>';

/// The `android:resource` the launcher activity points `android.app.shortcuts`
/// at, read back out of the parsed document rather than out of the text — which
/// is the only way to tell "written into the file" from "written into the right
/// element".
String? shortcutsResourceOf(String text, {String prefix = 'android'}) {
  final activities = XmlDocument.parse(text).rootElement
      .findElements('application')
      .expand((a) => a.findElements('activity'));
  for (final activity in activities) {
    final isLauncher = activity
        .findElements('intent-filter')
        .any(
          (f) => f
              .findElements('category')
              .any(
                (c) =>
                    c.getAttribute('$prefix:name') ==
                    'android.intent.category.LAUNCHER',
              ),
        );
    if (!isLauncher) continue;
    for (final data in activity.findElements('meta-data')) {
      if (data.getAttribute('$prefix:name') == 'android.app.shortcuts') {
        return data.getAttribute('$prefix:resource') ?? '';
      }
    }
  }
  return null;
}

Matcher throwsManifestException(Object about) => throwsA(
  isA<AndroidManifestException>().having((e) => e.message, 'message', about),
);

void main() {
  group('a template manifest', () {
    final installed = installShortcutsMetaData(_pristine);

    test('points its launcher activity at the generated shortcuts', () {
      expect(shortcutsResourceOf(installed), '@xml/os_intents_shortcuts');
    });

    test('is still XML', () {
      expect(() => XmlDocument.parse(installed), returnsNormally);
    });

    test('keeps every line it already had', () {
      // The edit is purely additive by construction; this is what stops it
      // quietly becoming a reformat of a file the user maintains by hand.
      expect(installed.split('\n'), containsAllInOrder(_pristine.split('\n')));
    });

    test('adds nothing but the meta-data and its comment', () {
      final added = installed.split('\n').length - _pristine.split('\n').length;
      expect(added, 5);
    });

    test('copies the indentation of the elements around it', () {
      final line = installed
          .split('\n')
          .firstWhere((l) => l.contains('<meta-data') && l.trim().length == 10);
      expect(line, startsWith('            <meta-data'));
    });

    test('is idempotent', () {
      expect(
        identical(installShortcutsMetaData(installed), installed),
        isTrue,
        reason: 'a second run should return the input, not a second element',
      );
    });

    test('answers declaresShortcutsMetaData before and after', () {
      expect(declaresShortcutsMetaData(_pristine), isFalse);
      expect(declaresShortcutsMetaData(installed), isTrue);
    });
  });

  group('a manifest it will not edit', () {
    test('one with no launcher activity at all', () {
      final text = manifest('        <activity android:name=".Other" />');
      expect(
        () => installShortcutsMetaData(text),
        throwsManifestException(contains('No launcher activity')),
      );
    });

    test('one with two launcher activities, naming both', () {
      final text = manifest(
        '${launcher()}\n${launcher(name: '.SecondActivity')}',
      );
      expect(
        () => installShortcutsMetaData(text),
        throwsManifestException(
          allOf(
            contains('2 launcher activities'),
            contains('.MainActivity'),
            contains('.SecondActivity'),
          ),
        ),
      );
    });

    test('one whose launcher is an activity-alias', () {
      // Android allows it, and shortcuts hang off an <activity>. Refusing and
      // naming the manual step beats attaching them to something else.
      final text = manifest(
        '        <activity android:name=".MainActivity" />\n'
        '${launcher(name: '.Alias', element: 'activity-alias')}',
      );
      expect(
        () => installShortcutsMetaData(text),
        throwsManifestException(contains('No launcher activity')),
      );
    });

    test('one already pointing android.app.shortcuts somewhere else', () {
      final text = manifest(
        launcher(
          extra:
              '            <meta-data android:name="android.app.shortcuts" '
              'android:resource="@xml/mine" />\n',
        ),
      );
      expect(
        () => installShortcutsMetaData(text),
        throwsManifestException(
          allOf(contains('@xml/mine'), contains('one shortcuts file')),
        ),
      );
    });

    test('one that does not declare the Android namespace', () {
      final text =
          '<manifest>\n'
          '    <application>\n'
          '${launcher()}\n'
          '    </application>\n'
          '</manifest>\n';
      expect(
        () => installShortcutsMetaData(text),
        throwsManifestException(contains('no prefix')),
      );
    });

    test('one that is not XML', () {
      expect(
        () => installShortcutsMetaData('<manifest><application></manifest>'),
        throwsA(isA<AndroidManifestException>()),
      );
    });

    test('and declaresShortcutsMetaData says false rather than throwing', () {
      expect(declaresShortcutsMetaData('not xml at all'), isFalse);
      expect(declaresShortcutsMetaData(manifest('')), isFalse);
    });
  });

  group('shapes other than the template', () {
    test('a prefix other than "android" is used, not assumed', () {
      final text = manifest(launcher(prefix: 'a'), prefix: 'a');
      final installed = installShortcutsMetaData(text);
      expect(installed, contains('a:name="android.app.shortcuts"'));
      expect(
        installed,
        isNot(contains('android:name="android.app.shortcuts"')),
      );
      expect(
        shortcutsResourceOf(installed, prefix: 'a'),
        '@xml/os_intents_shortcuts',
      );
    });

    test('a self-closing activity nearby is not mistaken for a body', () {
      final text = manifest(
        '        <activity android:name=".Splash" />\n'
        '${launcher()}\n'
        '        <activity android:name=".Settings" />',
      );
      expect(
        shortcutsResourceOf(installShortcutsMetaData(text)),
        '@xml/os_intents_shortcuts',
      );
    });

    test('an activity already carrying other meta-data keeps it', () {
      final text = manifest(
        launcher(
          extra:
              '            <meta-data android:name="io.flutter.x" '
              'android:value="2" />\n',
        ),
      );
      final installed = installShortcutsMetaData(text);
      expect(installed, contains('io.flutter.x'));
      expect(shortcutsResourceOf(installed), '@xml/os_intents_shortcuts');
    });

    test('a tab-indented manifest gets tab-indented output', () {
      final text =
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '\t<application>\n'
          '\t\t<activity android:name=".MainActivity">\n'
          '\t\t\t<intent-filter>\n'
          '\t\t\t\t<action android:name="android.intent.action.MAIN"/>\n'
          '\t\t\t\t<category android:name="android.intent.category.LAUNCHER"/>\n'
          '\t\t\t</intent-filter>\n'
          '\t\t</activity>\n'
          '\t</application>\n'
          '</manifest>\n';
      final installed = installShortcutsMetaData(text);
      expect(installed, contains('\t\t\t<meta-data\n'));
      expect(shortcutsResourceOf(installed), '@xml/os_intents_shortcuts');
    });
  });
}
