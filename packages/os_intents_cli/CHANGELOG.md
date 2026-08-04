## Unreleased

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
