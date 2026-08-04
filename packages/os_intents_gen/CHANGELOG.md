## Unreleased

`ParamType` gains `uri`, `duration`, `measurement` and `file`, and `ParamSpec`
gains a `dimension`. All three emitters carry them.

The Swift mappings were type-checked against the real SDK before they were
written down, which is what `swift_compiles_test` is for — and it earned its
place immediately. `Measurement`'s `defaultUnit:` argument exists for 22
dimensions, and **fifteen of them are iOS 17**; only `duration`, `energy`,
`length`, `mass`, `speed`, `temperature` and `volume` are iOS 16. So
`MeasurementDimension` is those seven, and the package's floor did not move.

The test now puts every dimension, every new parameter type in both its required
and optional form, and every new return type through `swiftc -typecheck`.

`KotlinEmitter` filters an intent with a file parameter out of the AppFunctions
surface and reports it through `unsupported`, the same shape as leaving a
foreground intent out — an `@AppFunction` cannot describe a file, and a `String`
that looked like one would be worse than its absence.

## 0.1.1

Dependency constraints only — the generated Dart, Swift and Kotlin are byte for
byte what 0.1.0 emitted.

`analyzer` is now `>=8.4.1 <15.0.0` and `build` is `>=3.0.2 <5.0.0`, so the
builder resolves against the majors those packages are on today instead of
holding an app back to `analyzer` 8. The one API in the parser that did not
survive that range was `FieldElement.isSynthetic`; it is gone, and nothing
replaced it, because a synthetic field carries no metadata of its own and the
`@EntityId` and `@EntityDisplay` lookups already skipped it.

The `xml` dev dependency, which only `emit_shortcuts_test.dart` uses, moves to 7.

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
