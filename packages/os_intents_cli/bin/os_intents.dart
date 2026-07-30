import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:os_intents_cli/src/install.dart';
import 'package:os_intents_cli/src/sync.dart';

Future<void> main(List<String> args) async {
  final runner =
      CommandRunner<int>(
          'os_intents',
          'Carries generated intents into the native project, and checks they arrived.',
        )
        ..addCommand(SyncCommand())
        ..addCommand(InstallCommand())
        ..addCommand(DoctorCommand());

  try {
    exitCode = await runner.run(args) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    exitCode = 64;
  }
}

/// Answers the one question nothing else in the toolchain will: did the
/// intents actually reach the built app?
class DoctorCommand extends Command<int> {
  DoctorCommand() {
    argParser.addOption(
      'app',
      help: 'Path to a built .app bundle. Defaults to the debug simulator build.',
    );
  }

  @override
  final String name = 'doctor';

  @override
  final String description =
      'Inspect a built app and report which intents and phrases the OS will see.';

  @override
  Future<int> run() async {
    final path =
        argResults!.option('app') ??
        'build/ios/iphonesimulator/Runner.app';
    final app = Directory(path);
    if (!app.existsSync()) {
      stderr.writeln(
        'No app bundle at $path.\n'
        'Build one first: flutter build ios --simulator --debug',
      );
      return 66;
    }

    final meta = Directory('$path/Metadata.appintents');
    if (!meta.existsSync()) {
      stderr.writeln(
        'The bundle has no Metadata.appintents.\n\n'
        'Nothing was extracted, which almost always means the generated Swift '
        'is not compiled into the Runner target. Add ios/Runner/OsIntents to '
        'the target in Xcode as a synchronized folder, then rebuild.',
      );
      return 1;
    }

    final actions = File('$path/Metadata.appintents/extract.actionsdata');
    final ssu = File('$path/Metadata.appintents/root.ssu.yaml');

    stdout.writeln('Metadata.appintents: present');
    stdout.writeln(
      'extract.actionsdata: ${actions.existsSync() ? "${actions.lengthSync()} bytes" : "MISSING"}',
    );

    if (!ssu.existsSync()) {
      stdout.writeln(
        'root.ssu.yaml:       MISSING — no spoken phrases were registered.\n'
        '                     Intents still work from Shortcuts and Spotlight;\n'
        '                     "Hey Siri" will not reach them.',
      );
    } else {
      stdout.writeln('root.ssu.yaml:       present');
    }
    return 0;
  }
}
