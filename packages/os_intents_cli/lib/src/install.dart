import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'pbxproj.dart';
import 'sync.dart';

/// Adds the generated sources to the Runner target.
///
/// Xcode 16 introduced synchronized folder groups, which would make this a
/// one-liner, but they need `objectVersion = 77` and Flutter still templates
/// projects at 54. Bumping that silently is not worth the risk, so the files
/// are registered explicitly.
///
/// Every anchor is an object id looked up in the parsed project — the ids in
/// Flutter's template are not a contract, and an anchor that silently fails to
/// match produces an app that builds cleanly with no intents in it. The edited
/// text is parsed again and checked before anything is written, so the failure
/// mode is a message rather than a quiet no-op.
class InstallCommand extends Command<int> {
  InstallCommand() {
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
      );
  }

  @override
  final String name = 'install';

  @override
  final String description =
      'Register the generated Swift with the Runner target in Xcode.';

  /// Directory name the generated sources live in, under the app group.
  static final String groupName = p.basename(SyncCommand.outputDir);

  @override
  Future<int> run() async {
    final root = p.absolute(argResults!.option('project')!);
    final targetName = argResults!.option('target')!;
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

    final original = pbx.readAsStringSync();
    final String edited;
    try {
      edited = install(original, files: present, targetName: targetName);
    } on PbxprojException catch (e) {
      stderr.writeln(
        'os_intents cannot edit ${p.relative(pbxPath, from: root)}:\n\n'
        '${e.message}\n\n'
        'Nothing was written. Add ${SyncCommand.outputDir} to the $targetName '
        'target by hand in Xcode\n(File → Add Files to "Runner"…, "Create '
        'groups"), and the rest of the toolchain works\nunchanged — '
        '`os_intents doctor` will confirm the intents reached the build.',
      );
      return 1;
    }

    if (identical(edited, original)) {
      stdout.writeln('os_intents: $targetName already compiles all of them.');
      return 0;
    }

    File('$pbxPath.os_intents.bak').writeAsStringSync(original);
    pbx.writeAsStringSync(edited);

    stdout
      ..writeln('os_intents: added to the $targetName target:')
      ..writeAll(present.map((f) => '  • $f\n'))
      ..writeln()
      ..writeln('Backup: ${p.basename(pbxPath)}.os_intents.bak');
    return 0;
  }

  /// Returns the project text with [files] compiled into [targetName].
  ///
  /// Pure, so the whole edit — including the check that it landed — is testable
  /// against a captured project file without Xcode. Returns the input
  /// unchanged, identically, when there is nothing to do. Throws
  /// [PbxprojException] rather than editing anything it does not understand.
  static String install(
    String text, {
    required List<String> files,
    String targetName = 'Runner',
  }) {
    final project = Pbxproj.parse(text);

    final targetId = project.nativeTargetNamed(targetName);
    if (targetId == null) {
      throw PbxprojException(
        'The project has no target called "$targetName". It has: '
        '${project.nativeTargetNames.join(', ')}.\n'
        'Pass --target if the app target is named something else.',
      );
    }

    final phaseId = project.sourcesPhaseOf(targetId);
    if (phaseId == null) {
      throw PbxprojException(
        'Target "$targetName" has no Sources build phase, so there is nothing '
        'to add the generated Swift to.',
      );
    }

    final mainGroupId = project.mainGroupId;
    if (mainGroupId == null) {
      throw PbxprojException('The project has no main group.');
    }

    // The group the generated directory hangs off. Its `path` matters: a file
    // reference with `sourceTree = "<group>"` resolves relative to the group
    // that holds it, so attaching to a name-only group would make Xcode look
    // for the sources in ios/ and fail with "Build input file cannot be found".
    final appGroupId = project.childGroupNamed(mainGroupId, targetName);
    if (appGroupId == null ||
        project.object(appGroupId)?['path'] != targetName) {
      if (project.usesSynchronizedFolders) {
        throw PbxprojException(
          'This project uses Xcode 16 synchronized folder groups '
          '(objectVersion ${project.objectVersion}), which add a directory '
          'wholesale rather than file by file.\n'
          'If ios/$targetName is synchronized, everything `sync` writes is '
          'already compiled and install has nothing to do.',
        );
      }
      throw PbxprojException(
        'Could not find a "$targetName" group holding the app sources '
        '(a PBXGroup with path = $targetName under the project\'s main group).',
      );
    }

    // A second reference to one of these names would compile the same source
    // twice rather than fix anything, and which of the two the user meant is
    // not a thing to decide on their behalf.
    final existingGroup = project.childGroupNamed(appGroupId, groupName);
    final alreadyOurs = existingGroup == null
        ? const <String>{}
        : project.childIds(existingGroup, 'children').toSet();
    for (final id in project.idsWithIsa('PBXFileReference')) {
      final path = project.object(id)?['path'];
      if (path is! String ||
          !files.contains(path) ||
          alreadyOurs.contains(id)) {
        continue;
      }
      throw PbxprojException(
        '"$path" is already referenced elsewhere in the project, outside the '
        '$groupName group.\n'
        'Adding a second reference would compile it twice. Remove that one in '
        'Xcode and run install again.',
      );
    }

    final plan = _Plan(project, phaseId: phaseId, appGroupId: appGroupId);
    for (final file in files) {
      plan.add(file);
    }
    if (plan.isEmpty) return text;

    final out = plan.apply(text);

    // The point of the rewrite: prove the edit landed rather than trust that
    // every anchor matched. A missed insertion used to look exactly like
    // success and only showed up as an app with no intents in it.
    _verify(out, files: files, targetName: targetName);
    return out;
  }

  static void _verify(
    String text, {
    required List<String> files,
    required String targetName,
  }) {
    final Pbxproj project;
    try {
      project = Pbxproj.parse(text);
    } on PbxprojException catch (e) {
      throw PbxprojException(
        'The edit would have produced a project file that no longer parses '
        '(${e.message}). Nothing was written.',
      );
    }

    final targetId = project.nativeTargetNamed(targetName)!;
    final phaseId = project.sourcesPhaseOf(targetId)!;
    final appGroupId = project.childGroupNamed(
      project.mainGroupId!,
      targetName,
    )!;
    final groupId = project.childGroupNamed(appGroupId, groupName);
    if (groupId == null) {
      throw PbxprojException(
        'The $groupName group was not created. Nothing was written.',
      );
    }

    for (final file in files) {
      final fileRef = project.fileRefIn(groupId, file);
      if (fileRef == null) {
        throw PbxprojException(
          '$file did not end up in the $groupName group. Nothing was written.',
        );
      }
      if (project.buildFileFor(phaseId, fileRef) == null) {
        throw PbxprojException(
          '$file was referenced but not added to the $targetName target\'s '
          'Sources phase, which would compile it into nothing. Nothing was '
          'written.',
        );
      }
    }
  }

  /// Deterministic 24-hex-digit object id, so re-running produces the same
  /// project file rather than a diff.
  static String _id(String seed) => md5
      .convert(utf8.encode('os_intents:$seed'))
      .toString()
      .substring(0, 24)
      .toUpperCase();
}

