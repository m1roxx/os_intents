# os_intents example

A small task app whose actions are reachable from Siri, Spotlight, the Shortcuts
app and — on Android — the launcher and Assistant. It is also the host for the
device self-checks in [`probe/`](https://github.com/m1roxx/os_intents/tree/main/probe).

Three intents, one entity and its query, and one of each execution mode:

| file | what to look at |
|---|---|
| [`lib/intents.dart`](lib/intents.dart) | everything you write by hand — three `@AppIntent`s, an `@AppEntity`, an `@EntityQuery` |
| [`lib/intents.os_intents.g.dart`](lib/intents.os_intents.g.dart) | what `build_runner` produced: the registry and the background entrypoint |
| [`lib/intents.os_intents.json`](lib/intents.os_intents.json) | the manifest the CLI reads |
| [`ios/Runner/OsIntents/`](ios/Runner/OsIntents) | what `os_intents sync` wrote: the `AppIntent` structs, the entities, the provider that owns the spoken phrases |
| [`lib/main.dart`](lib/main.dart) | `OsIntents.install($osIntentsRegistry)` before `runApp`, and `publishStatic` to keep the static answer fresh |

The generated files are checked in on purpose. They are the clearest answer to
"what does this actually emit?", and a diff on them is how a change to an emitter
becomes visible in review.

## The three modes, one each

```dart
addTask       Execution.background   runs with no UI, prompts for a missing title
dueToday      Execution.static_      answers from published data, no engine at all
completeTask  Execution.background   no phrases: reachable from Shortcuts, never by voice
```

`addTask` takes a `ProjectEntity?`, which is what lets the user say "add a task
to **Groceries**" and have the OS resolve which project that is before the
handler runs.

## Run it

```bash
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run os_intents_cli:os_intents sync
dart run os_intents_cli:os_intents install     # first time only
flutter run
```

Then leave the app and ask Shortcuts for "Add task" — the point is what happens
without the app on screen.

To see what the OS actually indexed:

```bash
flutter build ios --simulator --debug
dart run os_intents_cli:os_intents doctor
```
