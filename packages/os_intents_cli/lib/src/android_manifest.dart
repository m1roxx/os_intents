/// The one element the app-shortcuts layer needs in `AndroidManifest.xml`.
///
/// `sync` writes `res/xml/os_intents_shortcuts.xml`, and Android never opens it
/// unless the launcher activity points at it. That is the whole manifest change
/// — a shortcut names its target component, so no `intent-filter` is involved.
///
/// The edit is textual for the same reason the pbxproj edit is: parsing and
/// re-serialising would reformat a file the user maintains by hand, so the
/// document is parsed to *decide* where the element goes, inserted as text, and
/// parsed again to prove it landed. A missed insertion is then a message rather
/// than an app whose shortcuts silently never appear.
library;

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

/// Thrown when `AndroidManifest.xml` is not a shape this tool will edit.
class AndroidManifestException implements Exception {
  AndroidManifestException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The generated resource, without the `@xml/` the manifest needs.
const shortcutsResource = 'os_intents_shortcuts';

/// The `android:name` Android looks for when collecting an activity's shortcuts.
const _shortcutsMetaData = 'android.app.shortcuts';

const _androidNamespace = 'http://schemas.android.com/apk/res/android';

/// Returns [text] with the shortcuts `<meta-data>` added to the launcher
/// activity, or [text] itself — identically — when it is already there.
///
/// Pure, so the whole edit including the check that it landed is testable
/// against a captured manifest without an Android SDK. Throws
/// [AndroidManifestException] rather than editing anything it does not
/// understand.
String installShortcutsMetaData(String text) {
  final scan = _Scan.of(text);
  final activity = scan.launcherActivity();
  final resource = '@xml/$shortcutsResource';

  if (activity.shortcutsResource != null) {
    if (activity.shortcutsResource == resource) return text;
    throw AndroidManifestException(
      'The launcher activity already points $_shortcutsMetaData at '
      '"${activity.shortcutsResource}".\n'
      'Android reads one shortcuts file per activity, so a second one would '
      'not be merged — it would replace ours or be rejected as a duplicate. '
      'Either move those\n<shortcut> entries into the generated file, or point '
      'that meta-data at\n$resource once you have.',
    );
  }

  // Non-null for a launcher: deciding an activity is one means having seen an
  // intent-filter inside it, which a self-closing element cannot hold.
  final closeAt = activity.endsAt!;
  final closeIndent = _leadingWhitespace(text, closeAt);
  final childIndent = activity.firstChildAt == null
      ? '$closeIndent    '
      : _leadingWhitespace(text, activity.firstChildAt!);

  final block =
      '$childIndent<!-- Added by os_intents: without this line Android never '
      'reads\n'
      '$childIndent     res/xml/$shortcutsResource.xml and no shortcut '
      'appears. -->\n'
      '$childIndent<meta-data\n'
      '$childIndent    ${scan.android}:name="$_shortcutsMetaData"\n'
      '$childIndent    ${scan.android}:resource="$resource" />\n';

  final at = closeAt - closeIndent.length;
  final out = text.replaceRange(at, at, block);

  _verify(out, android: scan.android, resource: resource);
  return out;
}

/// Whether the launcher activity already carries the shortcuts `<meta-data>`.
///
/// Answers `false` for a manifest this tool cannot read rather than throwing:
/// the only caller uses it to decide whether to print a hint, and a hint is not
/// worth failing a sync over.
bool declaresShortcutsMetaData(String text) {
  try {
    return _Scan.of(text).launcherActivity().shortcutsResource != null;
  } on AndroidManifestException {
    return false;
  }
}

/// Re-reads the edited manifest and proves the element is where it was meant to
/// go.
///
/// The point of the exercise: a textual insertion that missed its anchor looks
/// exactly like success, and the failure it produces — shortcuts that never
/// appear — is indistinguishable from the layer not being generated at all.
void _verify(String text, {required String android, required String resource}) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(text);
  } on XmlException catch (e) {
    throw AndroidManifestException(
      'The edit would have produced a manifest that no longer parses '
      '(${e.message}). Nothing was written.',
    );
  }

  final activities = document.rootElement
      .findElements('application')
      .expand((a) => a.findElements('activity'))
      .where(
        (a) => a
            .findElements('intent-filter')
            .any(
              (f) => f
                  .findElements('category')
                  .any(
                    (c) =>
                        c.getAttribute('$android:name') ==
                        'android.intent.category.LAUNCHER',
                  ),
            ),
      );

  final found = activities
      .expand((a) => a.findElements('meta-data'))
      .where((m) => m.getAttribute('$android:name') == _shortcutsMetaData)
      .toList();

  if (found.length != 1 ||
      found.single.getAttribute('$android:resource') != resource) {
    throw AndroidManifestException(
      'The launcher activity did not end up with exactly one '
      '$_shortcutsMetaData pointing at $resource. Nothing was written.',
    );
  }
}

/// Whitespace running back from [offset] to the start of its line, or `''` when
/// something other than whitespace precedes it there.
String _leadingWhitespace(String text, int offset) {
  var i = offset;
  while (i > 0 && (text[i - 1] == ' ' || text[i - 1] == '\t')) {
    i--;
  }
  if (i != 0 && text[i - 1] != '\n') return '';
  return text.substring(i, offset);
}

