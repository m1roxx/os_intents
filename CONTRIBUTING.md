# Contributing

Issues and PRs are welcome. The ground rules below exist because this package's
whole pitch is that its claims are verified — a contribution that breaks that
property is a regression even when the code is right.

## Setup

The repo is a pub workspace pinned to a Flutter version via fvm:

```bash
fvm install            # reads .fvmrc
fvm flutter pub get    # once, at the root
```

Use `fvm flutter` / `fvm dart` throughout; the workspace resolves all six
packages locally.

## Checks that must stay green

```bash
fvm dart format .
fvm flutter analyze
```

Tests run per package, from the package directory (running several package
paths at once mis-resolves):

```bash
cd packages/os_intents     && fvm flutter test
cd packages/os_intents_gen && fvm dart test
cd packages/os_intents_cli && fvm dart test
```

`os_intents_gen/test/swift_compiles_test.dart` type-checks the emitted Swift
against the real plugin module — it needs Xcode and skips with a reason without
it. If you change an emitter or a bridge signature, run it; that is the test
that catches the two drifting apart.

CI also checks generated-file drift (`sync --check`, `install --check`) and
builds the example, so regenerate rather than hand-editing anything under
`ios/Runner/OsIntents/`, `*.g.dart` or `*.os_intents.json`.

## The rules that are easy to miss

- **Emitters are pure.** They take a `Manifest` and return file contents. Keep
  them that way; it is why they are testable without a device.
- **The wire format is a cross-platform contract.** `DateTime` crosses as epoch
  milliseconds UTC, entities as their identifier, on both platforms. A change
  on one side breaks the other silently at runtime — change both, and update
  the tests that assert the two ends agree.
- **Do not make the iOS and Android emitters symmetrical.** The platforms
  differ deliberately; the README and `docs/android.md` explain where and why.
- **Claims live in [docs/verified.md](docs/verified.md).** If your change makes
  a claim true (or false), update that file in the same PR. "Compiles" and
  "ran on a device" are different rows there, on purpose.

## Device verification

Anything touching the runtime path should be run through the harnesses:

```bash
./probe/run_integration.sh           # iOS, needs a booted simulator
./probe/run_android_integration.sh   # Android, needs a booted emulator
./probe/run_cold_start.sh            # blank flutter create → one build
```

They run self-checks from `main()` behind `--dart-define=OS_INTENTS_SELFCHECK`
and grep the device log — the README of `probe/` explains why not UI tests.

## Style

`dart format` settles formatting arguments. Comments state constraints the code
cannot show; they do not narrate the code. Match the density of what is around
you.
