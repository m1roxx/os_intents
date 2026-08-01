# What this package is for

You do not depend on this directly. Add
[os_intents](https://pub.dev/packages/os_intents) and this resolves with it.

It carries the Swift the *generated* code calls into. Nothing here is meant to
be written by hand — but it is worth knowing what runs, because every failure in
this space is silent.

## What the generated Swift looks like

`os_intents_gen` writes this into your app target; the only thing it knows about
this package is `OsIntentsBridge`:

```swift
@available(iOS 16.0, *)
struct AddTaskOsIntent: AppIntent {
  static let title: LocalizedStringResource = "Add task"
  static let openAppWhenRun = false

  @Parameter(title: "Title", requestValueDialog: "What should it be called?")
  var title: String

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let outcome = try await OsIntentsBridge.shared.invokeBackground(
      id: "addTask",
      args: ["title": title]
    )
    return .result(dialog: IntentDialog(stringLiteral: outcome.spoken ?? ""))
  }
}
```

Keeping that surface to one type is deliberate: generated output stays stable
across Flutter releases because it never touches a Flutter API.

## What this package does behind it

- **The bridge.** Routes an invocation to your Dart handler and waits for the
  answer. Prefers the UI isolate whenever the app is already running, so a
  handler sees the state the user is looking at.
- **A second `FlutterEngine`.** Since the scene-based lifecycle, the engine is
  created when a scene attaches — and a background launch attaches none. Started
  on demand, torn down after 20 s idle.
- **The static store.** Where `publishStatic` writes and an `Execution.static_`
  intent reads, with no engine at all. Plain `UserDefaults`: generated intents
  compile into the app target, so `perform()` runs in the app's own process and
  an App Group would buy nothing.
- **The snippet card**, and the lookup that lets a donation reach a generated
  intent this package cannot import.

## Two things it will not do

`AppIntentsPackage` is iOS 17+ while `AppIntent` is 16+, so it is not used —
building on it would silently cost every iOS 16 user the feature. And a
`FlutterMethodChannel` has to be used on the main thread, which is why the
locking here is a lock and not an actor.

Compiles clean under both Swift 5 and the full Swift 6 language mode, kept true
by a test.
