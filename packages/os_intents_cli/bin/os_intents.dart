import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:os_intents_cli/src/doctor.dart';
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
