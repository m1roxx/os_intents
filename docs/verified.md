# What is verified, and what is not

`README.md` is the pitch. This is the evidence behind it — and, more usefully,
the list of things the pitch does **not** cover. Every claim here says how it was
established: run on a device, compiled only, or never observed.

Measured on Flutter 3.44.8 / Xcode 26.0, an iPhone 17 simulator and an API 36
Android emulator.

**Pre-alpha.** Both pipelines work end to end and are verified on a device. No
real user's app has shipped on this.

## Verified on a device

Not "compiles" — actually ran. iOS via [`probe/run_integration.sh`](../probe/run_integration.sh):

| Check | What it proves |
|---|---|
| `headless_isolate` | A handler ran with no UI, and in a *different* isolate — the UI-side counter stayed at 0 |
| `static_round_trip` | `publishStatic` and the native read side agree |
| `entity_queries` | `@EntityQuery` answers, and the wire keys match what the generated Swift reads |
| `snippet_round_trip` | A card survives the store, spec and spoken text both |
| `donation` | Dart → channel → the generated class found by ObjC name → a real `AppIntent` rebuilt from wire values → `IntentDonationManager` accepted it. An unknown id is refused |

And once by hand, which is the check that matters most. Tapping an App Shortcut
in the **Shortcuts app** — a real, system-initiated invocation — produced:

```
Runner[91295] OSINTENTS_HOST intent=addTask process=Runner
              bundle=dev.osintents.osIntentsExample uiEngine=yes
```

iOS launched the app's own process **in the background** (background assertion,
never foregrounded), prompted for the missing parameter using the
`requestValueDialog` written in Dart, ran `perform()` in that process, and
Shortcuts displayed `Added "…"` — the Dart handler's own return value. The app
never appeared on screen.

That is the whole pitch, minus the voice: the OS invoked it, the handler ran, the
app stayed out of sight. It also settles the `WFIsolatedShortcutRunner` question
that other designs in this space turn on — that process exists and is running
here, but an intent compiled into the app target does not execute inside it.

Android via [`probe/run_android_integration.sh`](../probe/run_android_integration.sh):

| Check | What it proves |
|---|---|
| `headless_engine` | A second `FlutterEngine` started inside the app process, found the generated entrypoint by name, and ran the handler — the UI isolate's list stayed at 0 |
| `unknown_intent_fails` | An unknown id fails loudly instead of hanging |
| `shortcut_routing` | The Intent an app shortcut builds reaches the handler, on the UI isolate |
| `static_round_trip` | `publishStatic` and the native read side agree, so a static intent can answer without an isolate |
| `donation_declined` | `donate` returns false rather than throwing — the documented contract, so one code path can call it on both platforms |

`dumpsys shortcut` independently shows the two generated shortcuts registered
against the app, labelled from the generated string resources — and `addTask`
correctly absent, since a tap could not supply its required parameter.

Independently, iOS itself indexed the generated intents: the Shortcuts daemon
logged `Indexed: 3, Errored: 0` and loaded `LNActionMetadata`, `LNEntityMetadata`
and `LNQueryMetadata` for the example's bundle.

## Verified by reading the built artefact

Neither of these needs a device, and both answer the question no other step in
the toolchain can: the code was generated, it compiled, and it can still be
invisible to the OS.

- **iOS** — `os_intents doctor` reads `Metadata.appintents/extract.actionsdata`
  out of a built `.app` and reports the intents, parameters, entities, queries
  and phrases the system will see, then cross-checks them against the manifests.
- **Android** — `os_intents doctor --android` reads the built APK: the
  AppFunction metadata KSP wrote into `assets/` as plain XML, and whether the
  shortcuts XML was packaged. It reports the descriptions that travelled from
  Dart through KDoc, and the optionality the runtime will actually enforce —
  which is not what the file says, because a nullable property counts as
  optional however `<required>` lists it.

Both readers are pure and tested against files captured from real builds, so
they need neither Xcode nor the Android SDK to run.

- **Android, on a device** — `os_intents doctor --device` asks
  `dumpsys shortcut` what the system actually registered after install. That is
  a third thing again: `ShortcutManager` silently drops what it will not accept,
  caps how many it holds, and resolves labels through the resource table, none
  of which the APK knows. Verified against a real emulator, and its parser is
  fixture-tested against a dump captured from one.

## Verified by building, not by running

- The generated Swift compiles into an app and reaches
  `Metadata.appintents/extract.actionsdata` with entities, queries and phrases
  intact.
- The generated Kotlin compiles, KSP accepts it, and the descriptions written in
  Dart come out the far end in the APK's AppFunction metadata. A foreground
  intent is correctly left out.
- **The whole toolchain, from a blank `flutter create`** —
  [`probe/run_cold_start.sh`](../probe/run_cold_start.sh). A throwaway project
  *outside* the workspace, two annotated functions and an `@AppEnum`, one
  `os_intents build`: the registry and manifest are generated, the Swift and the
  shortcuts XML written, the Runner target and `AndroidManifest.xml` edited, and
  both `flutter build apk --debug` and `flutter build ios` then accept the
  result. The APK is the check that matters for the manifest edit, since aapt
  rejects a `<meta-data>` pointing at a resource it cannot find.

  Outside the workspace on purpose: every other check here resolves the six
  packages locally, which is not what a consumer from pub.dev gets, and that
  difference has already hidden a missing dependency once.
- **`install` survives another tool rewriting the project.** CocoaPods
  re-serialises `project.pbxproj` on every `pod install`, so every
  `flutter build ios` reorders the file under us. Round-tripped through
  CocoaPods' own serialiser: nothing is dropped, and re-running `install`
  afterwards returns the file unchanged rather than adding a second copy of
  everything. The rewritten project is a test fixture.

