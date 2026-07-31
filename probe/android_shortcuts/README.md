# Android app shortcuts — probe

What may a generated `res/xml/shortcuts.xml` contain, and what does Android
build out of it? Same method as Risk #1 and the AppFunctions probe: find out
before writing an emitter, because the documentation does not say.

The `<intent>` element's reference text is one sentence — it "must provide a
value for the `android:action` attribute" — and lists nothing else. Whether a
data URI or an `<extra>` survives is exactly what the routing design depends on,
so it was measured rather than assumed. Measured 2026-07-31, API 36 AOSP ATD.

## Method

A hand-written `shortcuts.xml` on a **stock** `flutter create` project — no
`compileSdk 37`, no AGP 9.1.1, none of the AppFunctions version chain — and a
`MainActivity` that asks `ShortcutManager.getManifestShortcuts()` what the system
made of it.

The system's own parse, rather than a launcher tap: this emulator image ships no
launcher, so tapping a shortcut is not something the harness can do at all.

## Verdict

| Question | Answer |
|---|---|
| Does the whole file build on stock Flutter settings? | **Yes** — shortcuts, `<capability>` and `<capability-binding>` all compile with no version chain |
| Does `android:data` survive into the Intent? | **Yes** — `data=osintents://intent/addTask` |
| Does a nested `<extra>` survive? | **Yes** — `extra osIntentsId=addTask` |
| Can each shortcut carry its own action instead? | **Yes** — `action=dev.osintents.action.RUN.dueToday` |
| Is an `<intent-filter>` needed for the action? | **No** — a shortcut names its target component explicitly, so filter matching never runs |
| Must labels be string resources? | **Yes**, per the docs — so the emitter has to write a `values` file too |

```
parsed=2
shortcut id=addTask short=Add task long=Add a task to the inbox
  action=dev.osintents.action.RUN data=osintents://intent/addTask component=.MainActivity
  extra osIntentsId=addTask
shortcut id=dueToday short=Due today long=Tasks due today
  action=dev.osintents.action.RUN.dueToday data=null component=.MainActivity
launched action=dev.osintents.action.RUN data=osintents://intent/addTask
```

## What this settles for the emitter

- **The id travels in a data URI.** Both a URI and an extra work, so the choice
  is on other grounds: one action shared by every shortcut keeps the manifest to
  a single line, and a URI is legible in `adb` output when something goes wrong.
- **The manual step is one `<meta-data>` element** on the launcher activity, not
  a manifest full of filters:

  ```xml
  <meta-data
      android:name="android.app.shortcuts"
      android:resource="@xml/os_intents_shortcuts" />
  ```

- **This layer costs nothing.** It is why it can be the default while
  AppFunctions stays behind `--android`: the whole version chain in
  [../../docs/android.md](../../docs/android.md) buys headless execution, and
  none of it is needed here.

## What it does not settle

An actual shortcut tap, and an actual Assistant invocation of the capability.
The first needs a launcher, which this image has not got; the second needs
Assistant to match a built-in intent against an installed app, which no harness
here can arrange. What is proven is that the system parses the file into exactly
the Intent the runtime expects, and that the Activity receives it.
