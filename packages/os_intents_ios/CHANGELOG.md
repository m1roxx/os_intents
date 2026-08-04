## Unreleased

`IntentOutcome` gains `urlValue` and `durationValue`, for intents declaring
`returns: Uri` or `returns: Duration`.

Nothing here imports AppIntents, deliberately: the file staging an `IntentFile`
needs is generated into the app target instead, where everything else naming an
App Intents type already lives. The plugin's deployment floor stays at iOS 13.

## 0.1.0

First released version. iOS implementation of
[os_intents](https://pub.dev/packages/os_intents) — you depend on that package,
and this one resolves with it.

Carries the runtime the generated Swift calls into: the bridge from an
`AppIntent` to your Dart handler, a second `FlutterEngine` for invocations that
arrive with no scene attached, the `UserDefaults`-backed store an
`Execution.static_` intent answers from, the entity-query channel, the snippet
card view, and the lookup that lets a donation reach a generated intent the
plugin cannot import.

Compiles clean under both Swift 5 and the full Swift 6 language mode, which a
test keeps true. iOS 16+.
