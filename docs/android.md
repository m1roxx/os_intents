# Android — feasibility probe

Same method as Risk #1 on iOS: before writing a Kotlin emitter, find out whether
the toolchain works at all inside a Flutter Android module, and what shape
generated code has to take.

Run: `probe/android_appfunctions` — `flutter build apk --debug`.

## Verdict: it works, and it is expensive

`androidx.appfunctions:1.0.0-alpha10` compiles inside a Flutter Android module,
KSP runs, and the metadata lands in the APK at
`assets/probe_app_function_service.xml` — the direct counterpart of iOS's
`Metadata.appintents`. Measured 2026-07-31.

The generated XML is complete, including the prose:

```xml
<appfunction>
  <id>dev.osintents.appfunctions_probe.BaseProbeAppFunctionService#createTask</id>
  <description>Creates a task.</description>
  <parameters>
    <dataTypeMetadata>
      <dataTypeReference>dev.osintents.appfunctions_probe.CreateTaskParams</dataTypeReference>
    </dataTypeMetadata>
    <name>createTaskParams</name>
    <description>the task to create</description>
  </parameters>
  <response>
    <valueType>
      <dataTypeReference>dev.osintents.appfunctions_probe.ProbeTask</dataTypeReference>
    </valueType>
  </response>
</appfunction>
```

## The cost: a version chain that outruns Flutter

Getting from a stock `flutter create` to a green build took four forced
upgrades, each surfaced only by the failure before it:

| Component | Flutter 3.44.8 templates | AppFunctions alpha10 demands |
|---|---|---|
| `compileSdk` | 36 | **37** (`requires … version 37 or later`) |
| Android Gradle Plugin | 9.0.1 | **9.1.0+** |
| Gradle | 9.1.0 | **9.3.1** (dragged in by AGP 9.1.1) |
| KSP | — | 2.3.10 |

Two extra sharp edges:

- Android 17 introduced **minor API levels**. The platform installs as
  `android-37.1`, not a flat `android-37`, so `compileSdk = 37` alone fails with
  *"Failed to find target with hash string 'android-37'"*. It needs
  `compileSdkMinor` alongside it.
- AGP 9.0.1 calls 36 its maximum recommended compile SDK, so even the working
  configuration wants `android.suppressUnsupportedCompileSdk=37`.

At runtime `AppFunctionService` is `@RequiresApi(36)` — Android 16 — and Google's
own note is that Gemini will not invoke these until the integration leaves a
private early-access programme.

## What this means for os_intents

Shipping AppFunctions support today would force **every consuming app** onto
AGP 9.1.1, Gradle 9.3.1 and `compileSdk 37`, to reach a feature that only runs
on Android 16+ and that nothing invokes yet. That is a bad trade to impose by
default.

So the Android half is two layers, and both now exist:

1. **Default: app shortcuts / capabilities.** Works on the Android versions
   people actually run, is invocable today, and needs none of the above.
   Emitted by `sync` with no flag — see below.
2. **Opt-in: AppFunctions**, behind `--android`, generated only when the project
   already meets the requirements.

## Layer 1: app shortcuts and capabilities

`ShortcutsEmitter` writes two files into the app's own resources:

```
android/app/src/main/res/xml/os_intents_shortcuts.xml
android/app/src/main/res/values/os_intents_strings.xml
```

The second exists because `shortcutShortLabel` refuses a literal — a label has
to be a string resource, so every shortcut drags an entry along with it.

Shapes were measured on a **stock** `flutter create` project before the emitter
was written: the whole file builds there, and both a data URI and a nested
`<extra>` survive into the Intent the system builds. The id rides in the URI:

```xml
<shortcut android:shortcutId="dueToday" …>
  <intent
      android:action="dev.osintents.action.RUN"
      android:targetPackage="…"
      android:targetClass="….MainActivity"
      android:data="osintents://intent/dueToday" />
</shortcut>
```

One element has to reach the launcher activity:

```xml
<meta-data
    android:name="android.app.shortcuts"
    android:resource="@xml/os_intents_shortcuts" />
```

No `intent-filter`: a shortcut names its target component, so filter matching
never runs.

