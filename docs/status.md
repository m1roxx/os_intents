# Status and plan

The document to read when picking this up after a gap. Last updated 2026-07-31
(doctor).

`README.md` is the pitch; this is the honest inventory.

---

## 1. Where the project stands

**Pre-alpha, nothing published.** Both pipelines work end to end and are
verified on a device: iOS on a simulator, Android on an API 36 emulator.

### Verified on a device

Not "compiles" — actually ran. iOS on an iPhone 17 simulator via
[`probe/run_integration.sh`](../probe/run_integration.sh):

| Check | What it proves |
|---|---|
| `headless_isolate` | A handler ran with no UI, and in a *different* isolate — the UI-side counter stayed at 0 |
| `static_round_trip` | `publishStatic` and the native read side agree |
| `entity_queries` | `@EntityQuery` answers, and the wire keys match what the generated Swift reads |
| `snippet_round_trip` | A card survives the store, spec and spoken text both |

Android on an API 36 emulator via
[`probe/run_android_integration.sh`](../probe/run_android_integration.sh):

| Check | What it proves |
|---|---|
| `headless_engine` | A second `FlutterEngine` started inside the app process, found the generated entrypoint by name, and ran the handler — the UI isolate's list stayed at 0 |
| `unknown_intent_fails` | An unknown id fails loudly instead of hanging |

Independently, iOS itself indexed the generated intents: the Shortcuts daemon
logged `Indexed: 3, Errored: 0` and loaded `LNActionMetadata`,
`LNEntityMetadata` and `LNQueryMetadata` for the example's bundle.

### Verified by building, not by running

- The generated Swift compiles into an app and reaches
  `Metadata.appintents/extract.actionsdata` with entities, queries and phrases
  intact.
- The generated Kotlin compiles, KSP accepts it, and the descriptions written in
  Dart come out the far end in the APK's AppFunction metadata. A foreground
  intent is correctly left out.

### Not verified at all

- **Invocation by Siri.** Everything short of the OS actually calling
  `perform()` is covered; getting a simulator to speak a phrase is not something
  this setup can arrange.
- **A real background launch.** `Execution.background` is proven by forcing the
  headless path while the app is open. iOS launching the app cold *from* an
  intent has never been observed here.
- **An agent invoking an AppFunction.** The bridge half is proven; the path
  from a real assistant through `AppFunctionService` has never run, because
  Gemini's integration is in a private EAP.

### Health

128 tests (6 in `os_intents`, 69 in `os_intents_gen`, 53 in `os_intents_cli`),
`flutter analyze` clean across the workspace, example app builds for iOS, probe
app builds for Android.

---

## 2. How it actually ended up

Three deviations from the original design, each forced by something measured.
They are the parts most likely to be misremembered later.

### Generated Swift goes to the app target, not the plugin

The Risk #1 probe proved intents *are* discoverable from a plugin module — but
that turned out not to be usable. A published package lives in `~/.pub-cache`,
shared between projects and wiped by `pub cache repair`, so per-project
generated sources could never live there; and `build_runner` derives output
paths from input paths, so it cannot write into `ios/` at all. Risk #1b then
forced one file into the app target regardless.

What Risk #1 still bought: the runtime bridge ships inside the plugin instead of
being copied into every app, and an app that wants no spoken phrases could skip
the Xcode step entirely.

Full reasoning and measurements: [risk1.md](risk1.md).

### The build splits in two

`build_runner` stops at `lib/*.os_intents.json`; `os_intents_cli sync` carries
the manifest the rest of the way into `ios/Runner/OsIntents/`. Not a design
preference — it is the only way to reach `ios/`.

```
annotations → build_runner → *.g.dart  (registry, background entrypoint)
                           → *.json    (manifest)
            → os_intents sync          → ios/Runner/OsIntents/*.swift
            → os_intents sync --android → android/…/<applicationId>/*.kt
            → os_intents install       → project.pbxproj  (once)
```

### `Execution.background` needs a second engine

Since the scene-based lifecycle, the `FlutterViewController` — and the engine
with it — is created when a scene attaches. A background launch attaches none,
so the app would come up with no isolate, no channel, and nothing to invoke.
`OsIntentsBackgroundEngine` therefore owns an engine of its own, started on
demand and torn down after 20 s idle.

The router prefers the UI isolate whenever the app is already running, so a
handler sees the state the user is looking at rather than an empty second world.

---

## 3. Layout

```
packages/
  os_intents                    annotations, IntentResult, registry, IntentHarness
  os_intents_platform_interface the contract platform implementations fulfil
  os_intents_ios                bridge, headless engine, snippet view (Swift)
  os_intents_android            headless engine bridge (Kotlin)
  os_intents_gen                build_runner builder → Dart + manifest + Swift/Kotlin
  os_intents_cli                sync / install / doctor
  os_intents/example            worked example; also the self-check host
probe/
  risk1_metadata                where may generated Swift live? (answered)
  android_appfunctions          Android feasibility, and now the Kotlin emitter's
                                end-to-end check (answered)
  fixtures                      probe-only sources, copied in per run so they
                                never ship inside the published plugin
  run_integration.sh            iOS device self-check
  run_android_integration.sh    Android device self-check
docs/
  risk1.md                      Risk #1 and #1b, design and verdicts
  android.md                    Android feasibility, cost, emitter constraints
  status.md                     this file
```

