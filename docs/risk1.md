# Risk #1 — where does generated Swift have to live?

## Why this comes before any code

App Intents are a **compile-time** contract. Xcode runs an "Extract App Intents
Metadata" step over each target and writes `Metadata.appintents` into the app
bundle; Siri, Spotlight and the Shortcuts app read only that. There is no
runtime registration API, so nothing a Flutter app declares from Dart can ever
become an App Intent on its own.

That means `os_intents` must generate Swift. The only open question is *where*
it may put it, and the answer changes the shape of the whole package:

| Outcome | Where generated Swift goes | What install looks like |
|---|---|---|
| **Plan A** | plugin module, `Sources/os_intents_ios/` | `flutter pub get`. Nothing else. |
| **Plan A′** | plugin module + one bridge file in Runner | `pub get` plus a single generated file added to the app target |
| **Plan B** | app's Runner target | CLI must patch `project.pbxproj` — fragile across Xcode versions |

Writing the emitter before knowing this would mean writing it twice, so the
probe runs first.

## Design of the experiment

Two builds of one app, differing by a single compile flag.

**Control — `ProbeRunnerIntent`.** Declared in `ios/Runner/AppDelegate.swift`,
i.e. compiled directly into the app target. This is the arrangement every
existing Flutter App Intents package forces on its users, so it must show up in
both builds. If it does not, the probe is broken and no conclusion about plugin
modules is valid.

**Subject — `ProbePodIntent`.** Declared in
`packages/os_intents_ios/ios/os_intents_ios/Sources/os_intents_ios/ProbeAppIntents.swift`,
inside the plugin module. It is deliberately **never referenced** from Dart or
from the Runner target — the `AppShortcutsProvider` lists only the control
intent. The only thing that can pull it into the bundle is metadata extraction
itself.

**Variant A.** No bridge. Does an intent in the plugin module reach
`Metadata.appintents` on its own?

**Variant B.** `Runner` declares

```swift
struct ProbeAppPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [OsIntentsPackage.self] }
}
```

which is Apple's documented way for an app to opt into intents vended by a
framework or Swift package. Toggled with `-D OS_INTENTS_BRIDGE` in
`OTHER_SWIFT_FLAGS`.

`SWIFT_ACTIVE_COMPILATION_CONDITIONS` would have been the more idiomatic switch,
but Flutter's Runner target sets it in `project.pbxproj`, where it overrides
anything an `.xcconfig` says. `OTHER_SWIFT_FLAGS` is unset at target level, so
the xcconfig wins — that is why the probe uses it.

The probe app's deployment target is raised to iOS 16.0 (App Intents' minimum)
so that availability cannot be confounded with visibility.

## Running it

```bash
./probe/risk1_metadata/run_probe.sh
```

Artifacts land in `probe/risk1_metadata/probe-results/`:

- `build-A.log`, `build-B.log` — full build output
- `metadata-A.txt`, `metadata-B.txt` — every `Metadata.appintents` bundle found
  in `Runner.app`, plus which intent names occur anywhere in the bundle

## Note on Flutter 3.44

Flutter now generates plugins in Swift Package Manager layout
(`ios/<name>/Package.swift` + `Sources/`) alongside a CocoaPods podspec pointing
at the same sources. Which integration is active changes how a plugin's code is
linked, and therefore may change this answer. The probe records the Flutter and
Xcode versions in its output for that reason; **re-run it when either changes.**

## Verdict

**PLAN A.** Measured 2026-07-30 on Flutter 3.44.8 (stable) / Xcode 26.0,
iOS simulator, debug build, **Swift Package Manager** integration (no `Pods`
directory was produced).

```
control   (ProbeRunnerIntent, Runner target): in metadata ✓
variant A (ProbePodIntent, plugin module):    in metadata ✓
variant B (ProbePodIntent, plugin module):    in metadata ✓
```

An intent declared inside a Flutter plugin module reaches
`Metadata.appintents/extract.actionsdata` **on its own** — no `AppIntentsPackage`
bridge, no Xcode surgery, and without being referenced from Dart or from the app
target. The entry is complete, not incidental:

```json
"ProbePodIntent": {
  "fullyQualifiedTypeName": "os_intents_ios.ProbePodIntent",
  "identifier": "ProbePodIntent",
  "mangledTypeName": "14os_intents_ios14ProbePodIntentV",
  "isDiscoverable": true,
  "openAppWhenRun": false,
  "title": { "key": "Probe Pod Intent" },
  "descriptionMetadata": {
    "descriptionText": { "key": "Declared inside the os_intents_ios plugin module." }
  },
  "availabilityAnnotations": { "LNPlatformNameIOS": { "introducedVersion": "16.0" } }
}
```

