import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:path/path.dart' as p;

import 'android_manifest.dart';
import 'manifests.dart';

/// Reads the manifests build_runner produced and writes Swift into the app.
///
/// `build_runner` cannot write outside the paths it derives from its inputs, so
/// it stops at `lib/*.os_intents.json` and this command carries the result the
/// rest of the way.
/// The app's `applicationId`, read out of the Gradle build script.
///
/// Both `sync` and `doctor --device` need it: it is the package name the
/// generated shortcuts target, and the one the system files them under.
String? readApplicationId(String root) {
  for (final name in ['build.gradle.kts', 'build.gradle']) {
    final f = File(p.join(root, 'android', 'app', name));
    if (!f.existsSync()) continue;
    final m = RegExp(
      r'''applicationId\s*=?\s*["']([\w.]+)["']''',
    ).firstMatch(f.readAsStringSync());
    if (m != null) return m.group(1);
  }
  return null;
}

class SyncCommand extends Command<int> {
  SyncCommand() {
    argParser
      ..addOption(
        'project',
        abbr: 'C',
        help: 'Flutter project root.',
        defaultsTo: '.',
      )
      ..addFlag(
        'check',
        help:
            'Verify the generated Swift is up to date; write nothing. '
            'Exits non-zero on drift — meant for CI.',
        negatable: false,
      )
      ..addFlag(
        'android',
        help:
            'Also generate Android AppFunctions. Off by default: it requires '
            'compileSdk 37, AGP 9.1.1 and Gradle 9.3.1, and only runs on '
            'Android 16+. See docs/android.md.',
        negatable: false,
      )
      // Hidden because it exists for one caller: `build` runs install straight
      // after this, and telling the user to do the thing that is about to
      // happen anyway reads as a warning rather than as progress.
      ..addFlag('hints', defaultsTo: true, hide: true);
  }

  @override
  final String name = 'sync';

  @override
  final String description =
      'Generate the iOS sources from the manifests build_runner produced.';

  /// Everything generated lands here, in one directory, so the Xcode target
  /// needs a single synchronized group rather than a file reference per file.
  static const outputDir = 'ios/Runner/OsIntents';

  @override
  Future<int> run() async {
    final root = p.absolute(argResults!.option('project')!);
    final checkOnly = argResults!.flag('check');

    if (!Directory(p.join(root, 'lib')).existsSync()) {
      stderr.writeln(
        'No lib/ directory under $root — is this a Flutter project?',
      );
      return 66;
    }

    final List<Manifest> manifests;
    try {
      manifests = readManifests(root);
    } on ManifestReadException catch (e) {
      stderr.writeln('${p.relative(e.path, from: root)}: ${e.message}');
      return 65;
    }

    if (manifests.isEmpty) {
      stderr.writeln(
        'No *.os_intents.json found under lib/.\n'
        'Run `dart run build_runner build` first, and check that at least one '
        'function carries @AppIntent.',
      );
      return 66;
    }

    final merged = Manifest.merge(manifests);
    final problems = merged.validateGlobal();
    if (problems.isNotEmpty) {
      stderr.writeln('os_intents found ${problems.length} problem(s):');
      for (final e in problems) {
        stderr.writeln('  • $e');
      }
      return 65;
    }

    final files = SwiftEmitter(merged).emit();
    final target = Directory(p.join(root, outputDir));

    // Not behind --android: the shortcuts layer costs nothing. Everything the
    // flag gates is the AppFunctions version chain, and this needs none of it.
    final rcShortcuts = _syncShortcuts(root, merged, checkOnly: checkOnly);
    if (rcShortcuts != 0) return rcShortcuts;

    if (argResults!.flag('android')) {
      final rc = _syncAndroid(root, merged, checkOnly: checkOnly);
      if (rc != 0) return rc;
    }

    // A provider declared anywhere else in the app target silently wins or
    // loses against ours — Apple picks exactly one and never says which.
    final rival = _findRivalProvider(root, target.path);
    if (rival != null && files.containsKey('OsIntentsShortcuts.swift')) {
      stderr.writeln(
        'Refusing to write OsIntentsShortcuts.swift: this app already declares '
        'an AppShortcutsProvider in\n'
        '  ${p.relative(rival, from: root)}\n\n'
        'iOS selects a single provider per app, and a second one is dropped '
        'without any error. Move your phrases into @AppIntent annotations, or '
        'delete that provider, then run sync again.',
      );
      return 65;
    }

    var changed = 0;
    for (final entry in files.entries) {
      final out = File(p.join(target.path, entry.key));
      final existing = out.existsSync() ? out.readAsStringSync() : null;
      if (existing == entry.value) continue;
      changed++;
      if (checkOnly) {
        stderr.writeln('  drift: ${p.relative(out.path, from: root)}');
        continue;
      }
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(entry.value);
      stdout.writeln('  wrote ${p.relative(out.path, from: root)}');
    }

    if (checkOnly) {
      if (changed == 0) {
        stdout.writeln('os_intents: generated Swift is up to date.');
        return 0;
      }
      stderr.writeln(
        '\n$changed file(s) out of date. Run `dart run os_intents sync`.',
      );
      return 1;
    }

    stdout
      ..writeln()
      ..writeln(
        'os_intents: ${merged.intents.length} intent(s), '
        '${merged.entities.length} entity(ies) → $outputDir',
      );

    if (changed > 0 && argResults!.flag('hints') && !_isInXcodeProject(root)) {
      stdout.writeln(
        '\nOne-time step left: `os_intents install`, which adds $outputDir to '
        'the\nRunner target. Without it the generated intents compile into '
        'nothing and Siri\nnever sees them — `os_intents doctor` checks for '
        'exactly this.',
      );
    }
    return 0;
  }

