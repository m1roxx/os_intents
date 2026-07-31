/// `os_intents doctor` — the only thing in the toolchain that answers "did the
/// intents actually reach the built app?".
///
/// Everything else reports on its own step. `build_runner` says it generated
/// Dart, `sync` says it wrote Swift, Xcode says it compiled — and an intent can
/// still be invisible to the OS after all three, because the generated sources
/// were never added to the target, or a second `AppShortcutsProvider` won and
/// took the phrases with it. Neither failure produces an error anywhere.
///
/// So doctor reads the extracted metadata out of a built bundle and compares it
/// against the manifests, which is the only comparison that can catch this.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:args/command_runner.dart';
import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:path/path.dart' as p;

import 'actions_data.dart';
import 'doctor_android.dart';
import 'manifests.dart';
import 'sync.dart';

enum Severity {
  error('error'),
  warning('warning'),
  note('note');

  const Severity(this.label);

  final String label;
}

class Finding {
  Finding(this.severity, this.summary, [this.detail]);

  final Severity severity;
  final String summary;

  /// Why it happened and what to do — printed indented under [summary].
  final String? detail;
}

/// The generated provider's type name. A different one in
/// `autoShortcutProviderMangledName` means Apple selected someone else's, and
/// every phrase os_intents emitted was dropped in silence.
const _generatedProviderName = 'OsIntentsShortcuts';

