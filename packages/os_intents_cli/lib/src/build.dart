import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import 'install.dart';
import 'sync.dart';

/// The whole pipeline, in the order it has to run.
///
/// The three steps exist for reasons that are real but none of the user's
/// business: `build_runner` derives its output paths from its input paths and
/// therefore cannot reach `ios/` or `android/`, so a manifest is handed to
/// `sync`, and what `sync` writes is invisible to both native builds until
/// `install` registers it. Getting that order wrong, or stopping one step
/// short, produces a build that succeeds and an app with no intents in it.
///
/// So there is one command that runs all three. Every step is idempotent, which
/// is what makes it safe to be the habitual one.
class BuildCommand extends Command<int> {
  BuildCommand() {
    argParser
      ..addOption(
        'project',
        abbr: 'C',
        help: 'Flutter project root.',
        defaultsTo: '.',
      )
      ..addOption(
        'target',
        help: 'Xcode target to compile the generated Swift into.',
        defaultsTo: 'Runner',
      )
      ..addFlag(
        'android',
        negatable: false,
        help:
            'Also generate Android AppFunctions — the same flag, and the same '
            'version chain, as `sync --android`.',
      )
      ..addFlag(
        'codegen',
        defaultsTo: true,
        help:
            'Run build_runner first. Turn it off when a watcher is already '
            'running, or when the generated Dart is checked in.',
      );
  }

  @override
  final String name = 'build';

  @override
  final String description =
      'Generate, sync and install in one step — the usual way to run this.';

  @override
  Future<int> run() async {
    final root = p.absolute(argResults!.option('project')!);

    if (argResults!.flag('codegen')) {
      final rc = await _buildRunner(root);
      if (rc != 0) return rc;
    }

    // Driven through a runner of their own rather than called directly: both
    // commands read their options out of `argResults`, which only a
    // CommandRunner populates. Cheaper than teaching them a second entry point,
    // and it keeps one definition of what each flag means.
    final runner = CommandRunner<int>('os_intents', description)
      ..addCommand(SyncCommand())
      ..addCommand(InstallCommand());

    final synced =
        await runner.run([
          'sync',
          '--project',
          root,
          '--no-hints',
          if (argResults!.flag('android')) '--android',
        ]) ??
        0;
    if (synced != 0) return synced;

    return await runner.run([
          'install',
          '--project',
          root,
          '--target',
          argResults!.option('target')!,
        ]) ??
        0;
  }

  /// Runs build_runner with the same Dart that is running us.
  ///
  /// [Platform.resolvedExecutable] rather than `dart` off `PATH`: a repo pinned
  /// with fvm has a different SDK on the path than the one that invoked this,
  /// and generating against one while the project resolves against the other is
  /// a class of failure worth not having.
  Future<int> _buildRunner(String root) async {
    stdout.writeln('os_intents: build_runner…');
    final process = await Process.start(
      Platform.resolvedExecutable,
      // Unconditionally: without it build_runner asks, and a prompt nobody is
      // there to answer is how a CI job hangs rather than fails.
      ['run', 'build_runner', 'build', '--delete-conflicting-outputs'],
      workingDirectory: root,
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await process.exitCode;
    if (code != 0) {
      stderr.writeln(
        '\nbuild_runner exited with $code, so nothing downstream ran.\n'
        'If it could not be found, the project needs both of these:\n'
        '  dev_dependencies:\n'
        '    build_runner: ^2.4.13\n'
        '    os_intents_gen: ^0.1.0',
      );
    }
    return code;
  }
}