Pub workspace; one `flutter pub get` at the root. Flutter pinned per-repo to
3.44.8 via `.fvmrc`, so none of this can disturb the other projects on the
machine.

---

## 4. What is missing

Ordered by how much it blocks a first release.

### Blocking 0.1

1. ~~**`os_intents doctor` is a stub.**~~ Done. It reads
   `extract.actionsdata`, lists the intents, parameters, entities, queries and
   phrases the OS will see, names the selected provider, and cross-checks all of
   it against the manifests — a phrase that never arrived, an entity without its
   query, a rival `AppShortcutsProvider` that won, or a bundle older than the
   generated Swift. Exits non-zero when something declared in Dart is missing.
   The metadata reader is pure and tested against a captured bundle, so it needs
   neither Xcode nor a device.
2. ~~**`install` is regex surgery on `project.pbxproj`.**~~ Done, both halves.
   The project is parsed, so the target, its Sources phase and the app's group
   are looked up rather than assumed from the template's object ids — and the
   Runner target is told apart from RunnerTests, which the ids could not do.
   The edits stay textual, so the diff is 23 lines rather than a file Xcode
   reformatted, but the result is parsed again and checked before anything is
   written: a missed insertion is now a message, not an app that builds cleanly
   with no intents in it. Anything unrecognised — another target name, a file
   already referenced elsewhere, synchronized folder groups — is refused with
   the manual step spelled out.

   Verified beyond the unit tests: installed into a project straight out of
   `flutter create`, then `plutil`, `xcodebuild -list` and a full
   `flutter build ios` all accepted it, and the four sources come out in the
   built `Runner.swiftmodule`.
3. **No test for the generated Swift itself.** The emitters are covered by
   string assertions; whether the output compiles is only ever discovered by
   building the example. A fixture that compiles generated Swift in CI would
   close that.
4. **README needs the GIF.** The whole pitch is "Siri runs your action without
   opening the app" and there is no picture of it.

### Blocking Android

5. **No app-shortcuts layer.** AppFunctions needs Android 16+ and a toolchain
   most projects do not have, so the default path for everyone else — shortcuts
   / capabilities — is still missing.
6. **`Execution.static_` does nothing on Android.** `publishStaticValues` is a
   no-op there, so a static intent runs its handler headlessly: correct, but not
   the free answer it is on iOS.

### Later

7. Interactive snippets, `AssistantIntent` schemas (iOS 18+), confirmation flows
   (`IntentResult.needsConfirmation` is modelled but nothing consumes it),
   `IntentResult.value` chaining in Shortcuts.

---

## 5. Decisions waiting on a human

**~~How should Android AppFunctions be gated?~~** Decided: opt-in, behind
`os_intents sync --android`, so the version chain is never imposed on anyone who
did not ask. The other half of that recommendation — an app-shortcuts layer as
the default for everyone else — is not built.

**Is `install`'s pbxproj editing acceptable, or should the provider file be a
documented manual step?** Still a judgement call, but a smaller one than it was.
`install` no longer depends on the template's object ids, refuses anything it
does not recognise, and names the manual step when it does — so the failure mode
is a message rather than a broken project, and the manual path stays available
for anyone who wants it. What is still unproven is Xcode's own reaction over
time: a project it reformats after a version bump has only been reasoned about,
not observed.

**What is the package actually called?** `os_intents` looked free on pub.dev but
was never confirmed against `pub.dev/packages/os_intents` directly. Worth
settling before any of it is published, since the name is baked into the
generated Swift, the channel names and the CLI.

---

## 6. Traps worth remembering

Things that cost real time here, and would cost it again.

- **`command | tail` returns `tail`'s exit code.** Two builds were read as
  successful when they had failed. Use `set -o pipefail`, or check the real
  status.
- **`log show --start` reads local time.** A UTC stamp widens the window by the
  offset and sweeps in the previous run's output — which briefly made the
  harness report a check twice.
- **`UserDefaults` refuses `NSNull`** and the `[AnyHashable: Any]` that nested
  method-channel maps decode to. Publishing a result with one unset field took
  the whole app down until payloads were made property-list-safe.
- **`AppIntentsPackage` is iOS 17+**, while `AppIntent` itself is iOS 16+.
  Building the bridge on it would silently cost every iOS 16 user the feature.
- **A provider declared in a plugin is dropped in silence.** No error, no
  warning, `root.ssu.yaml` simply never appears. This is why `sync` refuses to
  write one when the app already has its own.
- **Taps injected into the simulator do not reach Flutter's gesture layer** on
  this machine. Every device check therefore runs from `main()` behind a
  `--dart-define` rather than through the UI.
- **Android 17 has minor API levels.** `compileSdk = 37` alone does not resolve;
  the platform is `android-37.1` and needs `compileSdkMinor`.
