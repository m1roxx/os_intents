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

So the Android half should be two layers:

1. **Default: app shortcuts / capabilities.** Works on the Android versions
   people actually run, is invocable today, and needs none of the above.
2. **Opt-in: AppFunctions**, generated only when the project already meets the
   requirements. `os_intents doctor` should say plainly why it is off rather
   than generating code that will not build.

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

## Not answered

No emulator is configured on this machine, so nothing here has been *run* — only
built and inspected. Whether a background `FlutterEngine` can be started from
inside an `AppFunctionService`, which is the Android counterpart of the headless
work already verified on iOS, remains open.