/// Compares what Dart declared against what the bundle carries.
///
/// Pure, so the interesting half of doctor is testable without Xcode or a
/// device — the same reason the emitters take a [Manifest] and return strings.
///
/// [declared] is null when doctor runs outside a Flutter project, in which case
/// the bundle is described but nothing can be cross-checked.
List<Finding> diagnose({
  required Manifest? declared,
  required AppIntentsMetadata shipped,
  required bool hasSpokenPhraseFile,
}) {
  final findings = <Finding>[];

  if (declared == null) {
    findings.add(
      Finding(
        Severity.note,
        'No manifests found, so this is what the bundle holds, not a comparison.',
        'Run doctor from the Flutter project root (or pass -C) to check the '
            'bundle against the intents declared in Dart.',
      ),
    );
  }

  final intents = declared?.intents ?? const <IntentSpec>[];
  final declaresPhrases = intents.any((i) => i.phrases.isNotEmpty);

  for (final intent in intents) {
    final action = shipped.action(intent.swiftTypeName);
    if (action == null) {
      findings.add(
        Finding(
          Severity.error,
          '"${intent.id}" is declared in Dart but is not in the bundle.',
          'The OS cannot run it. Either ${SyncCommand.outputDir}/'
              '${intent.swiftTypeName}.swift was never generated — re-run '
              'build_runner and `os_intents sync` — or the directory is not a '
              'member of the Runner target, in which case the whole thing '
              'compiles into nothing.',
        ),
      );
      continue;
    }

    for (final param in intent.params) {
      final got = action.params.where((p) => p.name == param.name).firstOrNull;
      if (got == null) {
        findings.add(
          Finding(
            Severity.error,
            'Intent "${intent.id}" declares parameter "${param.name}", which '
                'the bundle does not have.',
            'The generated Swift in the app is older than the manifest. '
                'Re-run `os_intents sync` and rebuild.',
          ),
        );
        continue;
      }
      if (got.isOptional != !param.isRequired) {
        findings.add(
          Finding(
            Severity.warning,
            'Parameter "${param.name}" of "${intent.id}" is '
                '${param.isRequired ? "required" : "optional"} in Dart but '
                '${got.isOptional ? "optional" : "required"} in the bundle.',
            'A stale build, most likely. Rebuild and check again.',
          ),
        );
      }
    }

    if (intent.execution != ExecutionMode.foreground && action.opensApp) {
      findings.add(
        Finding(
          Severity.error,
          '"${intent.id}" is Execution.${intent.execution.wire} but the bundle '
              'says it opens the app.',
          'The point of a background intent is that it answers without a UI. '
              'This is the built app disagreeing with the manifest — rebuild.',
        ),
      );
    }

    if (intent.showsInSpotlight && !action.isDiscoverable) {
      findings.add(
        Finding(
          Severity.warning,
          '"${intent.id}" asks to appear in Spotlight, but the bundle marks it '
          'undiscoverable.',
        ),
      );
    }

    if (intent.phrases.isEmpty) continue;

    final shortcut = shipped.shortcutFor(intent.swiftTypeName);
    if (shortcut == null) {
      findings.add(
        Finding(
          Severity.error,
          '"${intent.id}" declares ${intent.phrases.length} phrase(s), and none '
          'of them is in the bundle.',
          _providerHint(shipped),
        ),
      );
      continue;
    }

    final got = shortcut.phrases.toSet();
    final missing = [
      for (final phrase in intent.phrases)
        if (!got.contains(_expandAppPlaceholder(phrase))) phrase,
    ];
    if (missing.isNotEmpty) {
      findings.add(
        Finding(
          Severity.error,
          'Phrase(s) on "${intent.id}" did not reach the bundle: '
              '${missing.map((p) => '"$p"').join(', ')}.',
          'Siri will not match them. The built app is probably older than the '
              'generated provider — rebuild and check again.',
        ),
      );
    }
  }

  for (final entity in declared?.entities ?? const <EntitySpec>[]) {
    if (!shipped.hasEntity(entity.swiftTypeName)) {
      findings.add(
        Finding(
          Severity.error,
          'Entity "${entity.typeName}" is declared in Dart but is not in the '
              'bundle.',
          'Any intent taking it as a parameter cannot be resolved.',
        ),
      );
      continue;
    }
    if (entity.hasQuery && shipped.queryFor(entity.swiftTypeName) == null) {
      findings.add(
        Finding(
          Severity.error,
          'Entity "${entity.typeName}" has an @EntityQuery in Dart, but the '
              'bundle carries no query for it.',
          'The system has no way to turn a spoken or typed name into a '
              '${entity.dartClassName}, so the parameter can never be filled.',
        ),
      );
    }
  }

  // Reported once rather than per intent: every phrase-bearing intent would
  // otherwise repeat the same sentence.
  if (declaresPhrases && !hasSpokenPhraseFile) {
    findings.add(
      Finding(
        Severity.error,
        'The bundle has no root.ssu.yaml, so no phrase was registered with '
            'Siri.',
        'The intents still run from Shortcuts and Spotlight; "Hey Siri" will '
            'not reach them. ${_providerHint(shipped)}',
      ),
    );
  }

  final provider = shipped.providerMangledName;
  if (provider != null &&
      !demangleSwiftTypeName(provider).endsWith('.$_generatedProviderName') &&
      declaresPhrases) {
    findings.add(
      Finding(
        Severity.error,
        'The selected AppShortcutsProvider is '
            '${demangleSwiftTypeName(provider)}, not $_generatedProviderName.',
        'iOS selects exactly one provider per app and drops the others without '
            'a word. Move your phrases into @AppIntent annotations, or delete '
            'the other provider.',
      ),
    );
  }

  // Intents the app declares by hand are perfectly legal; saying so avoids
  // reading the inventory as if os_intents produced all of it.
  if (declared != null) {
    final ours = {for (final i in intents) i.swiftTypeName};
    final theirs = [
      for (final a in shipped.actions)
        if (!ours.contains(a.identifier)) a.identifier,
    ];
    if (theirs.isNotEmpty) {
      findings.add(
        Finding(
          Severity.note,
          'The bundle also carries ${theirs.length} intent(s) os_intents did '
          'not generate: ${theirs.join(', ')}.',
        ),
      );
    }
  }

  return findings;
}

/// The Swift emitter writes `$app` as `\(.applicationName)`, which the metadata
/// processor extracts as `${applicationName}`.
String _expandAppPlaceholder(String phrase) =>
    phrase.replaceAll(r'$app', r'${applicationName}');

