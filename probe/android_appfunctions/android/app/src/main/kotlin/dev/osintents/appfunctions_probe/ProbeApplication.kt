package dev.osintents.appfunctions_probe

import android.app.Application

/**
 * Hands the bridge its configuration before any AppFunction can run.
 *
 * Application.onCreate rather than the Activity: an AppFunctionService can be
 * started with no Activity ever existing.
 */
class ProbeApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        OsIntentsSetup.configure()
    }
}
