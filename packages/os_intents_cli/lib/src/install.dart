import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'sync.dart';

/// Adds the generated sources to the Runner target.
///
/// Xcode 16 introduced synchronized folder groups, which would make this a
/// one-liner, but they need `objectVersion = 77` and Flutter still templates
/// projects at 54. Bumping that silently is not worth the risk, so the files
/// are registered explicitly. There are at most three of them and their names
/// are fixed, so this stays idempotent.
class InstallCommand extends Command<int> {
  InstallCommand() {
    argParser.addOption(
      'project',
      abbr: 'C',
      help: 'Flutter project root.',
      defaultsTo: '.',
    );
  }

  @override
  final String name = 'install';

  @override
  final String description =
      'Register the generated Swift with the Runner target in Xcode.';

  @override
  Future<int> run() async {
    final root = p.absolute(argResults!.option('project')!);
    final pbxPath = p.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj');
    final pbx = File(pbxPath);
    if (!pbx.existsSync()) {
      stderr.writeln('No Xcode project at ${p.relative(pbxPath, from: root)}.');
      return 66;
    }

    // Whatever sync produced, rather than a hardcoded list — the set grows
    // (OsIntentsBackground.swift arrived with Execution.background) and a list
    // here would silently skip new files, leaving them uncompiled.
    final dir = Directory(p.join(root, SyncCommand.outputDir));
    final present = dir.existsSync()
        ? (dir.listSync().whereType<File>().toList()
                ..sort((a, b) => a.path.compareTo(b.path)))
              .map((f) => p.basename(f.path))
              .where((f) => f.endsWith('.swift'))
              .toList()
        : <String>[];

    if (present.isEmpty) {
      stderr.writeln(
        'Nothing to install — ${SyncCommand.outputDir} is empty.\n'
        'Run `dart run build_runner build` then `os_intents sync` first.',
      );
      return 66;
    }

    var text = pbx.readAsStringSync();
    final added = <String>[];

    for (final file in present) {
      if (text.contains('/* $file */')) continue;
      text = _register(text, file);
      added.add(file);
    }

    if (added.isEmpty) {
      stdout.writeln('os_intents: Runner target already references all files.');
      return 0;
    }

    // Every file reference must sit inside the OsIntents group. A reference
    // with `sourceTree = "<group>"` resolves its path relative to whichever
    // group holds it, so one left outside is looked for in ios/ and the build
    // fails with "Build input file cannot be found".
    text = text.contains('/* OsIntents */ = {')
        ? _addToExistingGroup(text, added)
        : _addGroup(text, present);

    File('$pbxPath.os_intents.bak').writeAsStringSync(pbx.readAsStringSync());
    pbx.writeAsStringSync(text);

    stdout
      ..writeln('os_intents: added to the Runner target:')
      ..writeAll(added.map((f) => '  • $f\n'))
      ..writeln()
      ..writeln('Backup: ${p.basename(pbxPath)}.os_intents.bak');
    return 0;
  }

  /// Deterministic 24-hex-digit object id, so re-running produces the same
  /// project file rather than a diff.
  static String _id(String seed) =>
      md5.convert(utf8.encode('os_intents:$seed')).toString().substring(0, 24).toUpperCase();

  String _register(String text, String file) {
    final fileRef = _id('ref:$file');
    final buildFile = _id('build:$file');

    text = text.replaceFirst(
      '/* Begin PBXBuildFile section */\n',
      '/* Begin PBXBuildFile section */\n'
          '\t\t$buildFile /* $file in Sources */ = {isa = PBXBuildFile; '
          'fileRef = $fileRef /* $file */; };\n',
    );

    text = text.replaceFirst(
      '/* Begin PBXFileReference section */\n',
      '/* Begin PBXFileReference section */\n'
          '\t\t$fileRef /* $file */ = {isa = PBXFileReference; '
          'lastKnownFileType = sourcecode.swift; path = $file; '
          'sourceTree = "<group>"; };\n',
    );

    // The Runner target's Sources phase, identified by its stable template id.
    text = text.replaceFirst(
      '97C146EA1CF9000F007C117D /* Sources */ = {\n'
          '\t\t\tisa = PBXSourcesBuildPhase;\n'
          '\t\t\tbuildActionMask = 2147483647;\n'
          '\t\t\tfiles = (\n',
      '97C146EA1CF9000F007C117D /* Sources */ = {\n'
          '\t\t\tisa = PBXSourcesBuildPhase;\n'
          '\t\t\tbuildActionMask = 2147483647;\n'
          '\t\t\tfiles = (\n'
          '\t\t\t\t$buildFile /* $file in Sources */,\n',
    );

    return text;
  }

  String _addToExistingGroup(String text, List<String> files) {
    final groupId = _id('group:OsIntents');
    final anchor =
        '$groupId /* OsIntents */ = {\n'
        '\t\t\tisa = PBXGroup;\n'
        '\t\t\tchildren = (\n';
    if (!text.contains(anchor)) {
      throw StateError(
        'The OsIntents group in project.pbxproj is not in the shape this tool '
        'wrote it. Remove the group in Xcode and run install again.',
      );
    }
    final children = files
        .map((f) => '\t\t\t\t${_id('ref:$f')} /* $f */,\n')
        .join();
    return text.replaceFirst(anchor, '$anchor$children');
  }

  String _addGroup(String text, List<String> files) {
    final groupId = _id('group:OsIntents');
    final children = files
        .map((f) => '\t\t\t\t${_id('ref:$f')} /* $f */,\n')
        .join();

    text = text.replaceFirst(
      '/* End PBXGroup section */',
      '\t\t$groupId /* OsIntents */ = {\n'
          '\t\t\tisa = PBXGroup;\n'
          '\t\t\tchildren = (\n'
          '$children'
          '\t\t\t);\n'
          '\t\t\tpath = OsIntents;\n'
          '\t\t\tsourceTree = "<group>";\n'
          '\t\t};\n'
          '/* End PBXGroup section */',
    );

    // Hang it off the Runner group.
    return text.replaceFirst(
      '97C146F01CF9000F007C117D /* Runner */ = {\n'
          '\t\t\tisa = PBXGroup;\n'
          '\t\t\tchildren = (\n',
      '97C146F01CF9000F007C117D /* Runner */ = {\n'
          '\t\t\tisa = PBXGroup;\n'
          '\t\t\tchildren = (\n'
          '\t\t\t\t$groupId /* OsIntents */,\n',
    );
  }
}
