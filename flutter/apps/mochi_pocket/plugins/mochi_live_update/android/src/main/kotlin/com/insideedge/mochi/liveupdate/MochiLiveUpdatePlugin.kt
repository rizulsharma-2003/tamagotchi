package com.insideedge.mochi.liveupdate

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The channel `com.insideedge.mochi/live_update`, registered in every Flutter engine of the app: the app's own and
 * the background engine firebase_messaging starts for pushes that arrive while Mochi is closed. Both post the same
 * notification ([LiveNotification]).
 */
class MochiLiveUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val context = context ?: return result.error("detached", "Not attached to the app.", null)
        try {
            when (call.method) {
                "show" -> {
                    @Suppress("UNCHECKED_CAST")
                    val view = call.arguments as? Map<String, Any?> ?: return result.error("bad_arguments", "show takes a map.", null)
                    result.success(LiveNotification.show(context, view))
                }
                "cancel" -> {
                    LiveNotification.cancel(context, (call.argument<Number>("timestamp"))?.toLong(), call.argument<Boolean>("force") == true)
                    result.success(null)
                }
                "isShowing" -> result.success(LiveNotification.isShowing(context))
                "status" -> result.success(LiveNotification.status(context))
                "reset" -> {
                    LiveNotification.reset(context)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            // Never the notification's text: only what kind of failure it was.
            result.error("failed", error.javaClass.simpleName, null)
        }
    }

    private companion object {
        const val CHANNEL = "com.insideedge.mochi/live_update"
    }
}
