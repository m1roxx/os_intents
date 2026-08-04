import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'android_manifest.dart';
import 'pbxproj.dart';
import 'sync.dart';

/// Makes the generated files reachable by the native builds.
///
/// Two one-time edits, one per platform, and they are the same kind of thing:
/// `sync` writes files the toolchain will happily ignore until the native
/// project is told they exist. On iOS that is the Runner target; on Android it
/// is the one `<meta-data>` element pointing the launcher activity at the
/// generated shortcuts.
///
/// Both are decided against a parsed project, applied as text so the diff stays
/// small, and parsed again before anything is written — because in both cases a
/// missed insertion produces a build that succeeds with no intents in it, which
/// looks exactly like success until someone tries to run one.
///
/// On iOS every anchor is an object id looked up in the parsed project: the ids
/// in Flutter's template are not a contract. Xcode 16 introduced synchronized
/// folder groups, which would make that half a one-liner, but they need
/// `objectVersion = 77` and Flutter still templates projects at 54. Bumping
/// that silently is not worth the risk, so the files are registered explicitly.
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
      )
      ..addFlag(
        'xcode',
        defaultsTo: true,
        help: 'Register ios/Runner/OsIntents with the Xcode target.',
      )
      ..addFlag(
        'manifest',
        defaultsTo: true,
        help:
            'Point the launcher activity at the generated shortcuts XML. That '
            'is the app-shortcuts layer, which is not gated — nothing to do '
            'with `sync --android`.',
      )
      ..addFlag(
        'check',
        negatable: false,
        help:
            'Report what is not registered yet; write nothing. Exits non-zero '
            'when something is missing — the companion to `sync --check`, and '
            'the half that catches a file generated but never compiled.',
      );
  }

  @override
  final String name = 'install';

  @override
  final String description =
      'Tell the native projects about the files sync generated.';

  /// Directory name the generated sources live in, under the app group.
  static final String groupName = p.basename(SyncCommand.outputDir);

  @override
  Future<int> run() async {
    final root = p.absolute(argResults!.option('project')!);
    final checkOnly = argResults!.flag('check');
    var attempted = 0;
    var worst = 0;

    // Each half is skipped when its platform is simply absent, so an iOS-only
    // app never has to know the Android half exists, and the other way round.
    if (argResults!.flag('xcode') && xcodeProject(root).existsSync()) {
      attempted++;
      final rc = _installXcode(
        root,
        argResults!.option('target')!,
        checkOnly: checkOnly,
      );
      // Writing stops at the first failure; checking does not, because a CI
      // report that hides the second platform behind the first is one round
      // trip per problem.
      if (rc != 0 && !checkOnly) return rc;
      if (rc != 0) worst = rc;
    }
    if (argResults!.flag('manifest') && androidManifest(root).existsSync()) {
      attempted++;
      final rc = _installManifest(root, checkOnly: checkOnly);
      if (rc != 0 && !checkOnly) return rc;
      if (rc != 0) worst = rc;
    }

    if (attempted == 0) {
      stderr.writeln(
        'Nothing to install under $root — it has neither ios/Runner.xcodeproj '
        'nor\nandroid/app/src/main/AndroidManifest.xml. Pass -C if the project '
        'is elsewhere.',
      );
      return 66;
    }
    if (worst != 0) {
      stderr.writeln('\nRun `dart run os_intents_cli:os_intents install`.');
    }
    return worst;
  }

  static File xcodeProject(String root) =>
      File(p.join(root, 'ios', 'Runner.xcodeproj', 'project.pbxproj'));

  static File androidManifest(String root) => File(
    p.join(root, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
  );

  /// Adds the generated shortcuts to the launcher activity.
  ///
  /// The Android counterpart of the Xcode half, and the smaller one: a single
  /// element, whose absence is the difference between a generated
  /// `shortcuts.xml` and shortcuts a user can actually see.
  int _installManifest(String root, {required bool checkOnly}) {
    // Refusing to write the meta-data before the resource exists is not
    // tidiness: aapt fails the build outright on a resource that is not there,
    // which is a much worse first experience than a note saying to run sync.
    final resource = File(
      p.join(root, 'android/app/src/main/res/xml/$shortcutsResource.xml'),
    );
    if (!resource.existsSync()) {
      stdout.writeln(
        'os_intents: no ${p.relative(resource.path, from: root)} yet, so '
        'AndroidManifest.xml is\nleft alone. Run `os_intents sync` first.',
      );
      return 0;
    }

    final manifest = androidManifest(root);
    final original = manifest.readAsStringSync();
    final String edited;
    try {
      edited = installShortcutsMetaData(original);
    } on AndroidManifestException catch (e) {
      stderr.writeln(
        'os_intents cannot edit ${p.relative(manifest.path, from: root)}:\n\n'
        '${e.message}\n\n'
        'Nothing was written. Adding it by hand works just as well — the rest '
        'of the\ntoolchain does not care how the line got there, and '
        '`os_intents doctor --device`\nreports what the system accepted either '
        'way.',
      );
      return 1;
    }

    if (identical(edited, original)) {
      stdout.writeln(
        'os_intents: the launcher activity already reads '
        '@xml/$shortcutsResource.',
      );
      return 0;
    }

    if (checkOnly) {
      stderr.writeln(
        '  missing: ${p.relative(manifest.path, from: root)} does not point '
        'its launcher\n           activity at @xml/$shortcutsResource, so '
        'Android never reads it.',
      );
      return 1;
    }

    File('${manifest.path}.os_intents.bak').writeAsStringSync(original);
    manifest.writeAsStringSync(edited);

    stdout
      ..writeln(
        'os_intents: the launcher activity now reads '
        '@xml/$shortcutsResource.',
      )
      ..writeln('Backup: ${p.basename(manifest.path)}.os_intents.bak');
    return 0;
  }

  int _installXcode(String root, String targetName, {required bool checkOnly}) {
    final pbx = xcodeProject(root);
    final pbxPath = pbx.path;

    // Whatever sync produced, rather than a hardcoded list — the set grows
    // (OsIntentsBackground.swift arrived with Execution.background) and a list
    // here would silently skip new files, leaving them uncompiled.
    final dir = Directory(p.join(root, SyncCommand.outputDir));
    final present = dir.existsSync()
        ? (dir.listSync().whereType<File>().toList()
                ..sort((a, b) => a.path.compareTo(b.path)))
              .map((f) => p.basename(f.path))
              .where((f) => _Kind.of(f) != null)
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

    if (checkOnly) {
      stderr
        ..writeln(
          '  missing: $targetName does not compile these, so they reach the '
          'build as nothing:',
        )
        ..writeAll(
          notCompiled(
            original,
            files: present,
            targetName: targetName,
          ).map((f) => '    • $f\n'),
        );
      return 1;
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

  /// Which of [files] the project does not currently compile into [targetName].
  ///
  /// Both halves have to hold: a file reference in the group *and* a build file
  /// in the Sources phase. Half of that is what a project left mid-edit looks
  /// like, and it builds cleanly while the file reaches the app as nothing.
  static List<String> notCompiled(
    String text, {
    required List<String> files,
    String targetName = 'Runner',
  }) {
    final project = Pbxproj.parse(text);
    final targetId = project.nativeTargetNamed(targetName);
    final mainGroupId = project.mainGroupId;
    final appGroupId = mainGroupId == null
        ? null
        : project.childGroupNamed(mainGroupId, targetName);
    final groupId = appGroupId == null
        ? null
        : project.childGroupNamed(appGroupId, groupName);
    if (targetId == null || groupId == null) return files;

    return [
      for (final file in files)
        if (switch ((
          _Kind.of(file)?.phaseIn(project, targetId),
          project.fileRefIn(groupId, file),
        )) {
          (null, _) => true,
          (_, null) => true,
          (final phase?, final ref?) =>
            project.buildFileFor(phase, ref) == null,
        })
          file,
    ];
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

    // One phase per kind of output. A String Catalogue in the Sources phase is
    // not an error Xcode reports: it simply never reaches the bundle, every
    // lookup falls back to the key, and the app ships "addTask.title" to Siri.
    for (final kind in _Kind.needed(files)) {
      if (kind.phaseIn(project, targetId) == null) {
        throw PbxprojException(
          'Target "$targetName" has no ${kind.label} build phase, so there is '
          'nothing to add ${kind.what} to.',
        );
      }
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

    final plan = _Plan(project, targetId: targetId, appGroupId: appGroupId);
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
      final kind = _Kind.of(file)!;
      if (project.buildFileFor(kind.phaseIn(project, targetId)!, fileRef) ==
          null) {
        throw PbxprojException(
          '$file was referenced but not added to the $targetName target\'s '
          '${kind.label} phase, which would ${kind.whenMissing}. Nothing was '
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
  _Plan(this.project, {required this.targetId, required this.appGroupId})
    : groupId =
          project.childGroupNamed(appGroupId, InstallCommand.groupName) ??
          InstallCommand._id('group:${InstallCommand.groupName}'),
      createGroup =
          project.childGroupNamed(appGroupId, InstallCommand.groupName) == null;

  final Pbxproj project;
  final String targetId;
  final String appGroupId;
  final String groupId;
  final bool createGroup;

  final fileRefLines = <String>[];
  final buildFileLines = <String>[];

  /// Phase object id → the entries to append to its `files` list.
  ///
  /// Keyed rather than a single list because the generated output is no longer
  /// all one kind: Swift compiles and a String Catalogue is bundled, and the
  /// two go into different phases of the same target.
  final phaseEntries = <String, List<String>>{};

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
    final kind = _Kind.of(file);
    if (kind == null) return;
    final phaseId = kind.phaseIn(project, targetId)!;

    final existingRef = createGroup ? null : project.fileRefIn(groupId, file);
    final fileRef = existingRef ?? InstallCommand._id('ref:$file');

    if (project.object(fileRef) == null) {
      fileRefLines.add(
        '\t\t$fileRef /* $file */ = {isa = PBXFileReference; '
        'lastKnownFileType = ${kind.fileType}; path = $file; '
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
        '\t\t$buildFile /* $file in ${kind.label} */ = {isa = PBXBuildFile; '
        'fileRef = $fileRef /* $file */; };\n',
      );
    }
    phaseEntries
        .putIfAbsent(phaseId, () => [])
        .add('\n\t\t\t\t$buildFile /* $file in ${kind.label} */,');
  }

  String apply(String text) {
    var out = text;
    if (fileRefLines.isNotEmpty) {
      out = _intoSection(out, 'PBXFileReference', fileRefLines.join());
    }
    if (buildFileLines.isNotEmpty) {
      out = _intoSection(out, 'PBXBuildFile', buildFileLines.join());
    }
    for (final entry in phaseEntries.entries) {
      out = _intoList(out, entry.key, 'files', entry.value.join());
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

/// What a generated file is, which decides where in the target it goes.
///
/// Not cosmetic. Both phases fail the same silent way when a file lands in the
/// wrong one — Xcode reports nothing, the build succeeds, and the thing simply
/// is not there. A Swift file outside Sources compiles into nothing and the OS
/// never sees the intent; a String Catalogue outside Resources never reaches
/// the bundle and every lookup falls back to its key, so the app shows
/// "addTask.title" where the title should be.
enum _Kind {
  source(
    isa: 'PBXSourcesBuildPhase',
    label: 'Sources',
    fileType: 'sourcecode.swift',
    what: 'the generated Swift',
    whenMissing: 'compile it into nothing',
  ),
  resource(
    isa: 'PBXResourcesBuildPhase',
    label: 'Resources',
    fileType: 'text.json.xcstrings',
    what: 'the generated String Catalogue',
    whenMissing: 'leave every string showing its key',
  );

  const _Kind({
    required this.isa,
    required this.label,
    required this.fileType,
    required this.what,
    required this.whenMissing,
  });

  final String isa;
  final String label;
  final String fileType;
  final String what;
  final String whenMissing;

  String? phaseIn(Pbxproj project, String targetId) =>
      project.phaseOf(targetId, isa);

  /// Null for anything os_intents does not put in the project, so a stray file
  /// somebody left in the directory is skipped rather than registered.
  static _Kind? of(String file) {
    if (file.endsWith('.swift')) return _Kind.source;
    if (file.endsWith('.xcstrings')) return _Kind.resource;
    return null;
  }

  static Set<_Kind> needed(List<String> files) => {
    for (final f in files) ?of(f),
  };
}
