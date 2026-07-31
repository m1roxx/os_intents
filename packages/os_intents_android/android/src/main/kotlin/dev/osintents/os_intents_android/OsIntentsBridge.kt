package dev.osintents.os_intents_android

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicReference

/** What a Dart handler answered with. */
data class IntentOutcome(
    val kind: String,
    val spoken: String?,
    val snippet: Map<String, Any?>?,
) {
    companion object {
        @Suppress("UNCHECKED_CAST")
        fun fromWire(wire: Map<*, *>): IntentOutcome = IntentOutcome(
            kind = wire["kind"] as? String ?: "done",
            spoken = wire["spoken"] as? String ?: wire["displayed"] as? String,
            snippet = wire["spec"] as? Map<String, Any?>,
        )
    }
}

class OsIntentsException(message: String) : Exception(message)

/**
 * The single point every generated `@AppFunction` calls into.
 *
 * An `AppFunctionService` runs with no Activity and no UI engine, so unlike the
 * iOS side there is no live isolate to reuse — every invocation goes through a
 * headless [FlutterEngine] started here. That mirrors what
 * `OsIntentsBackgroundEngine` does on iOS, minus the routing, because there is
 * never a foreground engine to prefer.
 */
object OsIntentsBridge {

    /** Registers plugins with the headless engine. */
    var pluginRegistrantCallback: ((FlutterEngine) -> Unit)? = null

    /**
     * Dart entrypoint to run, as the raw function name.
     *
     * Set by generated code. Unlike iOS there is no library URI: the Android
     * embedder locates an entrypoint by name within the app's Dart program, and
     * the entrypoint is annotated `@pragma('vm:entry-point')` for exactly that.
     */
    var entrypointName: String = "osIntentsBackgroundEntrypoint"

    /** Dart library holding [entrypointName], as a `package:` URI. */
    var entrypointLibraryUri: String? = null

    /** Ceiling on bringing the isolate up and hearing back from Dart. */
    var startTimeoutMs: Long = 10_000

    /** Ceiling on a single handler. */
    var invokeTimeoutMs: Long = 25_000

    // MARK: - Execution.static_
    //
    // The counterpart of the iOS `UserDefaults` store, and it exists for the
    // same reason: a read-only action should not have to start an isolate to
    // answer. Only the AppFunctions path can collect on that — the shortcuts
    // layer starts an Activity, so the engine is up regardless.

    private const val PREFS = "dev.osintents.static"
    private const val PREFS_KEY = "values"

    /**
     * Stores what static intents should answer with.
     *
     * As JSON in a single entry, rather than one preference per field:
     * SharedPreferences holds primitives, and a result carries a nested snippet
     * spec. iOS had to solve the same problem and flattens into a property
     * list; this is the same trade in the shape Android already understands.
     */
    fun publishStatic(context: Context, values: Map<*, *>) {
        context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(PREFS_KEY, toJson(values).toString())
            .apply()
    }

    /**
     * The whole stored result for [id], or null when nothing was published.
     *
     * Whole results rather than the spoken text alone, so a snippet-bearing
     * intent has its card here too — the same choice as `staticResult` on iOS,
     * and the wire format is shared, so the two must agree.
     */
    fun staticResult(context: Context, id: String): Map<String, Any?>? {
        val raw = context.applicationContext
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(PREFS_KEY, null)
            ?: return null
        return try {
            @Suppress("UNCHECKED_CAST")
            fromJson(JSONObject(raw))[id] as? Map<String, Any?>
        } catch (e: JSONException) {
            // A store written by an older version, or truncated. An action that
            // answers with today's date is better than one that crashes.
            null
        }
    }

    /** Recursively converts a decoded method-channel map into JSON. */
    private fun toJson(value: Any?): Any = when (value) {
        null, JSONObject.NULL -> JSONObject.NULL
        is Map<*, *> -> JSONObject().apply {
            for ((k, v) in value) {
                // Nulls are dropped rather than stored: every reader treats
                // absent and null the same, and iOS drops them too.
                if (k is String && v != null) put(k, toJson(v))
            }
        }
        is List<*> -> JSONArray().apply {
            for (v in value) put(toJson(v))
        }
        else -> value
    }