`os_intents install` writes it — the Android half of the same command that
registers the generated Swift with the Xcode target, and the same shape of edit:
the manifest is parsed to find the single MAIN/LAUNCHER activity, the element is
spliced in as text at that activity's own indentation so the diff is five lines,
and the result is parsed again before anything is written. It refuses rather
than guesses when there is no launcher activity, when there are two, or when one
already points `android.app.shortcuts` at a shortcuts file of its own — Android
reads exactly one per activity, so a second would not be merged. Every refusal
names the manual step, and adding the element by hand works identically.

It will not write the element before `res/xml/os_intents_shortcuts.xml` exists:
aapt fails the build outright on a resource that is not there.

### It always opens the app

A `shortcuts.xml` `<intent>` starts an Activity. There is no way to answer one
without a UI, so on this layer `Execution.background` does **not** mean headless
— the plugin routes the launch into the UI isolate and the handler runs there,
seeing the state the user is looking at. Headless execution is the whole reason
the AppFunctions layer, and its version chain, exist at all.

### Two things it will not do

- **A launcher shortcut for an intent with a required parameter.** A tap carries
  no values — there is nowhere in `shortcuts.xml` to put one and nobody to ask —
  so the shortcut would appear and fail on use. `sync` says which intents this
  skipped and why. A capability is exempt: Assistant fills the built-in intent's
  parameters before launching anything.
- **Guess a built-in intent.** `androidCapability` has to be written out
  (`actions.intent.CREATE_TASK`), because Android matches against Google's fixed
  catalogue rather than against the app's own wording. `phrases` cannot be
  translated into one.

## Constraints the Kotlin emitter has to respect

The probe pins down the shape, and it differs from iOS in ways that matter:

- **`@AppFunction` cannot be top-level.** alpha10 requires methods on a class
  annotated `@AppFunctionServiceEntryPoint` extending `AppFunctionService`. So
  where iOS gets one struct per intent, Android gets one service class holding
  every intent as a method — the emitter cannot mirror the iOS structure.
- **Descriptions come from KDoc**, not annotation arguments
  (`isDescribedByKDoc = true`). The emitter must write real KDoc, and inline
  per-property KDoc inside `@AppFunctionSerializable` classes — class-level
  `@param` tags are explicitly not read.
- **Parameters are objects, not loose arguments.** Each function takes a single
  `@AppFunctionSerializable` data class, so the emitter has to synthesise a
  params class per intent.
- The imports are `androidx.appfunctions.*`. `androidx.appfunctions.service.*`
  does not exist — `appfunctions-service` was dropped in alpha10, on 1 July 2026.

## The emitter, and how to switch it on

`KotlinEmitter` implements the above. It is **off by default** — generating it
unconditionally would impose the whole version chain on every consumer for a
feature nothing invokes yet:

```bash
dart run os_intents sync --android
```

Output goes into the app's own package under
`android/app/src/main/kotlin/<applicationId>/`, not a directory of our own,
because `@AppFunctionServiceEntryPoint` produces a service the manifest has to
name and Kotlin's package must match its source path.

Only `Execution.background` and `Execution.static_` intents are exposed. A
foreground intent needs an Activity, which an `AppFunctionService` has none of;
offering one to an agent would produce an action that always fails.

Verified end to end in `probe/android_appfunctions` — Dart annotations through
to metadata in the APK:

```
• …BaseOsIntentsAppFunctionService#addTask
    desc: Creates a new task in the Inbox     ← from the Dart @AppIntent
    param params: the values for this action
• …BaseOsIntentsAppFunctionService#dueToday
    desc: Tasks due today

openInbox (Execution.foreground) — correctly absent
```

### Three things the CLI will not do to your build

1. `compileSdk 37` + `compileSdkMinor`, AGP 9.1.1+, Gradle 9.3.1+, and the KSP
   plugin.
2. The `androidx.appfunctions` dependency and its compiler.
3. `OsIntentsSetup.configure()` from `Application.onCreate`, plus the generated
   service in `AndroidManifest.xml`.

On the third: Flutter's manifest template already carries
`android:name="${applicationName}"`, so the way to install a custom
`Application` is to replace that placeholder — adding a second `android:name`
produces a duplicate attribute and the manifest merger fails with nothing more
useful than a parse error.

