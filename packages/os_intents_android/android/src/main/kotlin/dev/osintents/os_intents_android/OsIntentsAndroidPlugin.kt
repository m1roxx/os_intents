package dev.osintents.os_intents_android

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Routes an app-shortcut launch into the Dart handler, and carries the
 * development hooks.
 *
 * Generated `@AppFunction` methods call [OsIntentsBridge] directly and never
 * come through here — that path has no Activity at all. This is the other
 * Android path, and the one most apps will actually use: a shortcut or an
 * Assistant capability starts the launcher Activity with
 * `dev.osintents.action.RUN` and `osintents://intent/<id>`, and the handler runs
 * on the UI isolate the user is already looking at.
 *
 * Unavoidably foreground. A `shortcuts.xml` `<intent>` starts an Activity;
 * Android has no way to answer one without a UI, which is exactly what the
 * AppFunctions layer exists for.
 */
class OsIntentsAndroidPlugin :
    FlutterPlugin,
    ActivityAware,
    PluginRegistry.NewIntentListener {

    private var channel: MethodChannel? = null
    private var debug: MethodChannel? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var activityBinding: ActivityPluginBinding? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** Set once the Dart side has announced its handlers registered. */
    private var isReady = false

    /**
     * An invocation that arrived before Dart was listening.
     *
     * A shortcut tap can be a cold start: the Activity exists long before the
     * isolate has run `OsIntents.install`. Dropping it would make exactly the
     * first tap — the one after install, the one a user tries first — the one
     * that silently does nothing.
     */
    private var pending: Invocation? = null

    /**
     * Last id actually handed to Dart.
     *
     * Read by the harness: the emulator image that boots here ships no launcher,
     * so a shortcut cannot be tapped and the only way to check the routing is to
     * start the Activity with the same Intent and ask what arrived.
     */
    private var lastRouted: String? = null

    private data class Invocation(val id: String, val args: Map<String, Any?>)

    // MARK: - Engine

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::handleFromDart)
        }
        debug = MethodChannel(binding.binaryMessenger, DEBUG_CHANNEL).also {
            it.setMethodCallHandler(::handleDebug)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        debug?.setMethodCallHandler(null)
        channel = null
        debug = null
        isReady = false
        this.binding = null
    }

    // MARK: - Activity

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        route(binding.activity.intent)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }

    /** A second tap while the app is already up. */
    override fun onNewIntent(intent: Intent): Boolean = route(intent)

    // MARK: - Routing

    /**
     * Runs the intent a shortcut launched, if this is one.
     *
     * Returns whether it was consumed. The Activity is also started plainly from
     * the launcher, and every other launch has to fall through untouched.
     */
    private fun route(intent: Intent?): Boolean {
        if (intent == null || intent.action != ACTION_RUN) return false
        val data = intent.data ?: return false
        if (data.scheme != SCHEME) return false
        val id = data.lastPathSegment
        if (id.isNullOrEmpty()) return false

        // Clear the intent so a configuration change — a rotation, a theme
        // switch — does not re-run the action on the way back.
        (activityBinding?.activity as? Activity)?.intent = Intent(Intent.ACTION_MAIN)

        deliver(Invocation(id, argsFrom(intent)))
        return true
    }

    /**
     * Extras a capability filled in.
     *
     * Assistant supplies built-in intent parameters as extras keyed by the
     * `android:key` from `shortcuts.xml`. Only primitives are carried across:
     * anything else would be a Parcelable the method channel cannot encode, and
     * a generated handler has no parameter that could receive one.
     */
    private fun argsFrom(intent: Intent): Map<String, Any?> {
        val extras = intent.extras ?: return emptyMap()
        val out = mutableMapOf<String, Any?>()
        for (key in extras.keySet()) {
            @Suppress("DEPRECATION")
            when (val value = extras.get(key)) {
                is String, is Int, is Long, is Double, is Float, is Boolean ->
                    out[key] = value
                else -> Unit
            }
        }
        return out
    }

    private fun deliver(invocation: Invocation) {
        if (!isReady) {
            pending = invocation
            return
        }
        val channel = channel ?: return
        lastRouted = invocation.id
        channel.invokeMethod(
            "invoke",
            mapOf("id" to invocation.id, "args" to invocation.args),
        )
    }

    // MARK: - Dart calls

    private fun handleFromDart(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ready" -> {
                isReady = true
                pending?.let { buffered ->
                    pending = null
                    deliver(buffered)
                }
                result.success(null)
            }

            "publishStatic" -> {
                val context = binding?.applicationContext
                if (context == null) {
                    result.error("no_context", "Plugin is not attached.", null)
                    return
                }
                OsIntentsBridge.publishStatic(
                    context,
                    call.arguments as? Map<*, *> ?: emptyMap<String, Any?>(),
                )
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun handleDebug(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "debugInvokeBackground" -> {
                val context = binding?.applicationContext
                if (context == null) {
                    result.error("no_context", "Plugin is not attached.", null)
                    return
                }
                val id = call.argument<String>("id").orEmpty()
                val args = call.argument<Map<String, Any?>>("args") ?: emptyMap()
                scope.launch {
                    try {
                        val outcome = OsIntentsBridge.invoke(context, id, args)
                        result.success(
                            mapOf("kind" to outcome.kind, "spoken" to outcome.spoken)
                        )
                    } catch (e: Exception) {
                        result.error(
                            "background_failed",
                            e.message ?: e.toString(),
                            null,
                        )
                    }
                }
            }

            // Reports what the last shortcut launch delivered, so the harness can
            // check the routing without a launcher to tap — the emulator image
            // that boots here has none.
            "debugLastShortcut" -> result.success(lastRouted)

            // Reads back exactly what a generated Execution.static_ function
            // would see, which is the only way to check that publishStatic and
            // the native read side agree on the format.
            "debugStaticValue" -> {
                val context = binding?.applicationContext
                if (context == null) {
                    result.error("no_context", "Plugin is not attached.", null)
                    return
                }
                val id = call.argument<String>("id").orEmpty()
                val stored = OsIntentsBridge.staticResult(context, id)
                result.success(stored?.get("spoken") as? String)
            }

            else -> result.notImplemented()
        }
    }

    private companion object {
        const val CHANNEL = "dev.osintents/background"
        const val DEBUG_CHANNEL = "dev.osintents/debug"

        /** Must match `androidShortcutAction` in the emitter. */
        const val ACTION_RUN = "dev.osintents.action.RUN"
        const val SCHEME = "osintents"
    }
}