## Not verified at all

- **Invocation by Siri specifically.** The OS calling `perform()` is covered —
  from the Shortcuts app, above. Getting a simulator to speak a phrase is not
  something this setup can arrange, so the voice path in particular remains
  unobserved.
- **The dedicated headless engine under a real invocation.** iOS launching the
  app cold from an intent *has* been observed — but it launched the app's own
  process with its normal engine, so `OsIntentsBackgroundEngine` was not the
  thing that served it. The case it was built for has never been seen.
- **An agent invoking an AppFunction.** The bridge half is proven; the path from
  a real assistant through `AppFunctionService` has never run, because Gemini's
  integration is in a private EAP.
- **The timeout paths in the iOS bridge.** They were rewritten to fix three
  hangs, and they compile and pass their unit tests — but provoking one on a
  device means a Dart side that never answers, which nothing here can arrange.
- **A donation actually producing a suggestion.** `IntentDonationManager`
  accepting the intent is verified on a device, which covers every link the
  package owns. Whether iOS then puts the action in front of the user is a
  decision by a ranking model over days of real use, and nothing observable
  from here reports on it. The claim stops at "accepted".

## What a handler can answer with

Three shapes, and the generated code acts on all three:

| | |
|---|---|
| `IntentResult.done()` | succeeded, nothing to say |
| `IntentResult.dialog(spoken)` | succeeded, and Siri speaks it |
| `IntentResult.snippet(spec)` | succeeded, with a card — needs `showsSnippet: true` |
| `IntentResult.value(x)` | succeeded, handing a value to the next Shortcut step — needs `returns:` |

`returns:` carries the type because Swift fixes `perform()`'s return type at
compile time and `value(Object)` is untyped in Dart: `ReturnsValue<T>` has to
be known when the code is generated, not when the handler runs. `String`,
`int`, `double`, `bool` and `DateTime`; anything else is refused by the
generator rather than compiled into Swift that will not build. iOS only — on
Android an AppFunction answers with a fixed reply object.

Two more were modelled in Dart before anything was wired to them, and are
**not** in this release. The generated `perform()` did not branch on the result
kind, so each was encoded, sent across the wire, and dropped:

- **`IntentResult.needsConfirmation`** — the modelling was wrong, not just the
  wiring. The handler has already run and already had its effect by the time it
  returns anything, so "ask the user first" cannot be expressed as a return
  value.

  It came back as `@AppIntent(confirmBeforeRunning: 'Delete everything?')`,
  which is where it belonged: a property of the action, fixed when the code is
  generated. The generated `perform()` asks before it calls into Dart, so a
  refusal means the handler never ran. The prompt needs iOS 18; on 16 and 17
  the system still asks in its own words, and the generated Swift picks the
  richer call where it exists.
- **`IntentResult.openApp`** — `openAppWhenRun` is a compile-time constant
  derived from `Execution`, not a decision a handler can make at run time.

These were removed rather than documented as broken: a factory whose name
promises something the system never does is worse than its absence, and in a
0.1.0 with no dependents removal costs nothing. Each returns as an addition,
which is not a breaking change; leaving them in and fixing them later would
have been.

## Also not implemented

Interactive snippets, and `AssistantIntent` schemas (iOS 18+).

Entities and snippet cards are iOS only, and for entities that is not a gap
waiting to be filled. An entity parameter does cross to Android — as its
identifier, same wire format as iOS, resolved by your handler — but there is no
counterpart to `@EntityQuery`, and not because nobody wrote one:
`androidx.appfunctions` 1.0.0-alpha10 has no entity concept at all. Its
AppSearch index holds the app's *functions*, not its data, and the only way to
narrow a parameter is a fixed set fixed at compile time. Measured by reading
the library, and written up in [android.md](android.md).

Snippet cards have no Android counterpart either; an assistant renders its own
presentation from what the function returns.

**Enums are the part that does work on both.** A Dart enum annotated
`@AppEnum` becomes a real `AppEnum` on iOS and an
`@AppFunctionStringValueConstraint` on Android — a closed set needs no query,
which is exactly why it survives the gap entities fall into. The wire value is
the constant's own name on both platforms, so reordering the Dart enum cannot
silently repoint a shortcut someone already built.

An enum parameter is confirmed in the built bundle, not only in the emitters:
`doctor` reads it back out of the example's `extract.actionsdata` as
`priority linkEnumeration optional`.

## Health

246 tests — 7 in `os_intents`, 121 in `os_intents_gen`, 118 in `os_intents_cli` —
`flutter analyze` clean across the workspace, the example app builds for iOS, the
probe app builds for Android.

Analysis covers **generated** Dart too. Excluding `**/*.g.dart` is the ordinary
thing to do and it hid a real defect here: the generator emitted the literal
word `null` as a type name, the example stopped compiling, and analyze stayed
green because it never looked. The emitter writes `// ignore_for_file: type=lint`
into everything it produces, so what analysis sees there is errors only.

The device harnesses are the reason this file can be specific. Re-run them when
Flutter, Xcode or `androidx.appfunctions` moves:

```bash
./probe/run_integration.sh           # iOS, needs a booted simulator
./probe/run_android_integration.sh   # Android, needs a booted emulator
```

Why they run the checks from `main()` behind a `--dart-define` rather than
through the UI: injected taps do not reach Flutter's gesture layer reliably, and
no test can arrange for Siri or an agent to invoke a real intent.

Design decisions and their measurements: [risk1.md](risk1.md) for where generated
Swift may live, [android.md](android.md) for what each Android layer costs.