String _providerHint(AppIntentsMetadata shipped) {
  final provider = shipped.providerMangledName;
  if (provider == null) {
    return 'No AppShortcutsProvider was selected at all, which means '
        '${SyncCommand.outputDir}/$_generatedProviderName.swift is not '
        'compiled into the Runner target. Add the directory to the target in '
        'Xcode as a synchronized folder, or run `os_intents install`.';
  }
  final name = demangleSwiftTypeName(provider);
  if (!name.endsWith('.$_generatedProviderName')) {
    return 'iOS selected $name instead, and it drops every other provider in '
        'silence. Move the phrases into @AppIntent annotations, or delete that '
        'provider.';
  }
  return 'The provider $name was selected, so the app is probably older than '
      'the generated Swift — rebuild and check again.';
}

class DoctorCommand extends Command<int> {
  DoctorCommand() {
    argParser
      ..addOption(
        'project',
        abbr: 'C',
        help:
            'Flutter project root, used to find the manifests to check '
            'against.',
        defaultsTo: '.',
      )
      ..addOption(
        'app',
        help:
            'Path to a built .app bundle. Defaults to the most recent build '
            'under build/ios.',
      )
      ..addFlag(
        'android',
        negatable: false,
        help:
            'Inspect a built APK instead: which AppFunctions an agent will be '
            'offered, and whether the shortcuts XML was packaged.',
      )
      ..addOption(
        'apk',
        help:
            'Path to a built .apk. Implies --android. Defaults to the most '
            'recent build under build/app/outputs.',
      );
  }

  @override
  final String name = 'doctor';

  @override
  final String description =
      'Inspect a built app and report which intents, entities and phrases the '
      'OS will see.';

  /// Where `flutter build` leaves a bundle, newest layout first.
  static const _candidates = [
    'build/ios/iphonesimulator/Runner.app',
    'build/ios/Debug-iphonesimulator/Runner.app',
    'build/ios/Release-iphonesimulator/Runner.app',
    'build/ios/iphoneos/Runner.app',
    'build/ios/Debug-iphoneos/Runner.app',
    'build/ios/Release-iphoneos/Runner.app',
  ];

  /// Where `flutter build apk` leaves an APK, newest layout first.
  static const _apkCandidates = [
    'build/app/outputs/flutter-apk/app-debug.apk',
    'build/app/outputs/flutter-apk/app-release.apk',
    'build/app/outputs/apk/debug/app-debug.apk',
    'build/app/outputs/apk/release/app-release.apk',
  ];

  @override
  Future<int> run() async {
    final root = p.absolute(argResults!.option('project')!);

    if (argResults!.flag('android') || argResults!.option('apk') != null) {
      return _runAndroid(root);
    }

    final explicit = argResults!.option('app');
    final bundle = explicit != null
        ? Directory(p.isAbsolute(explicit) ? explicit : p.join(root, explicit))
        : _newestBundle(root);

    if (bundle == null) {
      stderr.writeln(
        'No built app found under ${p.join(root, 'build/ios')}.\n'
        'Build one first:\n'
        '  flutter build ios --simulator --debug\n'
        'or point doctor at a bundle with --app.',
      );
      return 66;
    }
    if (!bundle.existsSync()) {
      stderr.writeln('No app bundle at ${bundle.path}.');
      return 66;
    }

    final metaDir = Directory(p.join(bundle.path, 'Metadata.appintents'));
    final actionsFile = File(p.join(metaDir.path, 'extract.actionsdata'));
    if (!actionsFile.existsSync()) {
      stderr.writeln(
        '${p.relative(bundle.path, from: root)} has no '
        'Metadata.appintents/extract.actionsdata.\n\n'
        'Nothing was extracted, which almost always means the generated Swift '
        'is not compiled into\nthe Runner target. Add ${SyncCommand.outputDir} '
        'to the target in Xcode as a synchronized\nfolder — or run '
        '`os_intents install` — then rebuild.',
      );
      return 1;
    }

    final AppIntentsMetadata shipped;
    try {
      shipped = AppIntentsMetadata.parse(actionsFile.readAsStringSync());
    } on FormatException catch (e) {
      stderr.writeln('Could not read ${actionsFile.path}:\n  ${e.message}');
      return 65;
    }

    final List<Manifest> manifests;
    try {
      manifests = readManifests(root);
    } on ManifestReadException catch (e) {
      stderr.writeln('${p.relative(e.path, from: root)}: ${e.message}');
      return 65;
    }
    final declared = manifests.isEmpty ? null : Manifest.merge(manifests);

    final hasSsu = File(p.join(metaDir.path, 'root.ssu.yaml')).existsSync();

    _report(root, bundle, shipped, declared, hasSsu: hasSsu);

    final findings = [
      ...diagnose(
        declared: declared,
        shipped: shipped,
        hasSpokenPhraseFile: hasSsu,
      ),
      // Appended rather than part of diagnose: staleness is a fact about files
      // on disk, and diagnose stays pure so it can be tested without any.
      ?_stalenessWarning(root, actionsFile),
    ];
    _printFindings(findings);

    final errors = findings.where((f) => f.severity == Severity.error).length;
    return errors == 0 ? 0 : 1;
  }

