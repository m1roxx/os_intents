package dev.osintents.shortcuts_probe

import android.content.pm.ShortcutManager
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity

/**
 * Asks the system what it made of `res/xml/shortcuts.xml`.
 *
 * The documentation for the `<intent>` element inside a shortcut says only that
 * it "must provide a value for android:action" and lists nothing else, so
 * whether a data URI or an `<extra>` survives into the Intent the system builds
 * is genuinely unanswered — and the whole routing design for the app-shortcuts
 * layer depends on it.
 *
 * `ShortcutManager.getManifestShortcuts()` returns the system's own parse, which
 * answers it without a launcher — and the ATD emulator image has no launcher, so
 * tapping a shortcut is not something the harness could do anyway.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        report()
    }

    private fun report() {
        val manager = getSystemService(ShortcutManager::class.java)
        if (manager == null) {
            Log.i(TAG, "no ShortcutManager")
            return
        }

        val shortcuts = manager.manifestShortcuts
        Log.i(TAG, "parsed=${shortcuts.size}")
        for (shortcut in shortcuts) {
            Log.i(
                TAG,
                "shortcut id=${shortcut.id}" +
                    " short=${shortcut.shortLabel}" +
                    " long=${shortcut.longLabel}" +
                    " categories=${shortcut.categories}",
            )
            val intent = shortcut.intent
            if (intent == null) {
                Log.i(TAG, "  intent=<null>")
                continue
            }
            Log.i(
                TAG,
                "  action=${intent.action}" +
                    " data=${intent.data}" +
                    " component=${intent.component?.shortClassName}",
            )
            val extras = intent.extras
            if (extras == null) {
                Log.i(TAG, "  extras=<none>")
            } else {
                for (key in extras.keySet()) {
                    @Suppress("DEPRECATION")
                    Log.i(TAG, "  extra $key=${extras.get(key)}")
                }
            }
        }

        // What actually arrived on this launch. Started with `am start` here,
        // which is the closest the harness can get to a shortcut tap.
        Log.i(
            TAG,
            "launched action=${intent?.action}" +
                " data=${intent?.data}" +
                " extras=${intent?.extras?.keySet()?.joinToString()}",
        )
    }

    private companion object {
        const val TAG = "OS_INTENTS_SHORTCUTS"
    }
}
