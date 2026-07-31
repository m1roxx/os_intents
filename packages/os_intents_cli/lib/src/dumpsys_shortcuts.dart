/// Reads `adb shell dumpsys shortcut` — what the system actually registered.
///
/// The third thing doctor can ask, and the only one that involves a running
/// device. `sync --check` proves the generated XML matches the manifest;
/// `doctor --android` proves it was packaged into the APK; this proves the
/// system accepted it after install.
///
/// That last step is not a formality. `ShortcutManager` silently drops a
/// shortcut it does not like, resolves every label through the resource table,
/// and caps how many it will hold — none of which the APK can tell you. A
/// label reading `os_intents_addTask_label_short` instead of "Add task" means
/// the string resource never made it, and only the device knows.
///
/// The output is a debug dump with no stability guarantee, so this reads the
/// few fields that have been stable for years and reports what it cannot find
/// rather than inventing it.
library;

/// One shortcut as the system holds it.
class RegisteredShortcut {
  RegisteredShortcut({
    required this.id,
    required this.shortLabel,
    required this.longLabel,
    required this.activity,
    required this.isEnabled,
  });

  final String id;

  /// Already resolved from the string resource by the system.
  final String? shortLabel;
  final String? longLabel;

  /// Fully qualified component the shortcut starts.
  final String? activity;

  final bool isEnabled;

  /// Whether a label came back as its own resource name, which is what a
  /// missing string looks like from here.
  bool get labelLooksUnresolved =>
      shortLabel != null && shortLabel!.startsWith('os_intents_');
}

/// The section of the dump belonging to one package.
class DumpsysShortcuts {
  DumpsysShortcuts({required this.packageFound, required this.shortcuts});

  /// False when the package has no section at all — usually "not installed",
  /// which is a different problem from "installed and registered nothing".
  final bool packageFound;

  final List<RegisteredShortcut> shortcuts;
}

final _packageLine = RegExp(r'^\s*Package:\s*([\w.]+)\s');
final _shortcutLine = RegExp(r'^\s*ShortcutInfo\s*\{id=([^,]+),');

/// Parses the dump for one package.
///
/// Pure: the caller runs adb. A dump captured from a device is a fixture, and
/// the interesting cases can then be tested with no emulator in the loop.
DumpsysShortcuts parseDumpsysShortcuts(
  String output, {
  required String packageName,
}) {
  final lines = output.split('\n');

  var i = 0;
  var found = false;
  for (; i < lines.length; i++) {
    final m = _packageLine.firstMatch(lines[i]);
    if (m != null && m.group(1) == packageName) {
      found = true;
      i++;
      break;
    }
  }
  if (!found) {
    return DumpsysShortcuts(packageFound: false, shortcuts: const []);
  }

  final shortcuts = <RegisteredShortcut>[];
  String? id;
  String? shortLabel;
  String? longLabel;
  String? activity;
  var enabled = true;

  void flush() {
    if (id == null) return;
    shortcuts.add(
      RegisteredShortcut(
        id: id!,
        shortLabel: shortLabel,
        longLabel: longLabel,
        activity: activity,
        isEnabled: enabled,
      ),
    );
    id = null;
    shortLabel = null;
    longLabel = null;
    activity = null;
    enabled = true;
  }

  for (; i < lines.length; i++) {
    final line = lines[i];

    // The next package's section ends this one.
    final pkg = _packageLine.firstMatch(line);
    if (pkg != null && pkg.group(1) != packageName) break;

    final start = _shortcutLine.firstMatch(line);
    if (start != null) {
      flush();
      id = start.group(1)!.trim();
      continue;
    }
    if (id == null) continue;

    final trimmed = line.trim();
    if (trimmed.startsWith('shortLabel=')) {
      shortLabel = _label(trimmed, 'shortLabel=');
    } else if (trimmed.startsWith('longLabel=')) {
      longLabel = _label(trimmed, 'longLabel=');
    } else if (trimmed.startsWith('activity=ComponentInfo{')) {
      activity = trimmed
          .substring('activity=ComponentInfo{'.length)
          .replaceAll('}', '')
          .trim();
    } else if (trimmed.startsWith('disabledReason=')) {
      enabled = trimmed.contains('Not disabled');
    }
  }
  flush();

  return DumpsysShortcuts(packageFound: true, shortcuts: shortcuts);
}

/// `shortLabel=Tasks due today, resId=2131492873[os_intents_…]`.
///
/// The label itself may contain commas, so the resId suffix is found from the
/// right rather than by splitting on the first one.
String? _label(String line, String prefix) {
  var value = line.substring(prefix.length);
  final resId = value.lastIndexOf(', resId=');
  if (resId >= 0) value = value.substring(0, resId);
  value = value.trim();
  return value.isEmpty || value == 'null' ? null : value;
}
