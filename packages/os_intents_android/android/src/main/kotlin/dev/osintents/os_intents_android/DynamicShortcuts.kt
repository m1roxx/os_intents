package dev.osintents.os_intents_android

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.util.Log

/**
 * Launcher shortcuts the app publishes while it is running.
 *
 * The Android half of "this just happened, offer it back later". Deliberately
 * not routed through `donate`: a donation is a hint to a ranking model that iOS
 * may act on, and this is an entry on the launcher that the app owns outright.
 *
 * The Intent each one carries is the same shape a generated app shortcut
 * builds — `dev.osintents.action.RUN` with `osintents://intent/<id>` — so a tap
 * lands in [OsIntentsAndroidPlugin.route] and reaches the handler through the
 * one path, rather than through a second one that could drift from it.
 *
 * Values ride as extras, which is what the routing already reads. Only
 * primitives: anything else would be a Parcelable a generated handler has no
 * parameter for, and the method channel could not have carried it here anyway.
 */
class DynamicShortcuts private constructor(
    private val context: Context,
    private val manager: ShortcutManager,
) {

    companion object {
        private const val TAG = "os_intents"

        /** Null below API 25, where `ShortcutManager` does not exist. */
        fun of(context: Context): DynamicShortcuts? {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N_MR1) return null
            val manager = context.getSystemService(ShortcutManager::class.java)
                ?: return null
            return DynamicShortcuts(context, manager)
        }
    }

    @SuppressLint("NewApi")
    fun max(): Int = manager.maxShortcutCountPerActivity

    @SuppressLint("NewApi")
    fun ids(): List<String> =
        manager.dynamicShortcuts.sortedBy { it.rank }.map { it.id }

    /** Null removes them all, which is what a sign-out wants. */
    @SuppressLint("NewApi")
    fun remove(ids: List<String>?) {
        if (ids == null) {
            manager.removeAllDynamicShortcuts()
        } else {
            manager.removeDynamicShortcuts(ids)
        }
    }

    /**
     * Publishes one, replacing any entry with the same id.
     *
     * On API 30+ this is `pushDynamicShortcut`, which drops the lowest-ranked
     * entry when the app is at its cap — the platform's own policy, and the
     * reason this API exists. Below 30 there is no such call, so a push that
     * would exceed the cap answers false rather than picking one of the app's
     * own shortcuts to throw away. Which one to lose is the app's decision, and
     * `maxShortcuts` is there so it can make it.
     */
    @SuppressLint("NewApi")
    fun push(spec: Map<*, *>): Boolean {
        val info = build(spec) ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                manager.pushDynamicShortcut(info)
            } else {
                val existing = manager.dynamicShortcuts
                if (existing.none { it.id == info.id } &&
                    existing.size >= manager.maxShortcutCountPerActivity
                ) {
                    Log.w(
                        TAG,
                        "Not pushing \"${info.id}\": the app already has " +
                            "${existing.size} dynamic shortcuts and this " +
                            "device caps it there. Remove one first — which " +
                            "one is your call.",
                    )
                    return false
                }
                manager.addDynamicShortcuts(listOf(info))
            }
            true
        } catch (e: IllegalArgumentException) {
            // Thrown for a label the system will not take, or a cap this
            // missed. Reported rather than crashing the app over a launcher
            // entry it can live without.
            Log.w(TAG, "Shortcut \"${info.id}\" was refused: ${e.message}")
            false
        } catch (e: IllegalStateException) {
            // "The caller is in background" — pushing needs a foreground
            // process on some versions.
            Log.w(TAG, "Shortcut \"${info.id}\" was refused: ${e.message}")
            false
        }
    }

    @SuppressLint("NewApi")
    private fun build(spec: Map<*, *>): ShortcutInfo? {
        val id = spec["id"] as? String ?: return null
        val intentId = spec["intentId"] as? String ?: return null
        val shortLabel = spec["shortLabel"] as? String ?: return null

        val launcher = launcherComponent() ?: run {
            Log.w(TAG, "No launcher activity found, so \"$id\" has nothing to open.")
            return null
        }

        val intent = Intent(ACTION_RUN)
            .setComponent(launcher)
            .setData(Uri.parse("$SCHEME://intent/$intentId"))
        for ((key, value) in (spec["args"] as? Map<*, *> ?: emptyMap<Any, Any>())) {
            val name = key as? String ?: continue
            when (value) {
                is String -> intent.putExtra(name, value)
                is Int -> intent.putExtra(name, value)
                is Long -> intent.putExtra(name, value)
                is Double -> intent.putExtra(name, value)
                is Boolean -> intent.putExtra(name, value)
                else -> Unit
            }
        }

        val builder = ShortcutInfo.Builder(context, id)
            .setShortLabel(shortLabel)
            .setLongLabel((spec["longLabel"] as? String) ?: shortLabel)
            .setRank((spec["rank"] as? Number)?.toInt() ?: 0)
            .setIntent(intent)

        icon(spec["iconResource"] as? String)?.let(builder::setIcon)
        return builder.build()
    }

    /**
     * The activity a shortcut opens.
     *
     * Looked up rather than assumed: `ShortcutInfo` needs an explicit
     * component, and the launcher activity's class name is the app's to choose.
     */
    private fun launcherComponent() =
        context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?.component

    /**
     * A drawable or mipmap the app ships, by name.
     *
     * Resolved through the resource table rather than taken as an id, because
     * an id is a build-time constant of the *app* and Dart has no way to name
     * one. An unknown name loses the icon and keeps the shortcut.
     */
    private fun icon(name: String?): Icon? {
        if (name.isNullOrEmpty()) return null
        val cleaned = name.removePrefix("@")
        val (type, entry) = when {
            cleaned.contains('/') -> cleaned.substringBefore('/') to
                cleaned.substringAfter('/')
            else -> "drawable" to cleaned
        }
        val id = context.resources.getIdentifier(entry, type, context.packageName)
        if (id == 0) {
            Log.w(TAG, "No $type resource called \"$entry\"; the shortcut keeps the app icon.")
            return null
        }
        return Icon.createWithResource(context, id)
    }
}

private const val ACTION_RUN = "dev.osintents.action.RUN"
private const val SCHEME = "osintents"