  /// Writes `res/xml/os_intents_shortcuts.xml` and the strings it references.
  ///
  /// Silent no-op when there is no Android project — an iOS-only app should not
  /// have to know this exists.
  int _syncShortcuts(String root, Manifest merged, {required bool checkOnly}) {
    final manifestFile = File(
      p.join(root, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
    );
    if (!manifestFile.existsSync()) return 0;

    final appId = _applicationId(root);
    if (appId == null) {
      stderr.writeln(
        'Could not read the applicationId from android/app/build.gradle.kts, '
        'so the generated shortcuts have no target package to name.',
      );
      return 66;
    }

    final manifestText = manifestFile.readAsStringSync();
    final activity = _launcherActivity(manifestText, root: root);
    if (activity == null) {
      stderr.writeln(
        'Could not find a launcher activity in android/app/src/main/'
        'AndroidManifest.xml.\n'
        'A shortcut has to name the Activity it starts, and guessing it wrong '
        'produces shortcuts that fail at the tap rather than at build time.',
      );
      return 66;
    }

    final files = ShortcutsEmitter(
      merged,
      applicationId: appId,
      activityClass: activity,
    ).emit();
    if (files.isEmpty) return 0;

    final resDir = p.join(root, 'android', 'app', 'src', 'main', 'res');
    var changed = 0;
    for (final entry in files.entries) {
      final out = File(p.join(resDir, entry.key));
      final existing = out.existsSync() ? out.readAsStringSync() : null;
      if (existing == entry.value) continue;
      changed++;
      if (checkOnly) {
        stderr.writeln('  drift: ${p.relative(out.path, from: root)}');
        continue;
      }
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(entry.value);
      stdout.writeln('  wrote ${p.relative(out.path, from: root)}');
    }

    if (!checkOnly) {
      for (final intent in merged.intents) {
        if (intent.canBeLauncherShortcut) continue;
        final blockers = intent.androidShortcutBlockers;
        if (blockers.isEmpty) continue;
        stdout.writeln(
          '  note: "${intent.id}" gets no launcher shortcut — a tap cannot '
          'supply ${blockers.join(', ')}.',
        );
      }
    }

    if (!checkOnly &&
        changed > 0 &&
        argResults!.flag('hints') &&
        !declaresShortcutsMetaData(manifestText)) {
      stdout.writeln(
        '\nOne-time step left: `os_intents install`, which points the launcher '
        '<activity>\nat the file just written. Without it Android never reads '
        'it and no shortcut\nappears. By hand it is one element, and that is '
        'the whole manifest change —\na shortcut names its target component, '
        'so no intent-filter is needed:\n'
        '  <meta-data\n'
        '      android:name="android.app.shortcuts"\n'
        '      android:resource="@xml/os_intents_shortcuts" />',
      );
    }
    return 0;
  }

  static final _launcherActivityPattern = RegExp(
    r'<activity\b([^>]*)>(.*?)</activity>',
    dotAll: true,
  );
  static final _activityNamePattern = RegExp(r'android:name\s*=\s*"([^"]+)"');

  /// The activity carrying MAIN/LAUNCHER, fully qualified.
  ///
  /// Read from the manifest rather than assumed to be `.MainActivity`: it is
  /// what Flutter's template writes, but an app that renamed it would get
  /// shortcuts that fail when tapped, which is a much worse way to find out.
  String? _launcherActivity(String manifestText, {required String root}) {
    for (final m in _launcherActivityPattern.allMatches(manifestText)) {
      final body = m.group(2)!;
      if (!body.contains('android.intent.category.LAUNCHER')) continue;
      final name = _activityNamePattern.firstMatch(m.group(1)!)?.group(1);
      if (name == null) continue;
      if (!name.startsWith('.')) return name;
      final namespace = _namespace(root) ?? _applicationId(root);
      return namespace == null ? null : '$namespace$name';
    }
    return null;
  }

  /// Reads `namespace = "..."` from the app's Gradle file.
  ///
  /// The manifest's `android:name=".MainActivity"` is relative to this, which
  /// since AGP 8 lives in Gradle rather than in the manifest's `package`
  /// attribute — and it is not always the same as the applicationId.
  String? _namespace(String root) {
    for (final name in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(root, 'android', 'app', name));
      if (!f.existsSync()) continue;
      final m = RegExp(
        r'''namespace\s*=?\s*["']([\w.]+)["']''',
      ).firstMatch(f.readAsStringSync());
      if (m != null) return m.group(1);
    }
    return null;
  }

