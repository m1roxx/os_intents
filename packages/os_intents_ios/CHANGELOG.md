## 0.2.0

### macOS

The package serves macOS 13+ as well as iOS 16+. Same Dart, same Swift: the
macOS `Sources/` is a symlink into `ios/` rather than a copy, because both
builds compile the same four files and a copy is two things to keep in step.

What differs is inside them, under `#if`, and is four things — every one found
by a build rather than by reading:

- Flutter ships as `Flutter` on iOS and `FlutterMacOS` on macOS.
- `FlutterPluginRegistrar.messenger` is a property there and a method here.
- `FlutterEngine` has **no `libraryURI` parameter** on macOS, so a headless
  engine can only reach an entrypoint in the library holding `main()`. The
  engine reports that rather than starting and failing with the bare `false` a
  missing URI produces.
- `destroyContext` is iOS-only; macOS has `shutDownEngine`, whose header is
  explicit that an engine not shut down before release leaks.

`OsIntentsSnippetView` now carries `@available(iOS 16.0, macOS 13.0, *)` and its
inner gate names macOS 14. `#available(iOS 17.0, *)` alone reads as *satisfied*
on macOS at any version, which is how the view compiled an iOS-17 branch against
its own 10.15 floor and failed on SwiftUI API from macOS 11 and 12.

The podspec also stopped describing itself as "a new Flutter plugin project" at
`http://example.com`.

### The shortcut half of the contract

`pushDynamicShortcut` and its neighbours answer "nothing published" here. Not a
gap facing the other way from Android's `donate`: a dynamic shortcut is a
launcher entry an app owns, the nearest iOS thing is a Home Screen quick action
declared in `Info.plist` rather than pushed at runtime, and what actually serves
the same purpose on this platform is `donate`, which is implemented.

### More kinds of parameter

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
