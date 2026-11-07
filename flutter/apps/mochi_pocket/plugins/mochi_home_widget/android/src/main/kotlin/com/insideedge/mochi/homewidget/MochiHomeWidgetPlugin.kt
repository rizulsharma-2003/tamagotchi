package com.insideedge.mochi.homewidget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * The channel `com.insideedge.mochi/home_widget`, registered in every Flutter engine of the app: the app's own and
 * the background engine firebase_messaging starts for pushes that arrive while Mochi is closed.
 *
 * - `update(view)`: keeps what the widget shows (a JSON object the app builds, `HomeWidgetView` in mochi_pocket) in
 *   the app's preferences and asks this app's widget providers to redraw. The providers (in the app) read it back.
 * - `pin()`: asks the launcher to add the widget to the home screen (Android shows its own question).
 * - `status()`: how many are on the home screen, and whether the launcher can be asked to add one.
 */
class MochiHomeWidgetPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
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
                "update" -> {
                    @Suppress("UNCHECKED_CAST")
                    val view = call.arguments as? Map<String, Any?> ?: return result.error("bad_arguments", "update takes a map.", null)
                    save(context, JSONObject(view).toString())
                    result.success(redraw(context))
                }
                "pin" -> result.success(pin(context))
                "status" -> result.success(status(context))
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            // Never what the widget says: only what kind of failure it was.
            result.error("failed", error.javaClass.simpleName, null)
        }
    }

    companion object {
        private const val CHANNEL = "com.insideedge.mochi/home_widget"

        /** The app's widget provider reads the same preferences (`WidgetView.load` in the app). */
        const val PREFS = "mochi_home_widget"
        const val VIEW = "view"

        fun save(context: Context, json: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(VIEW, json).apply()
        }

        /** This app's widget providers (found through Android, so the plugin needn't know the app's classes). */
        private fun providers(context: Context): List<ComponentName> {
            val manager = AppWidgetManager.getInstance(context) ?: return emptyList()
            return manager.getInstalledProvidersForPackage(context.packageName, null).map { it.provider }
        }

        /** Asks each provider to redraw every widget it has on the home screen. The number of widgets. */
        fun redraw(context: Context): Int {
            val manager = AppWidgetManager.getInstance(context) ?: return 0
            var count = 0
            for (provider in providers(context)) {
                val ids = manager.getAppWidgetIds(provider)
                if (ids.isEmpty()) continue
                count += ids.size
                context.sendBroadcast(
                    Intent(AppWidgetManager.ACTION_APPWIDGET_UPDATE)
                        .setComponent(provider)
                        .putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids),
                )
            }
            return count
        }

        private fun pin(context: Context): Boolean {
            val manager = AppWidgetManager.getInstance(context) ?: return false
            if (!manager.isRequestPinAppWidgetSupported) return false
            val provider = providers(context).firstOrNull() ?: return false
            return manager.requestPinAppWidget(provider, null, null)
        }

        private fun status(context: Context): Map<String, Any?> {
            val manager = AppWidgetManager.getInstance(context)
            val placed = providers(context).sumOf { manager?.getAppWidgetIds(it)?.size ?: 0 }
            return mapOf("placed" to placed, "canPin" to (manager?.isRequestPinAppWidgetSupported == true))
        }
    }
}
