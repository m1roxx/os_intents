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

`dumpsys shortcut` independently shows the two generated shortcuts registered
against the app, labelled from the generated string resources — and `addTask`
correctly absent, since a tap could not supply its required parameter.

Independently, iOS itself indexed the generated intents: the Shortcuts daemon
logged `Indexed: 3, Errored: 0` and loaded `LNActionMetadata`, `LNEntityMetadata`
and `LNQueryMetadata` for the example's bundle.

## Verified by building, not by running

- The generated Swift compiles into an app and reaches
  `Metadata.appintents/extract.actionsdata` with entities, queries and phrases
  intact.
- The generated Kotlin compiles, KSP accepts it, and the descriptions written in
  Dart come out the far end in the APK's AppFunction metadata. A foreground
  intent is correctly left out.

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

## Not implemented yet

Interactive snippets; `AssistantIntent` schemas (iOS 18+); confirmation flows
(`IntentResult.needsConfirmation` is modelled, but nothing consumes it yet);
`IntentResult.value` chaining in Shortcuts. Entities and snippet cards are iOS
only.

## Health

152 tests — 6 in `os_intents`, 93 in `os_intents_gen`, 53 in `os_intents_cli` —
`flutter analyze` clean across the workspace, the example app builds for iOS, the
probe app builds for Android.

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
