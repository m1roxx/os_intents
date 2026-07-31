# os_intents_platform_interface

The common platform interface for
[`os_intents`](https://pub.dev/packages/os_intents).

This package is not meant to be imported by apps. It declares the contract that
the platform implementations — [`os_intents_ios`](https://pub.dev/packages/os_intents_ios)
and [`os_intents_android`](https://pub.dev/packages/os_intents_android) — fulfil,
so the app-facing package can talk to either without knowing which.

## What the contract covers

- installing the handler the native side routes an invocation to, on the UI
  isolate or the headless one;
- installing the handler that answers entity queries — `entities.byIds`,
  `entities.matching`, `entities.suggested`;
- publishing static values, which is how `Execution.static_` answers with no
  Dart running at all.

The `background` flag on the handler setters is not a detail: the headless
engine has its own binary messenger, so it needs its own channel. A channel
created in one isolate is invisible to the other.

## The wire format is the real contract

Both implementations decode the same shapes, and no compiler can catch a
disagreement — change one side and the other breaks silently, at run time rather
than at build time.

- `DateTime` crosses as **epoch milliseconds, UTC**.
- An entity crosses as **its identifier**, not as an object.
- An `IntentResult` crosses as a tagged map: `done`, `dialog`, `snippet`. The
  tag is open on purpose — a native side that meets a kind it does not know
  should treat it as `done` rather than fail, so a newer app package can add
  one without breaking an older implementation.

## Implementing it

Extend `OsIntentsPlatform` rather than implementing it, and pass the
verification token. `implements` would let a method added later break your class
silently, which is exactly what the token exists to prevent.