    /** The inverse, back into the shape the wire format uses. */
    private fun fromJson(json: JSONObject): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>()
        for (key in json.keys()) {
            out[key] = unwrap(json.get(key))
        }
        return out
    }

    private fun unwrap(value: Any?): Any? = when (value) {
        JSONObject.NULL -> null
        is JSONObject -> fromJson(value)
        is JSONArray -> (0 until value.length()).map { unwrap(value.get(it)) }
        else -> value
    }

    private val engineRef = AtomicReference<FlutterEngine?>(null)
    private val channelRef = AtomicReference<MethodChannel?>(null)
    private val readyRef = AtomicReference<CompletableDeferred<Unit>?>(null)

    private const val CHANNEL = "dev.osintents/background"

    /** Runs a handler in the headless isolate. */
    suspend fun invoke(
        context: Context,
        id: String,
        args: Map<String, Any?>,
    ): IntentOutcome {
        val channel = start(context)
        val payload = mapOf(
            "id" to id,
            // Nulls are dropped rather than sent: the Dart side reads absent and
            // null the same way, and StandardMessageCodec is happier without.
            "args" to args.filterValues { it != null },
        )

        val reply = CompletableDeferred<Map<*, *>>()
        withContext(Dispatchers.Main) {
            channel.invokeMethod(
                "invoke",
                payload,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        reply.complete(result as? Map<*, *> ?: mapOf("kind" to "done"))
                    }

                    override fun error(code: String, message: String?, details: Any?) {
                        reply.completeExceptionally(
                            OsIntentsException(message ?: code)
                        )
                    }

                    override fun notImplemented() {
                        reply.completeExceptionally(
                            OsIntentsException(
                                "The Dart side has no handler for \"$id\". Re-run " +
                                    "build_runner so the registry matches the " +
                                    "generated Kotlin."
                            )
                        )
                    }
                },
            )
        }

        val wire = withTimeout(invokeTimeoutMs) { reply.await() }
        if (wire["kind"] == "error") {
            throw OsIntentsException(wire["message"] as? String ?: "unknown")
        }
        return IntentOutcome.fromWire(wire)
    }

    /** Brings the engine up if needed and resolves once Dart has registered. */
    private suspend fun start(context: Context): MethodChannel {
        channelRef.get()?.let { existing ->
            if (readyRef.get()?.isCompleted == true) return existing
        }

        val ready = readyRef.get() ?: CompletableDeferred<Unit>().also { fresh ->
            if (!readyRef.compareAndSet(null, fresh)) {
                return@also
            }
            withContext(Dispatchers.Main) { launchEngine(context.applicationContext) }
        }

        // `run` returning without throwing only means an isolate was spawned; if
        // the entrypoint is missing, Dart never calls back.
        withTimeout(startTimeoutMs) { ready.await() }
        return channelRef.get()
            ?: throw OsIntentsException("The background engine did not come up.")
    }

    private fun launchEngine(context: Context) {
        val loader = FlutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)

        val engine = FlutterEngine(context)

        // Non-null once ensureInitializationComplete has run; were it null the
        // engine could not locate the Dart program at all.
        val bundlePath = loader.findAppBundlePath()!!

        // The three-argument form requires a non-null library URI, and the
        // generated entrypoint is never in main.dart — but keep the two-argument
        // path for a manifest that did not carry one.
        val entrypoint = entrypointLibraryUri?.let { uri ->
            DartExecutor.DartEntrypoint(bundlePath, uri, entrypointName)
        } ?: DartExecutor.DartEntrypoint(bundlePath, entrypointName)
        engine.dartExecutor.executeDartEntrypoint(entrypoint)
        pluginRegistrantCallback?.invoke(engine)

        val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            if (call.method == "ready") {
                readyRef.get()?.complete(Unit)
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        engineRef.set(engine)
        channelRef.set(channel)
    }

    /** Tears the engine down. Call when the service is destroyed. */
    fun shutdown() {
        val engine = engineRef.getAndSet(null)
        channelRef.set(null)
        readyRef.set(null)
        engine?.destroy()
    }
}
