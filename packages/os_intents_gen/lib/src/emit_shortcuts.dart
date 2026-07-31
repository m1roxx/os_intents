/// Emits the Android app-shortcuts layer: `res/xml` and the strings it needs.
///
/// The default Android path, and the counterpart of the Swift emitter rather
/// than of the Kotlin one. `KotlinEmitter` produces AppFunctions, which run
/// headless but drag `compileSdk 37`, AGP 9.1.1 and Gradle 9.3.1 into every
/// consuming app for something only Android 16+ can run. This costs nothing —
/// measured on a stock `flutter create` project before any of it was written.
///
/// What it buys is different, and the difference is not cosmetic: a shortcut's
/// `<intent>` starts an Activity, so **this layer always opens the app**.
/// `Execution.background` does not mean headless here. That is the platform,
/// not a shortcoming of the emitter — Android offers no way to answer from
/// `shortcuts.xml` without a UI.
library;

import 'model.dart';

/// Action every generated shortcut carries.
///
/// One action for all of them, with the intent id in the data URI, because a
/// shortcut names its target component explicitly — so no `<intent-filter>` is
/// needed and the manifest change stays a single `<meta-data>` element. Both a
/// URI and a nested `<extra>` were measured to survive; the URI wins for being
/// legible in `adb` output when an invocation goes astray.
const String androidShortcutAction = 'dev.osintents.action.RUN';

/// Scheme of the data URI that carries the intent id.
const String androidShortcutScheme = 'osintents';

class ShortcutsEmitter {
  ShortcutsEmitter(
    this.manifest, {
    required this.applicationId,
    required this.activityClass,
  });

  final Manifest manifest;

  /// The app's `applicationId`, used as `android:targetPackage`.
  final String applicationId;

  /// Fully qualified launcher Activity, used as `android:targetClass`.
  final String activityClass;

  /// Where the emitted files go, relative to `android/app/src/main/res`.
  static const shortcutsFile = 'xml/os_intents_shortcuts.xml';
  static const stringsFile = 'values/os_intents_strings.xml';

  List<IntentSpec> get _exposed => [
    for (final i in manifest.intents)
      if (i.hasAndroidShortcut) i,
  ];

  Map<String, String> emit() {
    final exposed = _exposed;
    if (exposed.isEmpty) return const {};
    return {shortcutsFile: _shortcuts(exposed), stringsFile: _strings(exposed)};
  }

  String _shortcuts(List<IntentSpec> intents) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..write(_header)
      ..writeln(
        '<shortcuts xmlns:android="http://schemas.android.com/apk/res/android">',
      );

    for (final intent in intents) {
      if (intent.canBeLauncherShortcut) {
        b
          ..writeln()
          ..writeln('  <shortcut')
          ..writeln('      android:shortcutId="${_attr(intent.id)}"')
          ..writeln('      android:enabled="true"')
          ..writeln(
            '      android:shortcutShortLabel="@string/${intent.androidLabelResource}_short"',
          )
          ..writeln(
            '      android:shortcutLongLabel="@string/${intent.androidLabelResource}_long">',
          );
        _intentElement(b, intent, indent: '    ');
        if (intent.androidCapability case final capability?) {
          // Binds the shortcut to the built-in intent, which is what lets
          // Assistant offer this particular shortcut for a spoken request
          // rather than only opening the app.
          b.writeln(
            '    <capability-binding android:key="${_attr(capability)}" />',
          );
        }
        b.writeln('  </shortcut>');
      }

      if (intent.androidCapability case final capability?) {
        b
          ..writeln()
          ..writeln('  <capability android:name="${_attr(capability)}">');
        _intentElement(
          b,
          intent,
          indent: '    ',
          parameters: [
            for (final p in intent.params)
              if (p.androidCapabilityParameter != null) p,
          ],
        );
        b.writeln('  </capability>');
      }
    }

    b
      ..writeln()
      ..writeln('</shortcuts>');
    return b.toString();
  }

  void _intentElement(
    StringBuffer b,
    IntentSpec intent, {
    required String indent,
    List<ParamSpec> parameters = const [],
  }) {
    final selfClosing = parameters.isEmpty;
    b
      ..writeln('$indent<intent')
      ..writeln('$indent    android:action="$androidShortcutAction"')
      ..writeln('$indent    android:targetPackage="${_attr(applicationId)}"')
      ..writeln('$indent    android:targetClass="${_attr(activityClass)}"')
      ..write(
        '$indent    android:data="$androidShortcutScheme://intent/${_attr(intent.id)}"',
      );
    if (selfClosing) {
      b.writeln(' />');
      return;
    }
    b.writeln('>');
    for (final p in parameters) {
      b
        ..writeln('$indent  <parameter')
        ..writeln(
          '$indent      android:name="${_attr(p.androidCapabilityParameter!)}"',
        )
        ..writeln('$indent      android:key="${_attr(p.name)}" />');
    }
    b.writeln('$indent</intent>');
  }

  /// `shortcutShortLabel` refuses a literal, so every label has to exist as a
  /// resource — which is the only reason this second file exists.
  String _strings(List<IntentSpec> intents) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..write(_header)
      ..writeln('<resources>');
    for (final intent in intents) {
      if (!intent.canBeLauncherShortcut) continue;
      b
        ..writeln(
          '  <string name="${intent.androidLabelResource}_short">'
          '${_text(intent.title)}</string>',
        )
        ..writeln(
          '  <string name="${intent.androidLabelResource}_long">'
          '${_text(intent.description ?? intent.title)}</string>',
        );
    }
    b.writeln('</resources>');
    return b.toString();
  }

  /// XML-escapes an attribute value.
  static String _attr(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// Escapes for a string resource.
  ///
  /// On top of XML, Android's resource compiler requires an apostrophe or a
  /// double quote inside a `<string>` to be backslash-escaped — an unescaped
  /// apostrophe is an error, not a warning, and "Add a task to Bob's inbox" is
  /// an ordinary title to write.
  static String _text(String raw) => raw
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('"', r'\"');

  static const String _header = '''
<!--
  GENERATED BY os_intents — do not edit.

  Regenerate with:
    dart run build_runner build && dart run os_intents_cli:os_intents sync
-->
''';
}
