/// `doctor --android`: what will an on-device agent actually see?
///
/// The Android half of the same question the iOS doctor answers, and it exists
/// for the same reason. Every other step reports on itself — `build_runner`
/// says it generated Dart, `sync` says it wrote Kotlin, Gradle says it
/// compiled — and the functions can still be invisible, because the service
/// never reached the merged manifest or because the metadata was never
/// packaged. None of those produce an error anywhere.
///
/// So this reads the built APK rather than the sources. `sync --check` already
/// proves the files on disk match the manifest; only the artifact can say they
/// arrived.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:os_intents_gen/os_intents_gen.dart';
import 'package:path/path.dart' as p;

import 'app_functions_xml.dart';
import 'doctor.dart';

/// The generated shortcuts file, compiled into the APK as binary XML.
///
/// Only its presence is checked. The contents are already guaranteed by
/// `sync --check`, and decoding Android's binary XML to re-derive them would
/// be a lot of machinery for an answer we have.
const shortcutsResPath = 'res/xml/os_intents_shortcuts.xml';

/// What the APK turned out to contain.
class ApkInspection {
  ApkInspection({
    required this.appFunctions,
    required this.hasShortcutsXml,
    required this.appFunctionsError,
  });

  /// Null when the APK carries no AppFunctions metadata at all, which is the
  /// normal state for an app that never ran `sync --android`.
  final AppFunctionsMetadata? appFunctions;

  final bool hasShortcutsXml;

  /// Set when the metadata was present but unreadable — kept apart from
  /// "absent", because they call for opposite advice.
  final String? appFunctionsError;
}

/// Reads the two things os_intents puts into an APK.
ApkInspection inspectApk(File apk) {
  final archive = ZipDecoder().decodeBytes(apk.readAsBytesSync());

  final hasShortcuts = archive.files.any(
    (f) => f.isFile && f.name == shortcutsResPath,
  );

  final entry = archive.files
      .where((f) => f.isFile && f.name == appFunctionsAssetPath)
      .firstOrNull;
  if (entry == null) {
    return ApkInspection(
      appFunctions: null,
      hasShortcutsXml: hasShortcuts,
      appFunctionsError: null,
    );
  }

  try {
    final text = String.fromCharCodes(entry.content as List<int>);
    return ApkInspection(
      appFunctions: parseAppFunctionsXml(text),
      hasShortcutsXml: hasShortcuts,
      appFunctionsError: null,
    );
  } on AppFunctionsFormatException catch (e) {
    return ApkInspection(
      appFunctions: null,
      hasShortcutsXml: hasShortcuts,
      appFunctionsError: e.message,
    );
  }
}

