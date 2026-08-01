## 0.1.0

First released version. Android implementation of
[os_intents](https://pub.dev/packages/os_intents) — you depend on that package,
and this one resolves with it.

Carries the runtime behind both Android layers: the headless `FlutterEngine` a
generated `@AppFunction` invokes, the routing that turns an app-shortcut launch
into a handler call on the UI isolate, and the `SharedPreferences` store an
`Execution.static_` function answers from without starting an isolate.
