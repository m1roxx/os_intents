package dev.osintents.os_intents_android

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Present so the Flutter tooling has a plugin class to register.
 *
 * The real work happens in [OsIntentsBridge], which generated `@AppFunction`
 * methods call directly. Nothing here needs a channel: the background isolate
 * creates its own, and there is no foreground path on Android.
 */
class OsIntentsAndroidPlugin : FlutterPlugin {
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {}

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {}
}
