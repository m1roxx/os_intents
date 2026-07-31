# os_intents_ios

The iOS implementation of [`os_intents`](https://pub.dev/packages/os_intents).

This package is endorsed: depending on `os_intents` pulls it in automatically,
and you should not need to import it. It is documented here so that what runs on
the device is not a black box.

**iOS 16+.** `AppIntent` itself is iOS 16; `AppIntentsPackage` is iOS 17, which
is why the bridge is not built on it — that would silently cost every iOS 16 user
the feature.

## What is inside

| | |
|---|---|
| `OsIntentsBridge` | routes an invocation from a generated `AppIntent` struct to Dart and decodes the answer |
| `OsIntentsBackgroundEngine` | a second `FlutterEngine` for `Execution.background`, started on demand and torn down after 20 s idle |
| `OsIntentsSnippetView` | renders an `IntentResult.snippet` as SwiftUI, since Siri and Shortcuts cannot host a Flutter view |
| static store | what `Execution.static_` reads, so an intent can answer with no engine at all |

## What is *not* inside

The generated `AppIntent` structs and the `AppShortcutsProvider`. Those go into
your app target, at `ios/Runner/OsIntents/`, written by
[`os_intents_cli`](https://pub.dev/packages/os_intents_cli).

That is measured, not assumed. An intent declared in a plugin module *is*
discoverable — but a published package lives in `~/.pub-cache`, shared between
projects and wiped by `pub cache repair`, so per-project sources could never live
there; and a provider declared in a plugin is dropped in silence, no error and no
warning. Both probes and their numbers are in
[docs/risk1.md](https://github.com/m1roxx/os_intents/blob/main/docs/risk1.md).

## Concurrency

The plugin compiles clean under both Swift 5 and the full Swift 6 language mode,
and a test keeps it that way.

An actor would have been the obvious answer and the wrong one:
`FlutterMethodChannel` has to be used on the main thread, which is what the lock
was really enforcing. Timeouts race their callbacks through `OneShotContinuation`
rather than a task group — a group awaits its children on the way out and a
checked continuation ignores cancellation, so the task-group version hangs the
very path that exists to report the timeout.

Full picture: [os_intents](https://pub.dev/packages/os_intents).
