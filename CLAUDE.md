# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

`os_intents` lets a Flutter app declare OS-level actions in Dart — iOS App
Intents and Android AppFunctions — so Siri, Spotlight, Shortcuts and on-device
agents can run them, ideally without opening the app.

Read [docs/status.md](docs/status.md) first. It is the honest inventory: what is
verified on a device versus merely compiled, what is missing, and which
decisions are still open.

## Toolchain

Flutter is pinned per-repo to **3.44.8** via `.fvmrc`. Use `fvm flutter` /
`fvm dart`, never the global SDK — the machine's global install is older and on
a detached branch, and other projects depend on it.

```bash
fvm flutter pub get          # at the repo root; this is a pub workspace
fvm flutter analyze          # whole workspace
```

## Tests

Per package, from the package directory — `flutter test` for Flutter packages,
`dart test` for pure Dart:

```bash
cd packages/os_intents      && fvm flutter test
cd packages/os_intents_gen  && fvm dart test
cd packages/os_intents_cli  && fvm dart test
cd packages/os_intents_gen  && fvm dart test test/emit_kotlin_test.dart -n "foreground intents are left out"
```

Running `flutter test` over several package paths at once mis-resolves and
reports phantom "loading" failures. Run each package in its own directory.

## Device checks

Unit tests cover the emitters as strings. Everything that actually matters —
the headless engine, the static store, entity queries — exists only on a device,
so it is verified by two harnesses that build the app, install it, run a
self-check from `main()` behind `--dart-define=OS_INTENTS_SELFCHECK=true`, and
grep the device log:

```bash
./probe/run_integration.sh           # iOS, needs a booted simulator
./probe/run_android_integration.sh   # Android, needs a booted emulator
```

The checks run from `main()` rather than through the UI because injected taps do
not reach Flutter's gesture layer on this machine, and no test can arrange for
Siri or an agent to invoke a real intent.

For Android, only an **AOSP ATD image** boots here; the emulator install has no
software GL renderer and every GPU mode on a Google APIs image crashes headless.
`docs/android.md` has the working command and the two harness consequences.

## The pipeline

Three stages, and the split is forced rather than chosen:

```
annotations → build_runner → lib/*.os_intents.g.dart   registry + background entrypoint
                           → lib/*.os_intents.json     manifest
            → os_intents sync            → ios/Runner/OsIntents/*.swift
            → os_intents sync --android  → android/app/src/main/kotlin/<applicationId>/*.kt
            → os_intents install         → project.pbxproj  (once per project)
```

`build_runner` derives output paths from input paths, so it cannot write into
`ios/` or `android/` at all. That is why a manifest exists and why the CLI
carries it the rest of the way. In the example app:

```bash
cd packages/os_intents/example
fvm dart run build_runner build --delete-conflicting-outputs
fvm dart run os_intents_cli:os_intents sync
fvm dart run os_intents_cli:os_intents install     # first time only
fvm dart run os_intents_cli:os_intents sync --check  # CI drift guard
fvm dart run os_intents_cli:os_intents doctor        # what the OS will actually see
```

`doctor` reads `Metadata.appintents/extract.actionsdata` out of a *built*
bundle, so it answers the one question no other step can: the generated Swift
can be written, compiled and still invisible, because the folder is not in the
Runner target or another `AppShortcutsProvider` won. The reader lives in
`os_intents_cli/lib/src/actions_data.dart`, is pure, and is tested against a
bundle captured from a real build — the format is Apple's and undocumented, so
it prints what it does not recognise rather than guessing.

Android generation is **off by default** (`--android` opts in): it forces
`compileSdk 37`, AGP 9.1.1 and Gradle 9.3.1 on the consuming app.

## Architecture

`os_intents` (annotations, `IntentResult`, registry, `IntentHarness`) is the only
package users import. `os_intents_platform_interface` is the contract;
`os_intents_ios` and `os_intents_android` implement it and carry the native
bridges. `os_intents_gen` holds the parser and all three emitters — Dart, Swift,
Kotlin — and `os_intents_cli` is the only thing that touches a native project.

Emitters take a `Manifest` and return `Map<fileName, contents>`. They are pure,
which is why they are testable without an analyzer or a device. When changing
one, the paired change is usually in the *other* platform's emitter or in the
runtime bridge — the wire format is shared and both sides decode it.

**The wire format is the contract.** `DateTime` crosses as epoch milliseconds
(UTC) and entities cross as their identifier, on both platforms. Change one side
and the other breaks silently at runtime, not at compile time; `emit_test.dart`
asserts the Dart encoder and the Swift `init(wire:)` agree.

### Where generated native code goes, and why

Into the **app target**, not the plugin — even though the Risk #1 probe proved
plugin-module intents are discoverable. A published package lives in
`~/.pub-cache`, shared between projects and wiped by `pub cache repair`, so
per-project sources could never live there; and Risk #1b showed the
`AppShortcutsProvider` is only ever taken from the app's own module. Full
measurements in [docs/risk1.md](docs/risk1.md).

### Headless execution

`Execution.background` needs a second `FlutterEngine`, because in the
scene-based lifecycle the engine is created when a scene attaches and a
background launch attaches none. On iOS the router prefers the UI isolate when
the app is already running, so a handler sees the state the user is looking at.
On Android there is no such choice: an `AppFunctionService` never has an
Activity, so every invocation goes through the headless engine.

The generated entrypoint carries `@pragma('vm:entry-point')` — nothing in Dart
references it, so without the pragma release builds shake it out and the engine
fails to start with nothing but a `false`.

### Platform shapes differ, deliberately

iOS gets one `AppIntent` struct per intent. Android cannot: `androidx.appfunctions`
alpha10 requires `@AppFunction` to be a method on one
`@AppFunctionServiceEntryPoint` service, reads descriptions from KDoc rather
than annotation arguments, and takes a single serializable object instead of
loose parameters. Do not try to make the two emitters symmetrical.

## Traps that already cost time here

- `command | tail` returns `tail`'s exit code. Two failed builds were read as
  successful. Use `set -o pipefail`.
- `log show --start` reads local time; a UTC stamp sweeps in the previous run.
- `UserDefaults` refuses `NSNull` and the `[AnyHashable: Any]` that nested
  method-channel maps decode to — publishing a result with one unset field took
  the whole app down until payloads were made property-list-safe.
- `AppIntentsPackage` is iOS 17+ while `AppIntent` is iOS 16+.
- A provider declared in a plugin is dropped in silence — no error, no warning.
- Flutter's Android manifest already carries `android:name="${applicationName}"`;
  install a custom `Application` by replacing that placeholder, not by adding a
  second attribute.

## Probes

`probe/` holds experiments that answered architectural questions, kept so the
answers can be re-checked when a toolchain moves. `probe/fixtures/` holds
probe-only native sources that are copied into the plugin for a run and removed
after, so they never ship. Verdicts live in `docs/risk1.md` and
`docs/android.md`; re-run the probes when Flutter, Xcode or
`androidx.appfunctions` changes.
