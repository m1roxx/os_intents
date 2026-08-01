# What this package is for

You add it as a dev dependency and never call it. `build_runner` does.

```yaml
dev_dependencies:
  build_runner: ^2.4.13
  os_intents_gen: ^0.1.0
```

## In

One annotated function, in your own code:

```dart
import 'package:os_intents/os_intents.dart';

part 'intents.os_intents.g.dart';

@AppIntent(
  title: 'Add task',
  description: 'Creates a new task in the Inbox',
  phrases: [r'Add a task to $app'],
  execution: Execution.background,
)
Future<IntentResult> addTask({
  @Param(title: 'Title') required String title,
}) async => IntentResult.dialog('Added "$title"');
```

## Out

```console
$ dart run build_runner build --delete-conflicting-outputs
[INFO] Succeeded after 9s with 2 outputs
```

**`lib/intents.os_intents.g.dart`** — the dispatcher that routes an invocation
back to your function, plus the headless entrypoint when something needs one:

```dart
final IntentRegistry $osIntentsRegistry = IntentRegistry({
  'addTask': IntentBinding(
    id: 'addTask',
    invoke: (args) => addTask(
      title: _require(args['title'] as String?, 'title'),
    ),
  ),
});
```

**`lib/intents.os_intents.json`** — the manifest, which exists because
`build_runner` derives output paths from input paths and therefore cannot reach
`ios/` or `android/` at all. [os_intents_cli](https://pub.dev/packages/os_intents_cli)
picks it up and emits the Swift, the Kotlin and the shortcuts XML from it.

## What it refuses

Problems in your annotations are build errors naming the offending element,
rather than native code that will not compile:

```
Phrase "Add a task" on intent "addTask" is missing the $app placeholder.
Apple requires every phrase to name the app.
```

Also refused: a `returns:` type the system cannot carry, a parameter on an
`Execution.static_` intent, an enum with no `@AppEnum`, a positional parameter,
a handler that does not return `Future<IntentResult>`.

## How the output is checked

The emitters are pure functions from manifest to file contents, so they are
tested without an analyzer or a device. The Swift is additionally type-checked
by `swiftc -typecheck` against the real `os_intents_ios` module, where a
*warning* counts as a failure — which is how a version-gated call and a
nonmutating property-wrapper setter were caught before any device saw them.
