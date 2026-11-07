package com.insideedge.mochi

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Mochi's one Android activity. Besides hosting Flutter, it answers a small channel (`com.insideedge.mochi/platform`):
 * the pairing link the app was opened with (`mochi://pair?…`, from a QR code app, a browser or `adb`), links that
 * arrive while it runs (`link`, sent to Dart), this phone's model for the Mac's device list, the app's files folder,
 * audio focus while Mochi reads aloud (`audioFocusLost` tells Dart when a call or another app takes the audio), and
 * the button of Mochi's ongoing notification that opened the app (`liveAction`: `open`, or `session` for Open the
 * Session). Hold to talk has a channel of its own ([SpeechChannel]).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** A pairing link not yet handed to Dart: the launch intent's, until Dart asks for it once. */
    private var pendingLink: String? = null

    /** The ongoing notification's button that opened the app, until Dart asks for it once. */
    private var pendingLiveAction: String? = null

    private var focusRequest: AudioFocusRequest? = null

    private var speech: SpeechChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLink = pairingLink(intent)
        pendingLiveAction = liveAction(intent)
        speech = SpeechChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialLink" -> {
                        result.success(pendingLink)
                        pendingLink = null
                    }
                    "initialLiveAction" -> {
                        result.success(pendingLiveAction)
                        pendingLiveAction = null
                    }
                    "deviceName" -> result.success(deviceName())
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "requestAudioFocus" -> result.success(requestAudioFocus())
                    "abandonAudioFocus" -> {
                        abandonAudioFocus()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        liveAction(intent)?.let { action ->
            val channel = channel
            if (channel == null) pendingLiveAction = action else channel.invokeMethod("liveAction", action)
        }
        val link = pairingLink(intent) ?: return
        val channel = channel
        if (channel == null) {
            pendingLink = link
        } else {
            channel.invokeMethod("link", link)
        }
    }

    /** Spoken audio, briefly: other sound ducks (or pauses, if it's speech too) until Mochi is done. */
    private fun requestAudioFocus(): Boolean {
        val audio = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        abandonAudioFocus()
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setOnAudioFocusChangeListener { change ->
                // A call, an alarm or another app's audio: Mochi stops rather than talk over it. (Being asked to duck
                // is fine to ignore: speech that dips is hard to follow, and the other sound is brief.)
                if (change == AudioManager.AUDIOFOCUS_LOSS || change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                    channel?.invokeMethod("audioFocusLost", null)
                }
            }
            .build()
        focusRequest = request
        return audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        val request = focusRequest ?: return
        (getSystemService(Context.AUDIO_SERVICE) as AudioManager).abandonAudioFocusRequest(request)
        focusRequest = null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        speech?.onPermissionResult(requestCode)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        speech?.cancel()
        speech = null
        abandonAudioFocus()
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /** `open` or `session`, when Mochi's ongoing notification (plugins/mochi_live_update) opened the app. */
    private fun liveAction(intent: Intent?): String? = intent?.getStringExtra(LIVE_ACTION)

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

        /** `LiveNotification.EXTRA_ACTION` in plugins/mochi_live_update. */
        const val LIVE_ACTION = "com.insideedge.mochi.LIVE_ACTION"
    }
}
