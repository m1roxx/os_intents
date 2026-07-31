package dev.osintents.os_intents_android

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Carries the development hooks.
 *
 * Generated `@AppFunction` methods call [OsIntentsBridge] directly and never
 * come through here; the channel exists so a test can reach the headless path
 * without an on-device agent, which nothing else can arrange.
 */
class OsIntentsAndroidPlugin : FlutterPlugin {
    private var channel: MethodChannel? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, "dev.osintents/debug").also {
            it.setMethodCallHandler(::handle)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        this.binding = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
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

            else -> result.notImplemented()
        }
    }
}
