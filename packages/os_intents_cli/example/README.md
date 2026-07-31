# A worked run

This package is a command-line tool, so the example is a session rather than a
Dart file. Everything below is real output, captured from the example app and
the Android probe in this repository.

Add it as a dev dependency:

```yaml
dev_dependencies:
  build_runner: ^2.4.13
  os_intents_gen: ^0.1.0
  os_intents_cli: ^0.1.0
```

## 1. Generate

`build_runner` turns the annotations into a registry and a manifest. It cannot
write into `ios/` or `android/` — its output paths derive from its input paths —
so it stops at the manifest and this CLI carries it the rest of the way.

```console
$ dart run build_runner build --delete-conflicting-outputs
[INFO] Succeeded after 9s with 2 outputs

$ dart run os_intents_cli:os_intents sync
  wrote ios/Runner/OsIntents/OsIntentsGenerated.swift
  wrote ios/Runner/OsIntents/OsIntentsEntities.swift
  wrote ios/Runner/OsIntents/OsIntentsEnums.swift
  wrote ios/Runner/OsIntents/OsIntentsShortcuts.swift
os_intents: 4 intent(s), 1 entity(ies) → ios/Runner/OsIntents
```

## 2. Register the folder with Xcode, once

App Intents are extracted at compile time from the app target, so the generated
folder has to be a member of it. This does that and nothing else:

```console
$ dart run os_intents_cli:os_intents install
```

It parses `project.pbxproj`, looks up the target and its Sources phase rather
than assuming ids from Flutter's template, re-parses its own output before
writing, and leaves a `.os_intents.bak` behind. Anything it does not recognise
is refused with the manual step spelled out — the rest of the toolchain does not
care how the folder got into the target.

## 3. Ask what the OS will actually see

The step that has no substitute. Everything else reports on itself:
`build_runner` says it generated Dart, `sync` says it wrote Swift, Xcode says it
compiled — and the intents can still be invisible, because the folder never made
it into the target or because another `AppShortcutsProvider` won. Neither
produces an error anywhere.

`doctor` reads a **built** bundle, so build first:

```console
$ flutter build ios --simulator --debug
$ dart run os_intents_cli:os_intents doctor

Intents the OS will see (3)
  AddTaskOsIntent  "Add task"
      Creates a new task in the Inbox
      runs without opening the app
      title         String          required
      dueDate       Date            optional
      project       ProjectEntity   optional

Entities (1)
  ProjectEntity  "Project"  resolved by Runner.ProjectQuery

Spoken phrases (3 via Runner.OsIntentsShortcuts)
  AddTaskOsIntent
      "Add a task to ${applicationName}"
      "New ${applicationName} task"
  root.ssu.yaml  present — Siri has the phrase model

Everything declared in Dart reached the bundle.
```

It exits non-zero when something declared in Dart is missing.

### Android

Same question, other platform: an agent either sees your functions or it does
not.

```console
$ flutter build apk --debug
$ dart run os_intents_cli:os_intents doctor --android

Reading build/app/outputs/flutter-apk/app-debug.apk

AppFunctions the OS will see (2)
  addTask
      Creates a new task in the Inbox
      title         String          required
      dueDate       Long            optional
  dueToday
      Tasks due today

App shortcuts XML: packaged

Everything declared in Dart reached the APK.
```

### On a device

A third thing again, and the one the APK cannot answer: `ShortcutManager` drops
what it will not accept without reporting it, caps how many it holds, and
resolves every label through the resource table.

```console
$ dart run os_intents_cli:os_intents doctor --device

On the device, as dev.osintents.appfunctions_probe
  dueToday        Tasks due today
  openInbox       Open inbox
```

Those labels arriving as words rather than as `os_intents_dueToday_label_short`
is the check worth having: the APK carries only the resource reference, and
whether it resolved is something only the device knows.

## 4. Keep it honest in CI

`sync --check` writes nothing and fails when the native sources have drifted
from the manifest:

```console
$ dart run os_intents_cli:os_intents sync --check
os_intents: generated Swift is up to date.
```

Pair it with `git diff --exit-code` after `build_runner`, which catches the
other kind of drift — generated Dart that was committed and then went stale.

Full documentation: [os_intents](https://pub.dev/packages/os_intents).
