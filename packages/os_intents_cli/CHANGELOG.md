## 0.2.0

### macOS

`sync` writes the generated Swift into every Apple project the app has, and
`install` registers it with each. Detected rather than flagged: macOS costs
nothing here — no version chain, no extra dependency, the same Swift — so what
decides whether an app gets macOS intents is whether it is a macOS app.

`sync` also notes the one thing that differs at run time: macOS `FlutterEngine`
has no `libraryURI` parameter, so an intent that runs with the app closed needs
its handler in `main.dart`. While the app is open the router uses the UI isolate
and nothing is lost.

`doctor` finds and reads a macOS bundle. Two differences it had to learn: the
metadata sits under `Contents/Resources/`, and there is no `root.ssu.yaml` —
the extractor writes no phrase model on macOS, so its absence is reported as a
note rather than the error it is on iOS. Failing every macOS build over a file
the extractor does not write would be reporting our own assumption as a bug.

### Localisation

`sync --l10n` writes `OsIntents.xcstrings` and makes the generated Swift look
its text up in it. Off by default, and not out of caution: a keyed lookup with
no catalogue answering renders as the key, so an app would ship "addTask.title"
to Siri with nothing failing anywhere. The Swift and the catalogue arrive
together or not at all. Pass it to `--check` too.

`install` learned a second build phase. A `.xcstrings` goes into **Resources**,
typed `text.json.xcstrings`; in Sources it would never reach the bundle and
every lookup would fall back to its key — the same silent shape as an
unregistered Swift file, one phase over. `--check` covers both.

`AppShortcuts.xcstrings` is written only when the app deploys to iOS 17 or
later. Below that Xcode fails the build outright — measured, and it cost one —
and Apple reads phrases from per-language `AppShortcuts.strings` instead, which
is a variant group rather than one file. `sync --l10n` lists the keys and says
so rather than writing a file that breaks the build. Xcode extracts the English
half itself either way.

`doctor` resolves keys back through the catalogue, so the report still reads
"Add task" rather than "addTask.title" — with the key alongside, since a keyed
title is worth seeing.

### More kinds of parameter

`sync --android` names an intent it left out because a parameter has no Android
counterpart, and says what Android does instead.

`doctor` reads two more parameter types back out of a built bundle — `URL` and
`IntentFile`, whose type identifiers (`11` and `12`) come from a real build
rather than from a guess, which is the rule that table has always been kept to.
`doctor --android` now measures against the intents that were actually emitted,
so an intent left out for taking a file is no longer reported as missing.

## 0.1.1

Dependency constraints only — no command changed.

`xml` moves to 7. The two readers that use it, the `AndroidManifest.xml` editor
and the AppFunctions metadata parser, are on API that did not move; their tests
pass unchanged.

## 0.1.0

First released version. The only part of os_intents that touches a native
project, and the only one that can tell you whether the OS ever saw your work.

### Commands

- **`build`** — `build_runner`, then `sync`, then `install`, in the order they
  have to run. Every step is idempotent, which is what makes it safe as the
  habitual one.
- **`sync`** — carries the manifest into the native projects: Swift into
  `ios/Runner/OsIntents/`, app shortcuts and Assistant capabilities into
  `android/…/res/`. `--android` additionally emits AppFunctions Kotlin, which is
  opt-in because it forces a version chain on the consuming app.
- **`install`** — one edit per platform, each idempotent and each refusing
  rather than guessing when the project is not a shape it understands: the
  generated folder into the Xcode target, and one `<meta-data>` element into the
  launcher activity of `AndroidManifest.xml`. Both are decided against the
  parsed project and re-parsed before anything is written.
- **`doctor`** — reads `Metadata.appintents/extract.actionsdata` out of a
  **built** bundle, lists what the OS will see, and cross-checks it against the
  manifests. Generated Swift can be written, compiled and still invisible;
  nothing else in the toolchain reports that. `--android` reads the APK,
  `--device` asks `dumpsys shortcut` what the system actually accepted — three
  different questions that fail separately.

### For CI

- `sync --check` — the generated files match the manifest.
- `install --check` — the native projects reference those files. Added after a
  generated source turned out to have been compiling into nothing while every
  other step reported success.

Both write nothing and exit non-zero on drift.
