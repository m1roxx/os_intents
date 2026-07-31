# os_intents_gen

The build-time half of [`os_intents`](https://pub.dev/packages/os_intents). You
do not import this package — you add it as a dev dependency and `build_runner`
does the rest.

```yaml
dev_dependencies:
  build_runner: ^2.4.13
  os_intents_gen: ^0.1.0
```

```bash
dart run build_runner build --delete-conflicting-outputs
```

The builder auto-applies to anything that depends on `os_intents`, so there is
no `build.yaml` to write.

## What it emits

Per annotated library, two files:

```
lib/intents.os_intents.g.dart    the registry OsIntents.install() consumes,
                                 plus the background entrypoint
lib/intents.os_intents.json      the manifest os_intents_cli sync turns into
                                 Swift, Kotlin and shortcuts XML
```

The manifest exists because `build_runner` derives output paths from input
paths, and so cannot write into `ios/` or `android/` at all. It stops next to
the generated Dart, and
[`os_intents_cli`](https://pub.dev/packages/os_intents_cli) carries it the rest
of the way.

The generated entrypoint carries `@pragma('vm:entry-point')`: nothing in Dart
references it, so without that a release build tree-shakes it out and the
headless engine fails to start with nothing but a `false`.

## The emitters

Four of them — Dart, Swift, Kotlin and Android shortcuts XML — and all four are
exported, because the CLI reuses them. Each takes a `Manifest` and returns
`Map<fileName, contents>`, with no analyzer, no file system and no device in the
loop. That is what makes the output testable as a string.

Where it stops being a string: `test/swift_compiles_test.dart` runs
`swiftc -typecheck` over the emitted Swift against the **real** `os_intents_ios`
module, so an emitter drifting from `OsIntentsBridge`'s signatures fails a test
rather than a device. Warnings fail it too. It needs Xcode, and skips with a
reason where there is none.

## Two things it refuses to do

- **A phrase without `$app` is an error.** Apple requires the app name in every
  utterance; rejecting it here is cheaper than finding out at App Review.
- **It will not guess an Android built-in intent from `phrases`.** Android
  matches against Google's fixed catalogue, not against wording the app chooses,
  so `androidCapability` is a lookup you make — not a translation the generator
  can do for you.

Full picture: [os_intents](https://pub.dev/packages/os_intents).