  /// Writes the Kotlin next to the app's own sources.
  ///
  /// Generated into the application id's package rather than a directory of our
  /// own, because `AppFunctionServiceEntryPoint` produces a service the
  /// manifest has to name, and Kotlin's package has to match the source path.
  int _syncAndroid(String root, Manifest merged, {required bool checkOnly}) {
    final appId = _applicationId(root);
    if (appId == null) {
      stderr.writeln(
        'Could not read the applicationId from android/app/build.gradle.kts.\n'
        'Generated Kotlin has to live in the app\'s own package, so this is not '
        'something os_intents can guess.',
      );
      return 66;
    }

    final emitter = KotlinEmitter(merged, packageName: appId);
    final files = emitter.emit();

    // Said before the "nothing to generate" line below, because an intent left
    // out for this reason is exactly the case where that line would otherwise
    // read as "your intents are all foreground" and send someone looking in the
    // wrong place.
    if (!checkOnly) {
      for (final entry in emitter.unsupported.entries) {
        stdout.writeln(
          '  note: "${entry.key}" is not offered to on-device agents — '
          '${entry.value.join(', ')} '
          '${entry.value.length == 1 ? 'is a file' : 'are files'}, and '
          'androidx.appfunctions has no file type. Android hands an agent a '
          'content URI and a grant instead, which is a different shape rather '
          'than a missing one. The app shortcut is unaffected.',
        );
      }
    }

    if (files.isEmpty) {
      stdout.writeln(
        'os_intents: nothing to generate for Android — every intent is '
        'Execution.foreground, and an AppFunctionService has no Activity to '
        'bring forward.',
      );
      return 0;
    }

    final dir = Directory(
      p.join(root, 'android/app/src/main/kotlin', appId.replaceAll('.', '/')),
    );

    var changed = 0;
    for (final entry in files.entries) {
      final out = File(p.join(dir.path, entry.key));
      final existing = out.existsSync() ? out.readAsStringSync() : null;
      if (existing == entry.value) continue;
      changed++;
      if (checkOnly) {
        stderr.writeln('  drift: ${p.relative(out.path, from: root)}');
        continue;
      }
      out.parent.createSync(recursive: true);
      out.writeAsStringSync(entry.value);
      stdout.writeln('  wrote ${p.relative(out.path, from: root)}');
    }

    if (!checkOnly && changed > 0) {
      stdout.writeln(
        '\nAndroid needs three things os_intents will not do to your build for '
        'you:\n'
        '  1. compileSdk 37 + compileSdkMinor, AGP 9.1.1+, Gradle 9.3.1+\n'
        '  2. the androidx.appfunctions dependency and its KSP compiler\n'
        '  3. a call to OsIntentsSetup.configure() from Application.onCreate,\n'
        '     and the generated service declared in AndroidManifest.xml\n'
        'docs/android.md has the exact snippets and why each is required.',
      );
    }
    return 0;
  }

  /// Reads `applicationId = "..."` out of the app's Gradle file.
  String? _applicationId(String root) => readApplicationId(root);

  /// Directories under `ios/` that hold dependencies rather than app source.
  ///
  /// `ephemeral` in particular is Flutter's symlink farm pointing at every
  /// plugin's sources — a provider found through it belongs to a package, and
  /// Risk #1b established the OS ignores those outright. Scanning them would
  /// only produce false alarms.
  static const _notAppSource = ['ephemeral', 'Pods', '.symlinks', 'build'];

  /// Looks for an `AppShortcutsProvider` the user wrote themselves.
  String? _findRivalProvider(String root, String skipDir) {
    final ios = Directory(p.join(root, 'ios'));
    if (!ios.existsSync()) return null;

    for (final f in ios.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.swift')) continue;
      if (p.isWithin(skipDir, f.path)) continue;

      final parts = p.split(p.relative(f.path, from: ios.path));
      if (parts.any(_notAppSource.contains)) continue;

      if (f.readAsStringSync().contains(': AppShortcutsProvider')) {
        return f.path;
      }
    }
    return null;
  }

  bool _isInXcodeProject(String root) {
    final pbx = File(
      p.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj'),
    );
    if (!pbx.existsSync()) return false;
    return pbx.readAsStringSync().contains('OsIntents');
  }
}