/// One `<activity>` under `<application>`, and the offsets needed to edit it.
class _Activity {
  _Activity({required this.name, required this.startsAt});

  final String? name;
  final int startsAt;

  /// Offset of the `<` in `</activity>`; `null` for a self-closing element.
  int? endsAt;

  /// Offset of the `<` of the first child element, used to copy its indent.
  int? firstChildAt;

  bool hasMain = false;
  bool hasLauncherCategory = false;

  /// `android:resource` of this activity's shortcuts `<meta-data>`, if any.
  String? shortcutsResource;

  bool get isLauncher => hasMain && hasLauncherCategory;
}

/// A single pull-parse of the manifest, keeping the offsets the DOM discards.
///
/// `package:xml` builds a tree without source positions, and an edit needs
/// both — the tree to decide, the positions to splice — so the event API with
/// `withLocation` is what answers the question in one pass.
class _Scan {
  _Scan._(this.android, this.activities);

  /// The prefix bound to Android's namespace, read rather than assumed. It is
  /// `android` in every template, but an attribute written under a prefix the
  /// manifest does not declare is a build error rather than a shortcut that
  /// merely fails to appear.
  final String android;
  final List<_Activity> activities;

  static _Scan of(String text) {
    String? android;
    final activities = <_Activity>[];
    final stack = <String>[];
    _Activity? current;

    final Iterable<XmlEvent> events;
    try {
      events = parseEvents(
        text,
        withLocation: true,
        validateNesting: true,
      ).toList();
    } on XmlException catch (e) {
      throw AndroidManifestException(
        'AndroidManifest.xml does not parse (${e.message}).',
      );
    }

    for (final event in events) {
      if (event is XmlStartElementEvent) {
        if (event.name == 'manifest' && stack.isEmpty) {
          android = _prefixFor(event);
        } else if (stack.length == 2 &&
            stack[0] == 'manifest' &&
            stack[1] == 'application' &&
            event.name == 'activity') {
          final activity = _Activity(
            name: _attribute(event, '$android:name'),
            startsAt: event.start!,
          );
          activities.add(activity);
          // A self-closing activity has no body, so nothing below can belong
          // to it and there is no `</activity>` to come back to.
          if (!event.isSelfClosing) current = activity;
        } else if (current != null) {
          current.firstChildAt ??= event.start;
          switch (event.name) {
            case 'action':
              current.hasMain |=
                  _attribute(event, '$android:name') ==
                  'android.intent.action.MAIN';
            case 'category':
              current.hasLauncherCategory |=
                  _attribute(event, '$android:name') ==
                  'android.intent.category.LAUNCHER';
            case 'meta-data':
              if (_attribute(event, '$android:name') == _shortcutsMetaData) {
                current.shortcutsResource =
                    _attribute(event, '$android:resource') ?? '';
              }
          }
        }
        if (!event.isSelfClosing) stack.add(event.name);
      } else if (event is XmlEndElementEvent) {
        if (stack.isNotEmpty) stack.removeLast();
        if (current != null && event.name == 'activity') {
          current.endsAt = event.start;
          current = null;
        }
      }
    }

    if (android == null) {
      throw AndroidManifestException(
        'AndroidManifest.xml declares no prefix for $_androidNamespace, so '
        'there is no way to write android:name onto an element.',
      );
    }
    return _Scan._(android, activities);
  }

  /// The single activity carrying MAIN/LAUNCHER.
  ///
  /// Read from the manifest rather than assumed to be `.MainActivity`: that is
  /// what Flutter's template writes, but an app that renamed it would get its
  /// shortcuts attached to nothing.
  _Activity launcherActivity() {
    final launchers = activities.where((a) => a.isLauncher).toList();
    if (launchers.isEmpty) {
      throw AndroidManifestException(
        'No launcher activity in AndroidManifest.xml — nothing carries both '
        'android.intent.action.MAIN and android.intent.category.LAUNCHER.\n'
        'Shortcuts hang off the activity they start, so there is nowhere to '
        'put them.',
      );
    }
    if (launchers.length > 1) {
      throw AndroidManifestException(
        'This app has ${launchers.length} launcher activities '
        '(${launchers.map((a) => a.name ?? '<unnamed>').join(', ')}), and the '
        'generated shortcuts target exactly one.\n'
        'Add the meta-data by hand to whichever should carry them:\n'
        '  <meta-data android:name="$_shortcutsMetaData" '
        'android:resource="@xml/$shortcutsResource" />',
      );
    }
    return launchers.single;
  }

  static String? _prefixFor(XmlStartElementEvent manifest) {
    for (final attribute in manifest.attributes) {
      if (attribute.name.startsWith('xmlns:') &&
          attribute.value == _androidNamespace) {
        return attribute.name.substring('xmlns:'.length);
      }
    }
    return null;
  }

  static String? _attribute(XmlStartElementEvent event, String name) {
    for (final attribute in event.attributes) {
      if (attribute.name == name) return attribute.value;
    }
    return null;
  }
}