  Future<int> _runAndroid(String root) async {
    final explicit = argResults!.option('apk');
    final apk = explicit != null
        ? File(p.isAbsolute(explicit) ? explicit : p.join(root, explicit))
        : _newestApk(root);

    if (apk == null) {
      stderr.writeln(
        'No built APK found under ${p.join(root, 'build/app/outputs')}.\n'
        'Build one first:\n'
        '  flutter build apk --debug\n'
        'or point doctor at one with --apk.',
      );
      return 66;
    }
    if (!apk.existsSync()) {
      stderr.writeln('No APK at ${apk.path}.');
      return 66;
    }

    final ApkInspection inspection;
    try {
      inspection = inspectApk(apk);
    } on ArchiveException catch (e) {
      stderr.writeln('Could not read ${p.relative(apk.path, from: root)}: $e');
      return 65;
    }

    final List<Manifest> manifests;
    try {
      manifests = readManifests(root);
    } on ManifestReadException catch (e) {
      stderr.writeln('${p.relative(e.path, from: root)}: ${e.message}');
      return 65;
    }
    final declared = manifests.isEmpty ? null : Manifest.merge(manifests);

    reportAndroid(root, apk, inspection);

    final findings = diagnoseAndroid(declared: declared, apk: inspection);
    _printFindings(findings, artefact: 'APK');

    final errors = findings.where((f) => f.severity == Severity.error).length;
    return errors == 0 ? 0 : 1;
  }

  /// Picks the APK most likely to be the one just built.
  File? _newestApk(String root) {
    File? best;
    DateTime? bestAt;
    for (final rel in _apkCandidates) {
      final file = File(p.join(root, rel));
      if (!file.existsSync()) continue;
      final at = file.lastModifiedSync();
      if (bestAt == null || at.isAfter(bestAt)) {
        best = file;
        bestAt = at;
      }
    }
    return best;
  }

  /// Picks the bundle most likely to be the one just built.
  Directory? _newestBundle(String root) {
    Directory? best;
    DateTime? bestAt;
    for (final rel in _candidates) {
      final dir = Directory(p.join(root, rel));
      if (!dir.existsSync()) continue;
      final marker = File(
        p.join(dir.path, 'Metadata.appintents', 'extract.actionsdata'),
      );
      final at = marker.existsSync()
          ? marker.lastModifiedSync()
          : dir.statSync().modified;
      if (bestAt == null || at.isAfter(bestAt)) {
        best = dir;
        bestAt = at;
      }
    }
    return best;
  }

  /// Metadata older than the Swift it was extracted from describes a previous
  /// build, and a report from one is worse than no report: it looks like proof.
  ///
  /// Only meaningful when the bundle was built from this project — a bundle
  /// passed in with `--app` from somewhere else has no relationship to these
  /// timestamps.
  Finding? _stalenessWarning(String root, File actionsFile) {
    if (!p.isWithin(root, actionsFile.path)) return null;

    final generated = Directory(p.join(root, SyncCommand.outputDir));
    if (!generated.existsSync()) return null;

    DateTime? newest;
    String? newestPath;
    for (final f in generated.listSync().whereType<File>()) {
      if (!f.path.endsWith('.swift')) continue;
      final at = f.lastModifiedSync();
      if (newest == null || at.isAfter(newest)) {
        newest = at;
        newestPath = f.path;
      }
    }
    if (newest == null) return null;
    if (!newest.isAfter(actionsFile.lastModifiedSync())) return null;

    return Finding(
      Severity.warning,
      'This bundle is older than the generated Swift.',
      '${p.relative(newestPath!, from: root)} changed after the app was built, '
          'so everything above describes the previous build. Rebuild, then run '
          'doctor again.',
    );
  }

