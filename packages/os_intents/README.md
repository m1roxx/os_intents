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

The pitch in one line: **you never open Xcode.** The second line is the one
nothing else in this space offers: **`os_intents doctor` opens the built bundle
and tells you what the OS can actually see.**

![Running an action from the Shortcuts app: the handler answers and the app never opens](https://raw.githubusercontent.com/m1roxx/os_intents/main/packages/os_intents/screenshots/shortcuts_demo.gif)

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
> The one thing still unobserved is Siri invoking a phrase by voice. The path
> from here to 1.0 is
> [ROADMAP.md](https://github.com/m1roxx/os_intents/blob/main/ROADMAP.md);
> early adopters get hands-on integration help — open a
> [discussion](https://github.com/m1roxx/os_intents/discussions).

## Install

```yaml
dependencies:
  os_intents: ^0.2.0

dev_dependencies:
  build_runner: ^2.4.13
  os_intents_gen: ^0.2.0   # the builder
  os_intents_cli: ^0.2.0   # carries the result into ios/ and android/
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
dart run os_intents_cli:os_intents build
```

That is the whole build. Under it are three steps, and they are three because
`build_runner` derives output paths from input paths and therefore cannot write
into `ios/` or `android/` at all: it stops at a manifest next to the generated
Dart, `sync` carries that manifest into the native projects, and `install`
registers what it wrote — the Xcode target on iOS, one `<meta-data>` element on
Android. Run them separately if you prefer; all three are idempotent.

Two more worth wiring into CI:

```bash
dart run os_intents_cli:os_intents sync --check      # generated files match the manifest
dart run os_intents_cli:os_intents install --check   # the native projects reference them
```

## Did it reach the OS?

Every other step in the toolchain reports on itself. `build_runner` says it
generated Dart, `sync` says it wrote Swift, Xcode says it compiled — and the
intents can still be invisible, because another `AppShortcutsProvider` won or
because the phrases never reached the extractor. Neither failure produces an
error anywhere.

`doctor` is the only step that asks the artefact. It reads
`Metadata.appintents/extract.actionsdata` out of a **built** bundle — the file
the OS itself indexes — and compares it against what you declared in Dart:

```console
$ flutter build ios --simulator --debug
$ dart run os_intents_cli:os_intents doctor

os_intents doctor
  bundle    build/ios/iphonesimulator/Runner.app
  extracted by xcode-tools 17A324 (format 1)
  declared  4 intent(s), 1 entity(ies) in Dart

Intents the OS will see (4)
  AddTaskOsIntent  "Add task"
      Creates a new task in the Inbox
      runs without opening the app
      title         String          required
      dueDate       Date            optional
      project       ProjectEntity   optional
      priority      linkEnumeration optional
  DueTodayOsIntent  "Tasks due today"
      runs without opening the app

Entities (1)
  ProjectEntity  "Project"  resolved by Runner.ProjectQuery

Spoken phrases (3 via Runner.OsIntentsShortcuts)
  AddTaskOsIntent
      "Add a task to ${applicationName}"
      "New ${applicationName} task"
  root.ssu.yaml  present — Siri has the phrase model

Everything declared in Dart reached the bundle.
```

That is the real output of the [example app](https://github.com/m1roxx/os_intents/tree/main/packages/os_intents/example), trimmed for length. It exits
non-zero when something declared in Dart did not arrive.

Android has the same question and two more answers, because there the metadata,
the package and the system each disagree separately:

```bash
dart run os_intents_cli:os_intents doctor --android  # what is in the APK
dart run os_intents_cli:os_intents doctor --device   # what the system accepted
```

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
| Buttons on a snippet card | ✅ iOS 17+, verified through the store | — |
| Suggested by the system (donation) | ✅ verified on device | — deliberately, see below |

iOS 16+. Android is two layers: app shortcuts and Assistant capabilities cost
nothing and are generated by default, while **AppFunctions** — the headless one —
is opt-in behind `sync --android`, because it forces `compileSdk 37`, AGP 9.1.1
and Gradle 9.3.1 on your app for something only Android 16+ can run.

The two are not interchangeable. A `shortcuts.xml` `<intent>` starts an Activity,
so on the shortcuts layer `Execution.background` **still opens the app**;
headless is what AppFunctions and its version chain buy. Details in
[docs/android.md](https://github.com/m1roxx/os_intents/blob/main/docs/android.md).

## Put a button on the card

A snippet can carry buttons, each running another intent your app declares:

```dart
return IntentResult.snippet(
  SnippetSpec(
    title: 'Due today',
    rows: [for (final t in tasks.take(3)) SnippetRow(t.title, t.projectName)],
    actions: [
      SnippetAction(
        label: 'Complete first',
        intentId: 'completeTask',
        systemImageName: 'checkmark.circle',
        args: {'taskId': tasks.first.id},
      ),
    ],
  ),
);
```

The **values** come from whatever the handler just computed. The **action**
cannot: `Button(intent:)` needs a concrete type, so which intents a button may
run is fixed when the code is generated, and naming an id nothing declares
leaves that button out rather than breaking the card.

Buttons need **iOS 17** — below that the card renders without them rather than
not at all. Apple's iOS 26 `SnippetIntent`, where the card reloads itself after
a button runs, is not used here yet.

## Ask before doing something expensive

```dart
@AppIntent(
  title: 'Delete completed',
  confirmBeforeRunning: 'Delete every completed task?',
)
```

The system asks; your handler is not called at all unless the user agrees, and
a refusal is not an error. A property of the action rather than something a
handler decides — by the time a handler could return anything it has already
done the work, which is why this is an annotation and not a result.

The prompt needs iOS 18. On 16 and 17 the system still asks, in its own words:
the generated Swift picks the richer call where it exists, so the guarantee
holds on every version this package supports. iOS only.

## Make the system suggest it

Declaring an intent makes it **available** — a user who goes looking finds it in
Shortcuts and Spotlight. Donating one makes it **suggested**: iOS learns that
this action, with these values, follows this moment, and starts offering it
unasked. Call it from the same place that did the work:

```dart
await TaskRepo.instance.create(title: title, dueDate: due);
await OsIntents.donate('addTask', {'title': title, 'dueDate': due});
```

Values are the ones your handler would have received — a `DateTime` or an enum
constant as itself, an entity as its identifier — and all of them are optional.
Donating with no values at all still says the action happened.

**Returns false on Android**, where there is nothing to donate to, and that is
not a gap waiting to be filled: the nearest equivalent there is a dynamic
shortcut, which is a launcher entry your app manages by hand — with a rank, an
icon and a cap of a few per app — rather than a hint to a ranking model.
Guarding on the result is unnecessary; a donation that goes nowhere costs
nothing.

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

- [docs/troubleshooting.md](https://github.com/m1roxx/os_intents/blob/main/docs/troubleshooting.md) — **it built and Siri still cannot see it.** Every silent failure in this space, and the command that identifies each one.
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
