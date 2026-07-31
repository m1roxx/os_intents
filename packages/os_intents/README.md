# os_intents

[![pub package](https://img.shields.io/pub/v/os_intents.svg)](https://pub.dev/packages/os_intents)
[![pub points](https://img.shields.io/pub/points/os_intents)](https://pub.dev/packages/os_intents/score)
[![likes](https://img.shields.io/pub/likes/os_intents)](https://pub.dev/packages/os_intents/score)
[![CI](https://github.com/m1roxx/os_intents/actions/workflows/ci.yml/badge.svg)](https://github.com/m1roxx/os_intents/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/m1roxx/os_intents/blob/main/LICENSE)

Declare OS-level app actions in Dart. The generator emits the iOS **App Intents**
and Android **AppFunctions** code the system needs at compile time, so Siri,
Spotlight, Shortcuts and on-device agents can run your app's actions — ideally
without opening the app at all.

The pitch in one line: **you never open Xcode.**

![Running an action from the Shortcuts app: the handler answers and the app never opens](https://raw.githubusercontent.com/m1roxx/os_intents/main/docs/media/shortcuts_demo.gif)

Not a mock-up. That is the example app's `addTask` handler, written in Dart,
invoked by iOS from the Shortcuts app. The prompt is the `requestValueDialog`
from the annotation; the answer is the handler's return value. iOS launched the
app's own process in the background to run it and never brought it to the
foreground — measured, not assumed:

```
Runner[91295] OSINTENTS_HOST intent=addTask process=Runner uiEngine=yes
```

> **Status: pre-alpha.** Both platforms work end to end and are verified on a
> device — iOS on a simulator, Android on an API 36 emulator — by the harnesses
> in [`probe/`](https://github.com/m1roxx/os_intents/tree/main/probe). No real
> user's app has shipped on this yet. What is verified, what only compiles, and
> what has never been observed is listed honestly in
> [docs/verified.md](https://github.com/m1roxx/os_intents/blob/main/docs/verified.md).
> The one thing still unobserved is Siri invoking a phrase by voice.

## Install

```yaml
dependencies:
  os_intents: ^0.1.0

dev_dependencies:
  build_runner: ^2.4.13
  os_intents_gen: ^0.1.0   # the builder
  os_intents_cli: ^0.1.0   # carries the result into ios/ and android/
```

## Declare an action

```dart
import 'package:os_intents/os_intents.dart';

part 'intents.os_intents.g.dart';

@AppIntent(
  title: 'Add task',
  description: 'Creates a new task in the Inbox',
  phrases: [r'Add a task to $app', r'New $app task'],
  systemImageName: 'plus.circle',
  execution: Execution.background,
)
Future<IntentResult> addTask({
  @Param(title: 'Title', requestValueDialog: 'What should the task be called?')
  required String title,
  @Param(title: 'Due date') DateTime? dueDate,
}) async {
  final task = await TaskRepo.instance.create(title: title, dueDate: dueDate);
  return IntentResult.dialog('Added "${task.title}"');
}
```

Every phrase must contain `$app` — it expands to `\(.applicationName)` in the
generated Swift, which Apple requires. The generator rejects a phrase without it
rather than letting App Review do it.

Install the generated registry once, before `runApp`:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OsIntents.install($osIntentsRegistry);
  runApp(const MyApp());
}
```

Before `runApp` matters: an intent can be what launched the app, and the native
side buffers that invocation only until this resolves.

## Generate

```bash
dart run build_runner build --delete-conflicting-outputs
dart run os_intents_cli:os_intents sync      # → ios/Runner/OsIntents/*.swift, android/…/res
dart run os_intents_cli:os_intents install   # register the folder with the Runner target (once)
```

`build_runner` derives output paths from input paths, so it cannot write into
`ios/` or `android/` at all — it stops at a manifest next to the generated Dart,
and the CLI carries it the rest of the way. That is why the build has two steps.

Two more worth wiring in:

```bash
dart run os_intents_cli:os_intents sync --check     # fails on drift, for CI
dart run os_intents_cli:os_intents doctor           # what will the OS actually see?
dart run os_intents_cli:os_intents doctor --android # …and what will an agent see?
```

`doctor` reads `Metadata.appintents/extract.actionsdata` out of a **built**
bundle — the file the OS itself indexes — and answers the one question no other
step can. Generated Swift can be written, compiled and still invisible, because
the folder never made it into the Runner target or because another
`AppShortcutsProvider` won. Neither failure produces an error anywhere else.

## What works

| | iOS | Android |
|---|---|---|
| Invoked by the OS, app stays closed | ✅ observed from Shortcuts | ✅ AppFunctions (headless) |
| App shortcuts / launcher entries | ✅ Spotlight, Shortcuts | ✅ generated `shortcuts.xml` |
| Spoken triggers | ✅ Siri phrases | ✅ Assistant capabilities (built-in intents) |
| `@AppEntity` + `@EntityQuery` resolution | ✅ verified on device | — |
| `Execution.background` — runs with no UI | ✅ verified on device | ✅ verified on emulator |
| `Execution.static_` — answers with no engine | ✅ verified on device | ✅ verified on emulator |
| Snippet cards | ✅ compiles and round-trips | — |

iOS 16+. Android is two layers: app shortcuts and Assistant capabilities cost
nothing and are generated by default, while **AppFunctions** — the headless one —
is opt-in behind `sync --android`, because it forces `compileSdk 37`, AGP 9.1.1
and Gradle 9.3.1 on your app for something only Android 16+ can run.

The two are not interchangeable. A `shortcuts.xml` `<intent>` starts an Activity,
so on the shortcuts layer `Execution.background` **still opens the app**;
headless is what AppFunctions and its version chain buy. Details in
[docs/android.md](https://github.com/m1roxx/os_intents/blob/main/docs/android.md).

## Execution modes

```dart
Execution.foreground   // bring the app up, run on the main isolate
Execution.background   // run with no UI
Execution.static_      // no Dart at all: the native side answers from published data
```

`static_` is the only mode with no engine startup cost and the only one that can
never be evicted for memory. It answers from whatever the app last published, so
keep it fresh:

```dart
await OsIntents.publishStatic({
  'dueToday': IntentResult.snippet(SnippetSpec(title: 'Due today', subtitle: '3 tasks')),
});
```

On iOS the router prefers the UI isolate whenever the app is already running, so
a background handler sees the state the user is looking at rather than an empty
second world.

## Test without a device

Nothing here needs Siri, a simulator or a plugged-in phone to test:

```dart
final harness = IntentHarness($osIntentsRegistry);

test('addTask returns what Siri will speak', () async {
  final result = await harness.invoke('addTask', {'title': 'Buy milk'});
  expect(result, isA<DialogResult>());
});

test('no handler was renamed', () {
  expect(harness.registeredIds, ['addTask', 'completeTask', 'dueToday']);
});
```

That second one is worth keeping: an intent id is what users' saved shortcuts
point at, so renaming a handler orphans them silently. Assert on the list and it
fails in CI instead.

## Packages

You import `os_intents` and nothing else. The rest resolve on their own:

| package | what it is |
|---|---|
| [`os_intents`](https://pub.dev/packages/os_intents) | annotations, `IntentResult`, registry, `IntentHarness` |
| [`os_intents_gen`](https://pub.dev/packages/os_intents_gen) | the builder — Dart dispatcher, manifest, Swift, Kotlin, shortcuts XML |
| [`os_intents_cli`](https://pub.dev/packages/os_intents_cli) | `sync` / `install` / `doctor`, the only part that touches a native project |
| [`os_intents_ios`](https://pub.dev/packages/os_intents_ios) | iOS bridge, headless engine, snippet view |
| [`os_intents_android`](https://pub.dev/packages/os_intents_android) | Android bridge, headless engine, shortcut routing |
| [`os_intents_platform_interface`](https://pub.dev/packages/os_intents_platform_interface) | the contract the two implementations fulfil |

## More

- [docs/verified.md](https://github.com/m1roxx/os_intents/blob/main/docs/verified.md) — how each claim above was established, what is only compiled, and what has never been observed. Read it before trusting the table.
- [docs/android.md](https://github.com/m1roxx/os_intents/blob/main/docs/android.md) — both Android layers and what each costs.
- [docs/risk1.md](https://github.com/m1roxx/os_intents/blob/main/docs/risk1.md) — why generated Swift lives in the app target and not in the plugin.
- [example/](https://github.com/m1roxx/os_intents/tree/main/packages/os_intents/example) — a task app with three intents, an entity and its query.

## License

MIT.

**The code os_intents generates is yours.** The Swift, Kotlin and XML written
into your project by `build_runner` and `os_intents sync` are the output of a
tool, like a compiler's, and carry no obligation from this licence — no notice to
keep, no attribution to add. The licence covers os_intents itself.
