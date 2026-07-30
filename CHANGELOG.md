# Changelog

## Unreleased

Working iOS pipeline, verified end to end by an app that builds. Nothing
published; Android not started.

### Generator

- `os_intents_gen` parses `@AppIntent`, `@Param`, `@AppEntity`, `@EntityId`,
  `@EntityDisplay` and `@EntityQuery` and emits, per library, a Dart registry
  (`*.os_intents.g.dart`) and a manifest (`*.os_intents.json`).
- `os_intents_cli sync` turns manifests into `ios/Runner/OsIntents/*.swift`:
  `AppIntent` structs, `AppEntity` types with their `EntityStringQuery`, and one
  `AppShortcutsProvider`. `--check` fails on drift, for CI.
- `os_intents_cli install` registers those files with the Runner target.
- `os_intents_cli doctor` reads a built bundle and reports what the OS sees.

### Decisions the probes forced

- Generated Swift goes to the app target, not the plugin module. Risk #1 showed
  plugin-module intents *are* discoverable, but a pub-cache package is not
  writable per project and `build_runner` cannot reach `ios/` — and Risk #1b
  requires the app target regardless. See `docs/risk1.md`.
- `sync` refuses to write a provider when the app already declares one. iOS
  picks a single `AppShortcutsProvider` and drops the rest silently.
- Phrases must contain `$app`; the generator rejects the ones that don't rather
  than letting App Review do it.
- An entity used as a parameter must have an `@EntityQuery`, or the build fails
  with an explanation instead of emitting Dart that will not compile.

### Conversions handled

- `DateTime` ↔ epoch millis (UTC). MethodChannel has no date type, and ISO
  strings lose the zone on the Android side.
- Entities cross as their identifier and are resolved back through the user's
  own `EntityQuery` before the handler runs.
- `Execution.foreground` sets `openAppWhenRun`; `static_` answers from the shared
  container with no engine started.

### Execution.background (iOS)

Handlers run with no UI. Verified on a simulator: the headless engine came up in
~260 ms, ran the handler, and the UI isolate's task count stayed at 0 — the work
happened in a genuinely separate isolate.

- `OsIntentsBackgroundEngine`: a second `FlutterEngine` started on demand. Needed
  because since the scene-based lifecycle the engine is created when a scene
  attaches, and a background launch attaches none — so the app would otherwise
  have no isolate to invoke at all.
- `invokeBackground` prefers the UI isolate when the app is already running, so
  a handler sees the state the user is looking at rather than an empty second
  world.
- Generated `@pragma('vm:entry-point')` entrypoint, plus `OsIntentsBackground.swift`
  carrying the entrypoint's library URI and `GeneratedPluginRegistrant`. Found by
  the plugin through `NSClassFromString`, so no AppDelegate edit.
- Idle shutdown after 20 s; timeouts on both engine start and invocation.
- Background intents must all live in one library — iOS starts a single Dart
  entrypoint. Split across two, the build now fails with that explanation.
- Emits `parameterSummary`. Shortcuts logged "has a parameter without a DOP"
  without it and rendered the action with bare slots.

Bugs this surfaced, all fixed: `Manifest.merge` dropped the entrypoint library
URI, so the engine would have searched `main.dart` and silently failed;
`GeneratedPluginRegistrant` on the background engine re-registered this plugin
and overwrote the UI engine's channel; `install` used a hardcoded file list and
skipped the new file; a new file reference was added outside the `OsIntents`
group, which Xcode then resolved against `ios/`.

### Runtime

- `OsIntentsBridge` (Swift, in the plugin): single entry point for generated
  code, with cold-launch buffering so an intent that starts the app is not
  dropped while Dart handlers register.
- `IntentHarness` invokes intents in plain Dart tests, no device.

44 tests. `flutter analyze` clean. Flutter pinned per-repo to 3.44.8 via fvm.