/// Compares what the APK carries against what Dart declared.
///
/// Pure, like the iOS `diagnose`, so the interesting cases can be tested
/// without building an app.
List<Finding> diagnoseAndroid({
  required Manifest? declared,
  required ApkInspection apk,
}) {
  final findings = <Finding>[];

  if (declared == null) {
    findings.add(
      Finding(
        Severity.error,
        'No manifests found — nothing to check the APK against.',
        'Run `dart run build_runner build` first; doctor compares the built '
            'app against what your annotations declared.',
      ),
    );
    return findings;
  }

  final headless = declared.intents
      .where((i) => i.needsHeadlessEngine)
      .toList();
  final wantsShortcuts = declared.intents.any((i) => i.hasAndroidShortcut);

  if (wantsShortcuts && !apk.hasShortcutsXml) {
    findings.add(
      Finding(
        Severity.error,
        'No $shortcutsResPath in the APK, but '
            '${declared.intents.where((i) => i.hasAndroidShortcut).length} '
            'intent(s) ask for a shortcut or a capability.',
        'Run `os_intents sync`, then rebuild. If it was generated but never '
            'packaged, check that the file is under android/app/src/main/res/xml.',
      ),
    );
  }

  if (apk.appFunctionsError case final message?) {
    findings.add(
      Finding(
        Severity.error,
        'The AppFunctions metadata is present but could not be read.',
        '$message\nandroidx.appfunctions is alpha; if its schema moved, this '
            'reader has to catch up before doctor can vouch for anything here.',
      ),
    );
    return findings;
  }

  final shipped = apk.appFunctions;
  if (shipped == null) {
    if (headless.isNotEmpty) {
      findings.add(
        Finding(
          Severity.note,
          '${headless.length} intent(s) could run headless, but the APK has no '
              'AppFunctions metadata.',
          'That is the default: AppFunctions is opt-in behind '
              '`os_intents sync --android`, because it forces compileSdk 37, AGP '
              '9.1.1 and Gradle 9.3.1 on your app. Without it these intents still '
              'work — through the shortcut, which opens the app.',
        ),
      );
    }
    return findings;
  }

  final byName = {for (final f in shipped.functions) f.functionName: f};

  for (final intent in headless) {
    final fn = byName[intent.id];
    if (fn == null) {
      findings.add(
        Finding(
          Severity.error,
          '`${intent.id}` is declared with Execution.'
              '${intent.execution.name} but is not in the APK\'s AppFunction '
              'metadata.',
          'It will not be offered to an agent. Re-run '
              '`os_intents sync --android` and rebuild.',
        ),
      );
      continue;
    }

    if (!fn.enabledByDefault) {
      findings.add(
        Finding(
          Severity.warning,
          '`${intent.id}` is packaged but not enabled by default.',
          'An agent will not see it until something enables it at run time.',
        ),
      );
    }

    if (intent.description != null && fn.description != intent.description) {
      findings.add(
        Finding(
          Severity.warning,
          'The description of `${intent.id}` in the APK is not the one in '
              'Dart.',
          'Dart: "${intent.description}"\nAPK:  "${fn.description ?? '(none)'}"'
              '\nDescriptions travel as KDoc, so this usually means a stale build.',
        ),
      );
    }

    final params = shipped.parametersOf(fn);
    if (params == null) continue;
    final props = {for (final prop in params.properties) prop.name: prop};

    for (final declaredParam in intent.params) {
      final prop = props[declaredParam.name];
      if (prop == null) {
        findings.add(
          Finding(
            Severity.error,
            'Parameter `${declaredParam.name}` of `${intent.id}` is missing '
                'from the APK.',
            'An agent cannot supply a value nothing declares.',
          ),
        );
        continue;
      }
      if (prop.isEffectivelyRequired != declaredParam.isRequired) {
        findings.add(
          Finding(
            Severity.warning,
            'Parameter `${declaredParam.name}` of `${intent.id}` is '
                '${declaredParam.isRequired ? 'required' : 'optional'} in Dart but '
                '${prop.isEffectivelyRequired ? 'required' : 'optional'} in the '
                'APK.',
            'A nullable property counts as optional however it is listed in '
                '<required>, which is what the runtime enforces.',
          ),
        );
      }
    }
  }

  // The other direction: something in the APK that Dart no longer declares.
  final declaredIds = headless.map((i) => i.id).toSet();
  for (final fn in shipped.functions) {
    if (declaredIds.contains(fn.functionName)) continue;
    findings.add(
      Finding(
        Severity.warning,
        '`${fn.functionName}` is in the APK but no longer declared in Dart.',
        'Left over from an earlier build. Agents may still offer it, and '
            'invoking it will fail. Re-run `os_intents sync --android` and do a '
            'clean rebuild.',
      ),
    );
  }

  return findings;
}

/// Prints what an agent will be offered.
void reportAndroid(String root, File apk, ApkInspection inspection) {
  final rel = p.relative(apk.path, from: root);
  stdout.writeln('Reading $rel\n');

  final shipped = inspection.appFunctions;
  if (shipped == null || shipped.functions.isEmpty) {
    stdout.writeln('AppFunctions the OS will see: none');
  } else {
    stdout.writeln(
      'AppFunctions the OS will see (${shipped.functions.length})',
    );
    for (final fn in shipped.functions) {
      stdout.writeln('  ${fn.functionName}');
      if (fn.description case final d?) stdout.writeln('      $d');
      if (!fn.enabledByDefault) {
        stdout.writeln('      not enabled by default');
      }
      final params = shipped.parametersOf(fn);
      for (final prop in params?.properties ?? const <AppFunctionProperty>[]) {
        // The emitter synthesises this one for a function that takes nothing;
        // it is an artefact of the API, not something the user wrote.
        if (prop.name == 'unused') continue;
        final need = prop.isEffectivelyRequired ? 'required' : 'optional';
        stdout.writeln(
          '      ${prop.name.padRight(14)}${prop.typeLabel.padRight(16)}$need',
        );
      }
    }
  }

  stdout.writeln(
    '\nApp shortcuts XML: ${inspection.hasShortcutsXml ? 'packaged' : 'absent'}',
  );
}
