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
| `snippet_buttons` | A card carrying a button survives the static store — nested lists of nested maps through a property-list-only path, which has taken the app down before |
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
| `dynamic_shortcuts` | The Android half of "offer this back": `ShortcutManager` accepted the entry, listed it, replaced it on the same id, and removed it. Room for 15 on this device |

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

  This is also where the parameter types are checked rather than assumed. A
  `Uri`, a `Duration`, a `Measurement` and an `IntentFile` were added to the
  example, built, and read back out of the bundle as `URL`, `measurement`,
  `measurement` and `IntentFile` — so the type identifiers in the reader's table
  (`11` for a URL, `12` for a file) come from a build rather than from a guess,
  which is the rule that table has always been kept to.
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
- **A snippet button being tapped.** The card is rendered inside Siri and
  Shortcuts, and nothing here can reach that surface. What is proven: the
  button is built from a real intent type, the whole thing type-checks against
  the SDK, and a card carrying one survives the store a static intent answers
  from.
- **A dynamic shortcut being tapped.** That it reached `ShortcutManager` and
  came back out is verified above, and the Intent it carries is the same shape a
  generated app shortcut builds — which `shortcut_routing` does prove end to
  end. What has never happened is a tap on the entry itself: the emulator image
  that boots here ships no launcher, which is the same reason that check starts
  the Activity by hand.
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

`AssistantIntent` schemas — a decision rather than a gap. The macro enforces its
contract through protocol conformance (`.reader.openPage` requires
`OpenIntent`), so emitting one from an arbitrary Dart function produces Swift
that does not build; supporting it honestly means encoding the parameter
contract of 143 schemas that Apple has already renamed once.

Snippet cards can carry **buttons** (iOS 17+), but not Apple's iOS 26
`SnippetIntent`, where the card reloads itself after a button runs.

## Localisation, and the two mechanisms it turned out to be

`sync --l10n` makes the generated Swift look every title, description, prompt
and choice up by key, and writes the String Catalogue that answers. Verified end
to end on the example, not only in the emitters: keys in the Swift → merged
catalogue → `install` into the Runner target's **Resources** phase → built →
`en.lproj/OsIntents.strings` in the bundle with every key resolving to the right
text → `doctor` reading it back.

Three findings, each of which changed the design:

- **A keyed lookup is not a drop-in for a literal.** `TypeDisplayRepresentation`
  and `IntentDialog` accept a bare string by conversion but a
  `LocalizedStringResource` only through an initialiser, and an `AppEnum`'s case
  display representation stops being a string at all. So the localised output is
  a different program, and `swift_compiles_test` type-checks both.

- **`AppShortcuts.xcstrings` needs iOS 17**, which the ordinary catalogue does
  not. Measured, and it cost a build: an app deploying to 13 fails outright with
  "AppShortcuts.xcstrings is only supported for iOS 17.0 and above. Use
  AppShortcuts.strings for previous versions." The two are read by different
  build steps — a normal catalogue becomes `.strings` at build time, the phrase
  table is consumed by a step that is 17-only. Below 17, `sync --l10n` writes
  everything else and lists the phrase keys rather than writing a file that
  breaks the build.

- **Phrases cannot be keyed at all, and do not need to be generated.**
  `AppShortcutPhrase` is `ExpressibleByStringInterpolation` over a plain
  `String` — there is no `LocalizedStringResource` initialiser anywhere in the
  SDK — so the English phrase is its own key. And Xcode extracts them itself:
  deleting `en.lproj/AppShortcuts.strings` from a built bundle and rebuilding
  regenerates it. The keys use `$app`, the same token written in Dart, not the
  `\(.applicationName)` the generated Swift contains.

**The catalogue is the one generated file os_intents will not overwrite.** It
holds translations that came from a person, so `sync` merges: keys are added,
translations kept, and a key nothing declares any more is reported rather than
removed. A changed source string marks the other languages `needs_review`, which
is what Xcode does and what makes the staleness visible in the editor the file
will be opened in.

`doctor` resolves keys back through the catalogue, so the report still reads
"Add task" rather than "addTask.title" — with the key alongside, since a keyed
title is itself worth seeing.

**Not verified:** a device showing a *translated* string. What is proven is that
the source language resolves out of the built bundle; that a second language
does the same is Foundation's own lookup, and nothing here adds to it.

## What a parameter may be, and what it costs

`String`, `int`, `double`, `bool`, `DateTime`, `Uri`, `Duration`,
`Measurement`, `IntentFile`, an `@AppEntity` class and an `@AppEnum` enum. The
last three of the plain ones are new, and each carries a finding worth keeping:

- **A `Duration` is not a `Date`.** App Intents has no duration type; the
  system's shape for "how long" is a `Measurement<UnitDuration>` with a unit
  picker. It crosses the wire as **microseconds** — Dart's own integer form of a
  `Duration`, the same rule by which a `DateTime` crosses as its
  `millisecondsSinceEpoch`. One rule, not two.

- **`Measurement` has seven dimensions here and App Intents has 22.** The other
  fifteen — area, angle, pressure, power, frequency, information storage and
  every electrical and optical one — are **iOS 17**, while `length`, `mass`,
  `duration`, `speed`, `temperature`, `volume` and `energy` are iOS 16. Measured
  rather than read off documentation: the 22-dimension case in
  `swift_compiles_test` failed with fifteen "only available in iOS 17.0 or
  newer", which is how the split was found at all. Supporting the rest means
  either raising the floor for everyone or version-gating a struct that three
  other generated files name, so the list stops where the package's floor does.

- **`IntentFile` is iOS only, and not for want of trying.** Read out of
  `androidx.appfunctions` 1.0.0-alpha10 the same way the entity question was:
  there is no file type in the library. What it has is `AppFunctionUriGrant` —
  Android's model is a content URI plus a permission grant, which is a different
  shape rather than a missing feature. An intent taking a file is therefore left
  out of the AppFunctions surface entirely, with `sync --android` naming it and
  the parameter; its app shortcut is unaffected. The same reading turned up an
  `AppFunctionUri` serialisable proxy for `android.net.Uri`, so a `Uri`
  parameter probably has a richer Kotlin type available than the `String` it
  gets — nothing here has built an APK through it, so it stays a `String`.

Incoming files are staged: the plugin writes what the system supplied into the
app's temporary directory before the handler runs, so the path is always
readable. That costs a copy per invocation, and the system's own `fileURL` is
deliberately not passed through — it may be security-scoped and gone by the time
an isolate reaches it.

**What is not verified:** a real file arriving from Siri or Shortcuts. The
staging helper compiles against the SDK, the round trip through the wire format
is unit-tested from both ends, and `doctor` confirms the parameter reached the
bundle as an `IntentFile` — but nothing here can make the system hand over a
document.

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

296 tests — 16 in `os_intents`, 156 in `os_intents_gen`, 124 in `os_intents_cli` —
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
