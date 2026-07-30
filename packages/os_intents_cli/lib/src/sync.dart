import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:path/path.dart' as p;

/// Reads the manifests build_runner produced and writes Swift into the app.
///
/// `build_runner` cannot write outside the paths it derives from its inputs, so
/// it stops at `lib/*.os_intents.json` and this command carries the result the
/// rest of the way.
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
        help: 'Verify the generated Swift is up to date; write nothing. '
            'Exits non-zero on drift — meant for CI.',
        negatable: false,
      );
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

    final libDir = Directory(p.join(root, 'lib'));
    if (!libDir.existsSync()) {
      stderr.writeln('No lib/ directory under $root — is this a Flutter project?');
      return 66;
    }

    final manifests = <Manifest>[];
    for (final f in libDir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.os_intents.json')) continue;
      try {
        manifests.add(Manifest.decode(f.readAsStringSync()));
      } on FormatException catch (e) {
        stderr.writeln('${p.relative(f.path, from: root)}: $e');
        return 65;
      }
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

    if (changed > 0 && !_isInXcodeProject(root)) {
      stdout.writeln(
        '\nOne-time step left: add $outputDir to the Runner target in Xcode\n'
        'as a synchronized folder, so files added later are picked up on their '
        'own.\nWithout it the generated intents compile into nothing and Siri '
        'never sees them —\n`os_intents doctor` checks for exactly this.',
      );
    }
    return 0;
  }

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
    final pbx = File(p.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));
    if (!pbx.existsSync()) return false;
    return pbx.readAsStringSync().contains('OsIntents');
  }
}
