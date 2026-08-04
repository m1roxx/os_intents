## 0.2.0

### Dynamic shortcuts

New `DynamicShortcuts`, wrapping `ShortcutManager` behind `pushShortcut`,
`shortcuts`, `removeShortcuts` and `maxShortcuts`.

The Intent each entry carries is the same shape the shortcuts emitter builds —
`dev.osintents.action.RUN` with `osintents://intent/<id>` — so a tap lands in
the routing that already exists rather than in a second path that could drift
from it. Values ride as extras, which is what that routing already reads.

Null below API 25, where `ShortcutManager` does not exist, which surfaces as
"the platform did nothing" — the same answer iOS gives, so one Dart code path
covers everything.

`donate` still returns false. That has not changed and is not a gap: this is
the call it was pointing at.

## 0.1.0

First released version. Android implementation of
[os_intents](https://pub.dev/packages/os_intents) — you depend on that package,
and this one resolves with it.

Carries the runtime behind both Android layers: the headless `FlutterEngine` a
generated `@AppFunction` invokes, the routing that turns an app-shortcut launch
into a handler call on the UI isolate, and the `SharedPreferences` store an
`Execution.static_` function answers from without starting an isolate.
