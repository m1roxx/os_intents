# Status and plan

The document to read when picking this up after a gap. Last updated 2026-07-31,
after closing everything in §4 except the README GIF — doctor, install, a Swift
compile test, the Swift 6 rewrite, and both Android layers.

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
| `shortcut_routing` | The Intent an app shortcut builds reaches the handler, on the UI isolate |
| `static_round_trip` | `publishStatic` and the native read side agree, so a static intent can answer without an isolate |

`dumpsys shortcut` independently shows the two generated shortcuts registered
against the app, labelled from the generated string resources — and `addTask`
correctly absent, since a tap could not supply its required parameter.

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

152 tests (6 in `os_intents`, 93 in `os_intents_gen`, 53 in `os_intents_cli`),
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
                                       → android/…/res/xml + res/values
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
  os_intents_gen                build_runner builder → Dart + manifest, and the
                                Swift / Kotlin / shortcuts-XML emitters
  os_intents_cli                sync / install / doctor
  os_intents/example            worked example; also the self-check host
probe/
  risk1_metadata                where may generated Swift live? (answered)
  android_appfunctions          Android feasibility, and now the Kotlin emitter's
                                end-to-end check (answered)
  android_shortcuts             what may a generated shortcuts.xml contain? (answered)
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
3. ~~**No test for the generated Swift itself.**~~ Done.
   `os_intents_gen/test/swift_compiles_test.dart` type-checks the emitter's
   output — every parameter type, all three execution modes, an entity with a
   query, and strings full of quotes and backslashes — against the *real*
   `os_intents_ios` module rather than a stub, so the emitter and
   `OsIntentsBridge` disagreeing about a signature is a test failure rather than
   a device-only surprise. Warnings fail it too. Runs in about eight seconds,
   and skips with a reason where there is no Xcode.

   It found something on its first run: the generated snippet path built
   `OsIntentsSnippetView` from a nonisolated context, which is a warning today
   and an error under the Swift 6 language mode. Fixed in the plugin — the
   initializer is `nonisolated` and `Row` moved out of the view, since a type
   nested in a `View` inherits its main-actor isolation.
4. **README needs the GIF.** The whole pitch is "Siri runs your action without
   opening the app" and there is no picture of it.
5. ~~**The plugin is not Swift 6 ready.**~~ Done — and it turned out to be
   hiding three real bugs rather than being cosmetic.

   The 21 warnings are gone: scoped `withLock` in place of `lock()`/`unlock()`
   (which is what "unavailable from asynchronous contexts" is asking for),
   `@preconcurrency import Flutter` for a framework that predates Sendable, and
   `nonisolated(unsafe)` on the five statics that are written once during launch.
   The plugin now compiles clean under **both** Swift 5 and the full Swift 6
   language mode — checked by a test, so it stays that way.

   An actor was the obvious answer and the wrong one: `FlutterMethodChannel` has
   to be used on the main thread, which is what the lock was really enforcing.

   The three bugs, all the same shape — a timeout racing a callback inside a
   task group:
   - `waitUntilReady` ran its deadline in a `Task` nobody awaited, so
     `readyTimeout` did nothing at all and a Dart side that never reported ready
     hung the intent until iOS killed it.
   - `start()` and `invoke()` did race their timeouts properly, but a task group
     awaits its children on the way out and a checked continuation ignores
     cancellation — so on timeout the loser stayed suspended and hung the very
     path meant to report it.

   All three now race through `OneShotContinuation`, where each side claims the
   continuation under a lock and exactly one wins.

   Compiling proves nothing about a rewrite of the runtime's concurrency, so
   `probe/run_integration.sh` was re-run on the simulator: `headless_isolate`,
   `static_round_trip`, `entity_queries` and `snippet_round_trip` all still
   pass. The timeout paths themselves remain unverified on a device — provoking
   one means a Dart side that never answers, which nothing here can arrange.

### Blocking Android

6. ~~**No app-shortcuts layer.**~~ Done. `sync` now writes
   `res/xml/os_intents_shortcuts.xml` and the strings it needs, with no flag and
   no version chain — a launcher shortcut per intent, plus an Assistant
   capability for each one that names a built-in intent through the new
   `androidCapability`. The manifest change is a single `<meta-data>` element.

   Shapes were measured first, in
   [`probe/android_shortcuts`](../probe/android_shortcuts): the file builds on a
   stock `flutter create` project, a data URI survives into the Intent the
   system builds, and no `intent-filter` is needed because a shortcut names its
   target component.

   Two things it deliberately will not do. It leaves an intent with a **required
   parameter** out of the launcher — a tap carries no values, so the shortcut
   would appear and then fail on use — and says so. And it will not guess a
   built-in intent from `phrases`: Android matches against Google's fixed
   catalogue, not the app's own wording.

   **This layer always opens the app.** A `shortcuts.xml` `<intent>` starts an
   Activity, so `Execution.background` does not mean headless here; the plugin
   routes the launch into the UI isolate. Headless is what the AppFunctions
   layer, and its version chain, exist for.
7. ~~**`Execution.static_` does nothing on Android.**~~ Done.
   `publishStaticValues` writes to `SharedPreferences` and a generated
   `@AppFunction` for a static intent reads it before starting anything,
   falling through to the handler when nothing has been published yet — a first
   run, where running the handler beats answering with silence. The same
   read-first shape as the generated Swift, and the same wire format, which is
   the part that had to agree.

   Stored as JSON in one entry rather than a preference per field:
   `SharedPreferences` holds primitives and a result carries a nested snippet
   spec. iOS solved the same problem by flattening into a property list.

   Only the AppFunctions path collects on this. A shortcut starts an Activity,
   so on that layer the engine is up regardless and there is nothing to save.

### Later

8. Interactive snippets, `AssistantIntent` schemas (iOS 18+), confirmation flows
   (`IntentResult.needsConfirmation` is modelled but nothing consumes it),
   `IntentResult.value` chaining in Shortcuts.

---

## 5. Decisions waiting on a human

**~~How should Android AppFunctions be gated?~~** Decided: opt-in, behind
`os_intents sync --android`, so the version chain is never imposed on anyone who
did not ask. The other half of that recommendation — an app-shortcuts layer as
the default for everyone else — is built too, and item 6 covers what it does and
does not do.

**Is `install`'s pbxproj editing acceptable, or should the provider file be a
documented manual step?** Still a judgement call, but a smaller one than it was.
`install` no longer depends on the template's object ids, refuses anything it
does not recognise, and names the manual step when it does — so the failure mode
is a message rather than a broken project, and the manual path stays available
for anyone who wants it. What is still unproven is Xcode's own reaction over
time: a project it reformats after a version bump has only been reasoned about,
not observed.

**~~What is the package actually called?~~** Checked 2026-07-31:
`pub.dev/packages/os_intents` returns 404 and the search API does not list it, so
the name is free. Nothing to change — it is already baked into the generated
Swift, the channel names and the CLI.

The same search turned up prior art nobody had looked for: `flutter_app_intents`,
`app_intents`, `app_intents_annotations`, `flutter_assistant_intents`,
`sirikit_media_intents` and `intelligence` all occupy some part of this space.
None of them has been read. Worth an hour before the README makes claims about
being the first or the only one — and worth knowing whether one of them already
solved something here the hard way.

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
