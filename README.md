# os_intents

Declare OS-level app actions in Dart. The generator emits the iOS **App Intents**
and Android **AppFunctions** code the system needs at compile time, so Siri,
Spotlight, Shortcuts and on-device agents can run your app's actions — ideally
without opening the app at all.

The pitch in one line: **you never open Xcode.**

> **Status: pre-alpha, iOS only.** Nothing is published. The pipeline below
> works end to end and is verified by an app that builds: annotations →
> `build_runner` → Swift → `Metadata.appintents`. Android is not started.

## Pipeline

```bash
dart run build_runner build   # annotations → registry + manifest
dart run os_intents sync      # manifest → ios/Runner/OsIntents/*.swift
dart run os_intents install   # register those files with the Runner target (once)
```

Verified on the example app: three intents, one entity and its query all reach
the built bundle, and the phrases resolve to the provider the OS selects.

```
actions:  AddTaskOsIntent, CompleteTaskOsIntent, DueTodayOsIntent
entities: ProjectEntity
queries:  ProjectQuery
provider: 6Runner18OsIntentsShortcutsV
  AddTaskOsIntent:  "Add a task to ${applicationName}", "New ${applicationName} task"
  DueTodayOsIntent: "What's due today in ${applicationName}"
```

`os_intents sync --check` fails on drift, for CI. `os_intents doctor` reads a
built bundle and reports what the OS will actually see.

## The idea

```dart
@AppIntent(
  title: 'Add task',
  description: 'Creates a new task in the Inbox',
  phrases: [r'Add a task to $app', r'New $app task'],
  execution: Execution.background,
)
Future<IntentResult> addTask({
  @Param(title: 'Title', requestValueDialog: 'What should it be called?')
  required String title,
  @Param(title: 'Due date') DateTime? dueDate,
}) async {
  final task = await TaskRepo.instance.create(title, dueDate);
  return IntentResult.dialog('Added "${task.title}"');
}
```

`dart run build_runner build` turns that into a Swift `AppIntent` struct, an
`AppShortcutsProvider`, a Kotlin `@AppFunction`, and the Dart dispatcher that
routes an invocation back to your function.

## Why another one

Four packages already occupy this niche on pub.dev. Between them they have
~31k downloads and 59 likes — people keep trying them and keep leaving. The
recurring reasons:

| | existing packages | os_intents |
|---|---|---|
| Swift written by hand | yes | no |
| Android | mostly absent | AppFunctions + shortcut fallback |
| `AppEntity` / disambiguation | no | yes |
| Runs without launching the app | no | yes, where the OS allows it |
| Xcode target set up for you | no | `dart run os_intents:install` |

## Layout

```
packages/
  os_intents                      app-facing: annotations, results, registry, test harness
  os_intents_platform_interface   the contract platform implementations fulfil
  os_intents_ios                  iOS implementation + OsIntentsBridge (Swift)
  os_intents_gen                  build_runner builder → Dart + Swift + Kotlin
  os_intents_cli                  install / doctor / simulate
probe/
  risk1_metadata                  the experiment described below
docs/
  risk1.md                        experiment design and verdict
```

Pub workspace — one `flutter pub get` at the root resolves everything.
Flutter version is pinned per-repo via fvm (`.fvmrc`, currently 3.44.8) so this
work cannot disturb other projects on the machine.

## Risk #1 — the question that shapes the architecture

App Intents are registered **at compile time**: Xcode extracts metadata from
Swift types into `Metadata.appintents` inside the app bundle. Nothing declared
at runtime from Dart is ever visible to Siri. So the generator has to put Swift
somewhere the extractor will look — and the open question is whether a Flutter
plugin module counts.

**Answered: it does.** On Flutter 3.44.8 / Xcode 26.0 (Swift Package Manager
integration), an intent declared inside the plugin module lands in
`Metadata.appintents/extract.actionsdata` by itself — no `AppIntentsPackage`
bridge, without ever being referenced from Dart or from the app target:

```json
"fullyQualifiedTypeName": "os_intents_ios.ProbePodIntent",
"isDiscoverable": true,
"openAppWhenRun": false
```

**But the generator does not use that.** Two things overrode it. A published
package lives in `~/.pub-cache`, shared between projects and wiped by
`pub cache repair`, so per-project generated sources could never be written
there; and `build_runner` derives output paths from input paths, so it cannot
reach `ios/` at all. Risk #1b then forced one file into the app target anyway.
Once the Runner target has to be touched once, putting everything there costs
nothing extra — so generated Swift goes to `ios/Runner/OsIntents/`.

What Risk #1 did buy: the runtime bridge ships inside the plugin rather than
being copied into every app, and an app that wants no spoken phrases could skip
the Xcode step entirely.

**Risk #1b, the follow-up: spoken phrases are the exception.** Siri utterances
come from an `AppShortcutsProvider`, and a second probe showed the extractor
takes one only from the app's own module. Declared in a plugin it is silently
ignored — no error, no warning, `root.ssu.yaml` simply never gets written.

| capability | declared in | status |
|---|---|---|
| intents, entities, queries — Shortcuts, Spotlight, agents | plugin module | free |
| spoken "Hey Siri …" phrases | app target, one provider per app | CLI writes one file |

So the iOS half of `os_intents_cli install` is exactly one job: put
`ios/Runner/OsIntentsShortcuts.swift` into the Runner target, once.

Reproduce both:

```bash
./probe/risk1_metadata/run_probe.sh
./probe/risk1_metadata/run_probe_1b.sh
```

## License

MIT.
