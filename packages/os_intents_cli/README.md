# os_intents_cli

The only part of os_intents that touches a native project. `build_runner`
derives its output paths from its input paths, so it cannot write into `ios/` or
`android/` at all; it stops at a manifest next to the generated Dart and this
CLI carries the manifest the rest of the way.

```bash
dart run os_intents_cli:os_intents sync              # manifest → ios/Runner/OsIntents/*.swift
dart run os_intents_cli:os_intents sync --android    # also → android/…/<applicationId>/*.kt
dart run os_intents_cli:os_intents sync --check      # drift guard for CI, writes nothing
dart run os_intents_cli:os_intents install           # add the generated folder to the Xcode target
dart run os_intents_cli:os_intents doctor            # what will the OS actually see?
```

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
