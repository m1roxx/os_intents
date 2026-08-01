## 0.1.0

First released version. The `build_runner` builder behind
[os_intents](https://pub.dev/packages/os_intents) — you add it as a dev
dependency and never call it directly.

Reads `@AppIntent`, `@Param`, `@AppEntity`, `@EntityQuery` and `@AppEnum`, and
emits:

- the Dart dispatcher that routes an invocation back to your function, plus the
  headless entrypoint when some intent needs one;
- `*.os_intents.json`, the manifest `os_intents_cli` carries into `ios/` and
  `android/` — which exists because `build_runner` derives output paths from
  input paths and cannot reach either;
- Swift `AppIntent` structs, entities, queries, enums, the `AppShortcutsProvider`
  and the donation decoder;
- Kotlin `@AppFunction` methods, and the Android shortcuts and strings XML.

Problems in your own annotations are build errors naming the offending
element — a phrase missing `$app`, a `returns:` type the system cannot carry, a
parameter on a static intent, an unannotated enum — rather than native code that
will not compile.

The emitters are pure functions from manifest to file contents, so they are
tested without an analyzer or a device. The Swift they produce is additionally
type-checked against the real `os_intents_ios` module by `swiftc -typecheck`,
where a warning counts as a failure.