/// The edits to make, worked out against the parsed project before any text is
/// touched.
class _Plan {
  _Plan(this.project, {required this.phaseId, required this.appGroupId})
    : groupId =
          project.childGroupNamed(appGroupId, InstallCommand.groupName) ??
          InstallCommand._id('group:${InstallCommand.groupName}'),
      createGroup =
          project.childGroupNamed(appGroupId, InstallCommand.groupName) == null;

  final Pbxproj project;
  final String phaseId;
  final String appGroupId;
  final String groupId;
  final bool createGroup;

  final fileRefLines = <String>[];
  final buildFileLines = <String>[];
  final phaseEntries = <String>[];
  final groupChildren = <String>[];

  bool get isEmpty =>
      !createGroup &&
      fileRefLines.isEmpty &&
      buildFileLines.isEmpty &&
      phaseEntries.isEmpty &&
      groupChildren.isEmpty;

  /// Works out what [file] is still missing.
  ///
  /// Each of the four registrations is checked on its own, so a project left
  /// half-edited — a file reference with no build file, the state the old
  /// silent-no-op could produce — is repaired rather than skipped.
  void add(String file) {
    final existingRef = createGroup ? null : project.fileRefIn(groupId, file);
    final fileRef = existingRef ?? InstallCommand._id('ref:$file');

    if (project.object(fileRef) == null) {
      fileRefLines.add(
        '\t\t$fileRef /* $file */ = {isa = PBXFileReference; '
        'lastKnownFileType = sourcecode.swift; path = $file; '
        'sourceTree = "<group>"; };\n',
      );
    }
    if (existingRef == null) {
      groupChildren.add('\n\t\t\t\t$fileRef /* $file */,');
    }

    final existingBuild = project.buildFileFor(phaseId, fileRef);
    if (existingBuild != null) return;

    final buildFile = InstallCommand._id('build:$file');
    if (project.object(buildFile) == null) {
      buildFileLines.add(
        '\t\t$buildFile /* $file in Sources */ = {isa = PBXBuildFile; '
        'fileRef = $fileRef /* $file */; };\n',
      );
    }
    phaseEntries.add('\n\t\t\t\t$buildFile /* $file in Sources */,');
  }