## The runtime, verified

`probe/run_android_integration.sh`, on an API 36 emulator:

```
✓ headless_engine — ran in a second isolate, UI list stayed at 0
✓ unknown_intent_fails — reported by the Dart registry
```

The first is the whole Android runtime in one line: `FlutterLoader` initialised,
a second `FlutterEngine` came up, `osIntentsBackgroundEntrypoint` was found by
name in the right library, plugins registered, and the round trip over the
method channel worked. The list staying at 0 is what proves a *second* isolate
did the work — the UI isolate has its own copy and never saw the write.

### Getting an emulator to boot here at all

Four configurations crashed before one worked, and the reason is worth writing
down because it will cost the next person the same hour.

The emulator install has **no `lib64/gles_swiftshader`** — there is no software
GL renderer, only MoltenVK. So every GPU mode on a Google APIs image segfaults
or wedges headless: `swiftshader_indirect` is rejected as invalid and falls back
to `auto`, `-gpu off` still routes through the ranchu graphics HAL and dies the
moment surfaceflinger touches the composer, and windowed mode survives longer
but `adbd` never comes up.

What works is an **AOSP ATD image** — built for headless CI, with the graphics
stack stripped:

```bash
sdkmanager "system-images;android-36;aosp_atd;arm64-v8a"
avdmanager create avd -n os_intents_atd -k "system-images;android-36;aosp_atd;arm64-v8a"
emulator -avd os_intents_atd -no-window -no-audio -no-snapshot -no-boot-anim -gpu off
```

It boots in about 40 seconds. Two consequences for the harness: an ATD image
ships no launcher, so `monkey -c LAUNCHER` exits -5 and the app has to be
started with `am start -n <pkg>/.MainActivity`; and `adb logcat -d` returns
instantly, so a polling loop without a pause finishes long before a second
engine has started.

## Entities: there is nothing to hook into

iOS has `@EntityQuery` — the OS calls back into a running app to turn "Groceries"
into an object, for disambiguation and for filling a parameter in the Shortcuts
editor. The obvious guess is that Android does the same thing through AppSearch,
inverted: the app publishes entities and the system queries the index.

Measured against the artifacts this project already depends on,
`androidx.appfunctions` **1.0.0-alpha10**, by unpacking the AAR and the KSP
compiler and reading the class list — 215 and 190 classes respectively.

**There is no entity concept in the library at all.** Nothing named for
resolution, candidates, lookup or disambiguation exists in either artifact.

AppSearch *is* in the dependency graph, and it is genuinely used — but for the
functions, not for the app's data. The generated `$$__AppSearch__*` document
classes are `AppFunctionMetadataDocument` and its relatives, and
`AppFunctionInventory` reads:

```
Map<String, CompileTimeAppFunctionMetadata> getFunctionIdToMetadataMap()
```

An inventory of what the app can *do*, indexed so the system can find it. Not an
inventory of what the app *has*.

The nearest thing to constraining a parameter is a fixed set, decided at compile
time and read from an annotation:

```kotlin
@AppFunctionStringValueConstraint(enumValues = [...])
@AppFunctionIntValueConstraint(enumValues = [...])
@AppFunctionOneOfType(matchOneOf = [...])
```

Nothing there asks the app anything.

**So the feature cannot be built the way it was imagined.** An app can index its
own entities into AppSearch — it is a general-purpose index — but nothing
connects that to filling an AppFunction parameter. An agent would have to search
AppSearch itself and then pass an identifier, which is exactly what already
happens today: an entity parameter crosses as its identifier and the Dart
handler resolves it.

What the probe *did* find worth building is the value constraint. A Dart enum
parameter maps onto `AppFunctionStringValueConstraint` directly, and onto
`AppEnum` on the iOS side — one feature, both platforms, and the only kind of
parameter narrowing Android actually offers.

Re-check when `androidx.appfunctions` moves; alpha10 is where this was true.

## Still not answered

An agent actually invoking one of these `@AppFunction` methods. Gemini's
integration is in a private EAP, so the path from a real assistant through
`AppFunctionService` into the bridge has never run — only the bridge half has.