  void _report(
    String root,
    Directory bundle,
    AppIntentsMetadata shipped,
    Manifest? declared, {
    required bool hasSsu,
  }) {
    final out = StringBuffer()
      ..writeln('os_intents doctor')
      ..writeln('  bundle    ${p.relative(bundle.path, from: root)}');
    if (shipped.generator case final g?) {
      out.writeln('  extracted by $g (format ${shipped.formatVersion ?? "?"})');
    }
    if (declared != null) {
      out.writeln(
        '  declared  ${declared.intents.length} intent(s), '
        '${declared.entities.length} entity(ies) in Dart',
      );
    }
    out.writeln();

    out.writeln('Intents the OS will see (${shipped.actions.length})');
    if (shipped.actions.isEmpty) {
      out.writeln('  none');
    }
    for (final a in shipped.actions) {
      final flags = [
        if (a.opensApp) 'opens the app' else 'runs without opening the app',
        if (!a.isDiscoverable) 'hidden from Shortcuts and Spotlight',
      ];
      out.writeln('  ${a.identifier}  "${a.title ?? '<no title>'}"');
      if (a.description case final d?) out.writeln('      $d');
      out.writeln('      ${flags.join(', ')}');
      for (final param in a.params) {
        out.writeln(
          '      ${param.name.padRight(14)}${param.typeLabel.padRight(16)}'
          '${param.isOptional ? 'optional' : 'required'}',
        );
      }
    }
    out.writeln();

    out.writeln('Entities (${shipped.entities.length})');
    if (shipped.entities.isEmpty) out.writeln('  none');
    for (final e in shipped.entities) {
      final query = e.defaultQueryIdentifier;
      out.writeln(
        '  ${e.typeName}  "${e.displayName ?? e.typeName}"  '
        '${query == null ? 'no query — cannot be resolved by name' : 'resolved by $query'}',
      );
    }
    out.writeln();

    final phraseCount = shipped.autoShortcuts.fold<int>(
      0,
      (n, s) => n + s.phrases.length,
    );
    final provider = shipped.providerMangledName;
    out.writeln(
      'Spoken phrases ($phraseCount'
      '${provider == null ? ', no provider selected' : ' via ${demangleSwiftTypeName(provider)}'})',
    );
    if (shipped.autoShortcuts.isEmpty) out.writeln('  none');
    for (final s in shipped.autoShortcuts) {
      out.writeln('  ${s.actionIdentifier}');
      for (final phrase in s.phrases) {
        out.writeln('      "$phrase"');
      }
    }
    out.writeln(
      '  root.ssu.yaml  ${hasSsu ? 'present — Siri has the phrase model' : 'MISSING — nothing was registered with Siri'}',
    );

    stdout.write(out);
  }

  void _printFindings(List<Finding> findings, {String artefact = 'bundle'}) {
    if (findings.isEmpty) {
      stdout
        ..writeln()
        ..writeln('Everything declared in Dart reached the $artefact.');
      return;
    }
    stdout.writeln();
    for (final f in findings) {
      stdout.writeln('${f.severity.label}: ${f.summary}');
      if (f.detail case final d?) {
        for (final line in _wrap(d, 76)) {
          stdout.writeln('  $line');
        }
      }
    }
  }

  /// Hard-wrapped rather than left to the terminal, so the two-space indent
  /// that ties a detail to its finding survives.
  static List<String> _wrap(String text, int width) {
    final lines = <String>[];
    final buf = StringBuffer();
    for (final word in text.split(RegExp(r'\s+'))) {
      if (buf.isNotEmpty && buf.length + 1 + word.length > width) {
        lines.add(buf.toString());
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(word);
    }
    if (buf.isNotEmpty) lines.add(buf.toString());
    return lines;
  }
}