  String apply(String text) {
    var out = text;
    if (fileRefLines.isNotEmpty) {
      out = _intoSection(out, 'PBXFileReference', fileRefLines.join());
    }
    if (buildFileLines.isNotEmpty) {
      out = _intoSection(out, 'PBXBuildFile', buildFileLines.join());
    }
    if (phaseEntries.isNotEmpty) {
      out = _intoList(out, phaseId, 'files', phaseEntries.join());
    }

    if (createGroup) {
      out = _intoSection(
        out,
        'PBXGroup',
        '\t\t$groupId /* ${InstallCommand.groupName} */ = {\n'
            '\t\t\tisa = PBXGroup;\n'
            '\t\t\tchildren = (${groupChildren.join()}\n'
            '\t\t\t);\n'
            '\t\t\tpath = ${InstallCommand.groupName};\n'
            '\t\t\tsourceTree = "<group>";\n'
            '\t\t};\n',
      );
      out = _intoList(
        out,
        appGroupId,
        'children',
        '\n\t\t\t\t$groupId /* ${InstallCommand.groupName} */,',
      );
    } else if (groupChildren.isNotEmpty) {
      out = _intoList(out, groupId, 'children', groupChildren.join());
    }
    return out;
  }

  /// Inserts [lines] at the top of a `/* Begin <isa> section */` block,
  /// creating the block when the project has none — a project with no Swift
  /// file yet has no `PBXBuildFile` section at all.
  static String _intoSection(String text, String isa, String lines) {
    final begin = '/* Begin $isa section */\n';
    if (text.contains(begin)) {
      return text.replaceFirst(begin, '$begin$lines');
    }
    final anchor = RegExp(r'objects\s*=\s*\{\n');
    final m = anchor.firstMatch(text);
    if (m == null) {
      throw PbxprojException(
        'The project has no $isa section and no objects dictionary to add one '
        'to.',
      );
    }
    return text.replaceRange(
      m.end,
      m.end,
      '\n$begin$lines/* End $isa section */\n',
    );
  }

  /// Inserts [entries] at the head of the `<key> = ( … )` list belonging to the
  /// object [id].
  ///
  /// Anchored on an id read out of the parsed project rather than on the shape
  /// of the surrounding text, which is the whole reason this rewrite exists.
  static String _intoList(String text, String id, String key, String entries) {
    final (start, end) = _objectRange(text, id);
    final list = RegExp(
      '\\b$key\\s*=\\s*\\(',
    ).firstMatch(text.substring(start, end));
    if (list == null) {
      throw PbxprojException(
        'Object $id has no "$key" list to add to, which is not a shape this '
        'tool knows how to edit.',
      );
    }
    final at = start + list.end;
    return text.replaceRange(at, at, entries);
  }

  /// Offsets of the body of the object [id], found by matching braces so a
  /// nested dictionary cannot end the search early.
  static (int, int) _objectRange(String text, String id) {
    final decl = RegExp(
      '^\\s*$id\\b[^\\n]*?=\\s*\\{',
      multiLine: true,
    ).firstMatch(text);
    if (decl == null) {
      throw PbxprojException(
        'Object $id is in the project but its definition could not be located '
        'in the text.',
      );
    }
    var depth = 0;
    var inQuotes = false;
    for (var i = decl.end - 1; i < text.length; i++) {
      final c = text[i];
      if (inQuotes) {
        if (c == r'\') {
          i++;
        } else if (c == '"') {
          inQuotes = false;
        }
        continue;
      }
      switch (c) {
        case '"':
          inQuotes = true;
        case '{':
          depth++;
        case '}':
          depth--;
          if (depth == 0) return (decl.end, i);
      }
    }
    throw PbxprojException('Object $id is never closed in project.pbxproj.');
  }
}
