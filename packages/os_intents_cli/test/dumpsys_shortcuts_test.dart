import 'dart:io';

import 'package:os_intents_cli/src/dumpsys_shortcuts.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Captured from `adb shell dumpsys shortcut` on an API 36 AOSP ATD emulator
/// with the Android probe installed. It holds three packages, one of them
/// Android's own contacts app, because picking the right section out of a
/// system-wide dump is most of the job.
String get _dump =>
    File(p.join('test', 'fixtures', 'dumpsys_shortcut.txt')).readAsStringSync();

const _probe = 'dev.osintents.appfunctions_probe';

void main() {
  group('a real dump', () {
    test('reads only the section belonging to the package asked for', () {
      final result = parseDumpsysShortcuts(_dump, packageName: _probe);
      expect(result.packageFound, isTrue);
      expect(result.shortcuts.map((s) => s.id), ['dueToday', 'openInbox']);
    });

    test('a different package in the same dump is read separately', () {
      // Two os_intents probes were installed at once; reading one must not
      // pick up the other's shortcuts.
      final other = parseDumpsysShortcuts(
        _dump,
        packageName: 'dev.osintents.shortcuts_probe',
      );
      expect(other.shortcuts.map((s) => s.id), ['dueToday', 'addTask']);
    });

    test('labels come back resolved, not as resource names', () {
      // The whole point of asking the device: the APK only has
      // @string/os_intents_dueToday_label_short, and whether that resolves is
      // something only ShortcutManager knows.
      final s = parseDumpsysShortcuts(
        _dump,
        packageName: _probe,
      ).shortcuts.firstWhere((s) => s.id == 'dueToday');
      expect(s.shortLabel, 'Tasks due today');
      expect(s.longLabel, 'Tasks due today');
      expect(s.labelLooksUnresolved, isFalse);
      expect(s.isEnabled, isTrue);
    });

    test('names the activity the shortcut starts', () {
      final s = parseDumpsysShortcuts(
        _dump,
        packageName: _probe,
      ).shortcuts.first;
      expect(s.activity, contains('MainActivity'));
    });

    test('an intent with a required parameter is absent, as designed', () {
      // A tap carries no values, so the emitter leaves addTask out of the
      // launcher. This is that decision observed at run time rather than
      // asserted about a string.
      final ids = parseDumpsysShortcuts(
        _dump,
        packageName: _probe,
      ).shortcuts.map((s) => s.id);
      expect(ids, isNot(contains('addTask')));
    });
  });

  group('what the dump cannot tell us apart', () {
    test('a package with no section is reported as not found', () {
      final result = parseDumpsysShortcuts(
        _dump,
        packageName: 'com.example.never.installed',
      );
      expect(result.packageFound, isFalse);
      expect(result.shortcuts, isEmpty);
    });

    test('installed with nothing registered is not the same as absent', () {
      final result = parseDumpsysShortcuts('''
      Package: com.example.app  UID: 10101
        Calls: 0
        Shortcuts:
      Package: com.other.app  UID: 10102
''', packageName: 'com.example.app');
      expect(result.packageFound, isTrue);
      expect(result.shortcuts, isEmpty);
    });
  });

  group('fields that go wrong on a device', () {
    test('a label that never resolved is recognisable', () {
      final result = parseDumpsysShortcuts('''
      Package: com.example.app  UID: 10101
        Shortcuts:
          ShortcutInfo {id=addTask, flags=0x1a0 [ImManStr]
            shortLabel=os_intents_addTask_label_short, resId=0[null]
''', packageName: 'com.example.app');
      expect(result.shortcuts.single.labelLooksUnresolved, isTrue);
    });

    test('a disabled shortcut is not reported as live', () {
      final result = parseDumpsysShortcuts('''
      Package: com.example.app  UID: 10101
        Shortcuts:
          ShortcutInfo {id=addTask, flags=0x1a0 [ImManStr]
            shortLabel=Add task, resId=1[x]
            disabledReason=[App changed]
''', packageName: 'com.example.app');
      expect(result.shortcuts.single.isEnabled, isFalse);
    });

    test('a label containing a comma survives', () {
      final result = parseDumpsysShortcuts('''
      Package: com.example.app  UID: 10101
        Shortcuts:
          ShortcutInfo {id=addTask, flags=0x1a0 [ImManStr]
            shortLabel=Add a task, quickly, resId=1[x]
''', packageName: 'com.example.app');
      expect(result.shortcuts.single.shortLabel, 'Add a task, quickly');
    });
  });
}
