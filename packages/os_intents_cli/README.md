# os_intents_cli

The only part of [`os_intents`](https://pub.dev/packages/os_intents) that
touches a native project. `build_runner` derives its output paths from its input
paths, so it cannot write into `ios/` or `android/` at all; it stops at a
manifest next to the generated Dart and this CLI carries the manifest the rest
of the way.

```yaml
dev_dependencies:
  os_intents_cli: ^0.2.0
```

```bash
dart run os_intents_cli:os_intents build             # all three steps, in order
dart run os_intents_cli:os_intents sync              # manifest → ios/Runner/OsIntents/*.swift
dart run os_intents_cli:os_intents sync --android    # also → android/…/<applicationId>/*.kt
dart run os_intents_cli:os_intents sync --check      # drift guard for CI, writes nothing
dart run os_intents_cli:os_intents install           # register what sync wrote, per platform
dart run os_intents_cli:os_intents install --check   # …and the drift guard for that
dart run os_intents_cli:os_intents doctor            # what will the OS actually see?
dart run os_intents_cli:os_intents doctor --android  # …and what will an agent see?
```

## build

One command, because the order matters and stopping one step short produces a
build that succeeds with no intents in it:

```bash
dart run os_intents_cli:os_intents build
```

It runs `build_runner`, then `sync`, then `install`. Every step is idempotent,
which is what makes it safe as the habitual one — run it after any change to an
annotation and the two native projects catch up.

`--android` is forwarded to `sync` and means exactly what it does there.
`--no-codegen` skips `build_runner` for a project with a watcher already
running. build_runner is started with the same Dart that is running the CLI, so
an SDK pinned with fvm stays pinned.

## install

Two one-time edits, one per platform, skipped where the platform is absent:

| | |
|---|---|
| `ios/Runner.xcodeproj` | adds `ios/Runner/OsIntents` to the Runner target |
| `AndroidManifest.xml` | points the launcher `<activity>` at `@xml/os_intents_shortcuts` |

They are the same kind of thing. `sync` writes files that both native builds
will happily ignore until the project is told they exist, and neither omission
produces an error anywhere — just an app whose intents are not there.

Both edits are decided against the parsed project, applied as text so the diff
stays small (five lines in the manifest, four per Swift file in the pbxproj),
and parsed again before anything is written. On iOS every anchor is an object id
looked up in the parsed project, not one of the ids Flutter's template happens
to use: those are not a contract, and an anchor that fails to match would leave
the sources referenced but in no build phase.

Both are idempotent, repair a project left half-edited, and refuse rather than
guess when the project is not a shape they understand — a target under another
name (`--target`), a file already referenced elsewhere, a project using
synchronized folders, an app with two launcher activities, an activity already
pointing `android.app.shortcuts` at a shortcuts file of its own. Every refusal
names the manual step, which works just as well: the rest of the toolchain does
not care how the registration happened, and `doctor` confirms the result either
way.

`--no-xcode` and `--no-manifest` restrict it to one platform. Backups are left
next to each edited file, as `*.os_intents.bak`.

### install --check

The companion to `sync --check`, and the half that catches a different failure.
`sync --check` proves the generated files match the manifest; this proves the
native projects reference them:

```
  missing: Runner does not compile these, so they reach the build as nothing:
    • OsIntentsEnums.swift
```

Writes nothing, exits non-zero, and reports both platforms rather than stopping
at the first. The case it exists for is not hypothetical: this check was written
after a new emitter output — `OsIntentsEnums.swift` — turned out to have been
generated into the example and never registered, so it compiled into nothing
while `build_runner`, `sync` and Xcode all reported success.

## doctor

Everything else in the toolchain reports on its own step. `build_runner` says it
generated Dart, `sync` says it wrote Swift, Xcode says it compiled — and the
intents can still be invisible, because the generated folder was never added to
the Runner target, or because the app already had an `AppShortcutsProvider` and
iOS silently kept that one instead. Neither failure produces an error anywhere.

`doctor` reads `Metadata.appintents/extract.actionsdata` out of a built bundle —
the file the OS itself indexes — lists what is in it, and compares that against
the manifests:

```
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
```

It exits non-zero when something declared in Dart did not reach the bundle.
Warnings — a stale build, an optionality mismatch — are reported but do not fail.

Build first; doctor reads a bundle, not source:

```bash
flutter build ios --simulator --debug
dart run os_intents_cli:os_intents doctor
```

`--app` points it at a specific bundle, `-C` at a project root other than the
working directory.

The metadata format is Apple's and undocumented. Every field
[`actions_data.dart`](lib/src/actions_data.dart) reads was observed in a bundle
iOS actually indexed, and the parser reports what it does not recognise instead
of guessing — a `type #12` in the output means the format moved and the reader
has not caught up.

### doctor --android

The same question on the other platform: an agent either sees your functions or
it does not, and nothing in the build says which.

```bash
flutter build apk --debug
dart run os_intents_cli:os_intents doctor --android
```

```
AppFunctions the OS will see (2)
  addTask
      Creates a new task in the Inbox
      title         String          required
      dueDate       Long            optional
  dueToday
      Tasks due today

App shortcuts XML: packaged
```

It reads the APK, not the sources — `sync --check` already proves the files on
disk match the manifest, and only the artefact can say they were packaged. The
AppFunction metadata is plain XML in `assets/`, so no binary XML decoding is
involved and the reader stays pure.

What it catches: a headless intent that never reached the metadata, a
description that stopped matching the one in Dart (they travel as KDoc, so a
stale build shows up here), a function left over from an earlier build that an
agent may still offer, and a missing shortcuts XML.

And one that is easy to get wrong by hand: **optionality**. The generated Kotlin
lists every property in `<required>`, but `androidx.appfunctions` treats a
nullable property as optional however it is listed — so doctor reports what the
runtime will enforce, not what the file says.

An APK with no AppFunction metadata is reported as a note rather than an error.
That is the default state: the layer is opt-in behind `sync --android`.

### doctor --device

The third question, and the only one that needs a running device:

```bash
dart run os_intents_cli:os_intents doctor --device
```

```
On the device, as com.example.tasks
  dueToday        Tasks due today
  openInbox       Open inbox
```

`sync --check` proves the generated XML matches the manifest. `--android` proves
it was packaged. This proves the **system accepted it** — three different
things that fail separately.

`ShortcutManager` drops a shortcut it does not like without reporting it, caps
how many it will hold, and resolves every label through the resource table. So
the check worth having is the label: if it comes back as
`os_intents_addTask_label_short` instead of "Add task", the string resource
never made it into the build, and nothing but the device can tell you.

It reads `adb shell dumpsys shortcut` and needs the app installed. adb is found
on `PATH`, via `ANDROID_HOME` / `ANDROID_SDK_ROOT`, in the usual SDK location,
or wherever `ADB_BIN` points. No device, no adb, or no applicationId are
reported as warnings and not as errors — "could not ask" is not the same answer
as "your shortcuts are broken".