Variant B shows the bridge is unnecessary but harmless. Do not adopt it as the
baseline anyway: `AppIntentsPackage` is **iOS 17+**, while `AppIntent` itself is
iOS 16+ — using it as the mechanism would silently cost every iOS 16 user the
feature. (The first run of this probe failed to compile for exactly that reason.)

### Consequence for the package

The generator writes Swift into `os_intents_ios/ios/os_intents_ios/Sources/`.
`flutter pub get` is the entire install step, and `os_intents_cli install` loses
most of its reason to exist — it shrinks to App Group provisioning and the
Android/Gradle wiring.

## Risk #1b — phrases are a separate question, and it is NOT answered

The probe measured intent *discoverability*, and that is all it measured.
`Metadata.appintents/root.ssu.yaml` — the Siri phrase training data — contains
only `ProbeRunnerIntent`:

```yaml
intents:
- metadata:
    name: ProbeRunnerIntent_0
    title: Probe Runner Intent
  corpuses:
    training:
    - locale: Base
      utterances:
      - Run runner probe in ${+applicationName}
```

That is expected here (the probe's `AppShortcutsProvider` deliberately lists only
the control intent), so it is **not** evidence that a provider must live in the
app target — the probe simply never tested it. Apple documents at most one
`AppShortcutsProvider` per app, which makes it the likely exception to Plan A.

Practical reading for now:

| capability | source needed |
|---|---|
| Shortcuts app, Spotlight, agent invocation | plugin module — **confirmed** |
| spoken "Hey Siri …" phrases | needs `AppShortcutsProvider` — **untested** |

### Verdict on 1b — phrases need the app target

Measured 2026-07-30, same toolchain. `./probe/risk1_metadata/run_probe_1b.sh`.

The plugin module always declares `ProbePodShortcuts` ("Run pod probe in
&lt;app&gt;"); the Runner's own provider is gated by `-D PROBE_RUNNER_SHORTCUTS`.

```
variant P — plugin phrases in root.ssu.yaml: absent ✗
variant D — plugin phrases, app also has a provider: absent ✗
variant D — app phrases: PRESENT ✓
```

**Variant P (only the plugin declares a provider)** — `root.ssu.yaml` is not
produced at all, and `extract.actionsdata` reports:

```
autoShortcutProviderMangledName: (none)
autoShortcuts: []
```

**Variant D (both declare one)** — the app's provider is selected and the
plugin's is ignored:

```
autoShortcutProviderMangledName: 6Runner14ProbeShortcutsV
autoShortcuts: [{ "actionIdentifier": "ProbeRunnerIntent",
                  "phraseTemplates": [{"key": "Run runner probe in ${applicationName}"}] }]
```

The mangled name resolves to module `Runner` — the extractor picks the provider
from the **app's own module** and nowhere else.

Note the failure mode: variant D **built cleanly**. A provider declared in a
plugin is not rejected, not warned about, just silently dropped. Anyone shipping
this without the probe would have found out from bug reports.

### What this costs the design

| capability | where it must be declared | status |
|---|---|---|
| intents, entities, queries — Shortcuts app, Spotlight, agents | plugin module | free (Plan A) |
| spoken "Hey Siri …" phrases | app target, exactly one provider | needs the CLI |

So `os_intents_cli install` survives, but its iOS job shrinks to one thing:
write `ios/Runner/OsIntentsShortcuts.swift` and add that single file to the
Runner target in `project.pbxproj`. After the first install the file is only
rewritten in place, so the pbxproj is touched exactly once per project.

Two consequences the generator has to respect:

1. **One provider per app is a hard limit.** If the host app already declares an
   `AppShortcutsProvider`, emitting a second is not an error — it is a silent
   loss. The generator must detect an existing provider and merge its shortcuts
   into the generated one rather than adding a rival.
2. **`doctor` needs a check for this**, because nothing else in the toolchain
   will tell the user their phrases went nowhere: read
   `Metadata.appintents/extract.actionsdata` from the built app and report the
   selected `autoShortcutProviderMangledName` and the phrase count.

An honest fallback if pbxproj patching proves fragile: ship the provider as a
documented 8-line file the user adds to Runner once by hand. Everything else
still comes from `pub get`.
