package com.insideedge.mochi

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Mochi's one Android activity. Besides hosting Flutter, it answers a small channel (`com.insideedge.mochi/platform`):
 * the pairing link the app was opened with (`mochi://pair?…`, from a QR code app, a browser or `adb`), links that
 * arrive while it runs (`link`, sent to Dart), this phone's model for the Mac's device list, and the app's files folder.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** A pairing link not yet handed to Dart: the launch intent's, until Dart asks for it once. */
    private var pendingLink: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLink = pairingLink(intent)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialLink" -> {
                        result.success(pendingLink)
                        pendingLink = null
                    }
                    "deviceName" -> result.success(deviceName())
                    "filesDir" -> result.success(filesDir.absolutePath)
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = pairingLink(intent) ?: return
        val channel = channel
        if (channel == null) {
            pendingLink = link
        } else {
            channel.invokeMethod("link", link)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun pairingLink(intent: Intent?): String? {
        val data = intent?.data ?: return null
        if (intent.action != Intent.ACTION_VIEW || data.scheme != "mochi" || data.host != "pair") return null
        return data.toString()
    }

    /** "realme RMX3242": the maker and model, as the Mac lists this phone. */
    private fun deviceName(): String {
        val maker = Build.MANUFACTURER.orEmpty().trim()
        val model = Build.MODEL.orEmpty().trim()
        return when {
            model.isEmpty() -> maker.ifEmpty { "Android phone" }
            maker.isEmpty() || model.startsWith(maker, ignoreCase = true) -> model
            else -> "$maker $model"
        }
    }

    private companion object {
        const val CHANNEL = "com.insideedge.mochi/platform"
    }
}
