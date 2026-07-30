package dev.osintents.appfunctions_probe

import androidx.annotation.RequiresApi
import androidx.appfunctions.AppFunction
import androidx.appfunctions.AppFunctionSerializable
import androidx.appfunctions.AppFunctionService
import androidx.appfunctions.AppFunctionServiceEntryPoint

// ─────────────────────────────────────────────────────────────────────────────
// ANDROID FEASIBILITY PROBE — mirrors what Risk #1 did for iOS.
//
// Questions, in order of how much they would cost to get wrong:
//
//   1. Does androidx.appfunctions 1.0.0-alpha10 + KSP even run inside a Flutter
//      Android module? Flutter's Gradle plugin, AGP 9 and KSP have to agree.
//   2. Does the compiler emit the metadata XML the platform reads, the way
//      Extract App Intents Metadata does on iOS?
//   3. What shape must generated Kotlin take? Unlike iOS, @AppFunction cannot
//      be a top-level function — alpha10 requires methods on a class annotated
//      @AppFunctionServiceEntryPoint. That decides the whole Kotlin emitter.
//
// Nothing here is shipped; it exists to answer those three before any emitter
// is written.
// ─────────────────────────────────────────────────────────────────────────────

/** The parameter to create a task. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class CreateTaskParams(
    /** The title of the task. */
    val title: String,
)

/** A created task. */
@AppFunctionSerializable(isDescribedByKDoc = true)
data class ProbeTask(
    /** The title of the task. */
    val title: String,
)

/**
 * Hosts the app's functions.
 *
 * KSP generates the concrete `ProbeAppFunctionService` from this, plus the XML
 * named below.
 */
@RequiresApi(36)
@AppFunctionServiceEntryPoint(
    serviceName = "ProbeAppFunctionService",
    appFunctionXmlFileName = "probe_app_function_service",
)
abstract class BaseProbeAppFunctionService : AppFunctionService() {

    /**
     * Creates a task.
     *
     * @param createTaskParams the task to create
     */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun createTask(createTaskParams: CreateTaskParams): ProbeTask {
        // A real implementation would hand this to a background FlutterEngine,
        // the same way the iOS side does. The probe only needs it to compile
        // and to be described in the generated metadata.
        return ProbeTask(title = createTaskParams.title)
    }
}
