package com.insideedge.mochi

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
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
 * where the app should open (`place`): `home`, `sessions` or `updates` from the home-screen widget (`mochi://<place>`)
 * and the buttons of Mochi's ongoing notification (Open, Open the Session); `talk`, `waiting` or `check` from the
 * Quick Settings tile ([TalkTileService]), the app shortcuts and Google Assistant (res/xml/shortcuts.xml). It also asks
 * Android to add the tile to Quick Settings (`addTalkTile`). Hold to talk has a channel of its own ([SpeechChannel]).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    /** A pairing link not yet handed to Dart: the launch intent's, until Dart asks for it once. */
    private var pendingLink: String? = null

    /** Where the app was opened to (see [place]), until Dart asks for it once. */
    private var pendingPlace: String? = null

    /**
     * Dart has asked for the launch's link and place, so it's listening for more. Until then a new intent's link or
     * place waits here: when Android recreates the activity for a widget tap or a shortcut (the app wasn't running),
     * it calls [onNewIntent] before Dart has set up its side of the channel, and a message sent then would be lost.
     */
    private var dartAskedForLink = false
    private var dartAskedForPlace = false

    private var focusRequest: AudioFocusRequest? = null

    private var speech: SpeechChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingLink = pairingLink(intent)
        pendingPlace = place(intent)
        speech = SpeechChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialLink" -> {
                        result.success(pendingLink)
                        pendingLink = null
                        dartAskedForLink = true
                    }
                    "initialPlace" -> {
                        result.success(pendingPlace)
                        pendingPlace = null
                        dartAskedForPlace = true
                    }
                    "deviceName" -> result.success(deviceName())
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "requestAudioFocus" -> result.success(requestAudioFocus())
                    "abandonAudioFocus" -> {
                        abandonAudioFocus()
                        result.success(null)
                    }
                    "talkTile" -> result.success(mapOf("added" to TalkTileService.isAdded(this), "canAsk" to (Build.VERSION.SDK_INT >= 33)))
                    "addTalkTile" -> addTalkTile(result)
                    else -> result.notImplemented()
                }
            }
        }
    }

    /**
     * Mochi's links (`mochi://pair`, `mochi://<place>`) are handled here and in the app, never as Flutter routes:
     * Flutter's own deep linking would push a second home screen for each one. (Flutter reads this from the activity,
     * so the manifest's meta-data says the same on the activity.)
     */
    override fun shouldHandleDeeplinking(): Boolean = false

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        place(intent)?.let { place ->
            val channel = channel
            if (channel == null || !dartAskedForPlace) pendingPlace = place else channel.invokeMethod("place", place)
        }
        val link = pairingLink(intent) ?: return
        val channel = channel
        if (channel == null || !dartAskedForLink) {
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

    /**
     * Where the app was opened to: a `mochi://<place>` link from the widget, the Quick Settings tile, an app shortcut
     * or Google Assistant (explicit intents only: there's no intent filter for them, so a web page can't open one); a
     * feature Assistant names ("open what's waiting in Mochi"); or Mochi's ongoing notification's button
     * (plugins/mochi_live_update: `open` is home, `session` is Claude's sessions). Assistant's own links carry `voice=1`
     * and arrive as `<place>:voice`, so Mochi answers out loud. Not when Android reopens the app from Recents with the
     * intent that first started it: that place was already visited.
     */
    private fun place(intent: Intent?): String? {
        if (intent == null || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return null
        intent.getStringExtra(LIVE_ACTION)?.let { return if (it == "session") "sessions" else "home" }
        if (intent.action != Intent.ACTION_VIEW) return null
        val data = intent.data
        if (data == null) return intent.getStringExtra("feature")?.let(::feature)
        if (data.scheme != "mochi") return null
        val place = data.host?.takeIf { it in PLACES } ?: return null
        return if (data.getQueryParameter("voice") == "1") "$place:voice" else place
    }

    /** A feature Assistant matched to none of the shortcuts' names, by its words. */
    private fun feature(words: String): String {
        val text = words.lowercase()
        return when {
            "talk" in text || "speak" in text || "voice" in text -> "talk"
            "wait" in text || "pending" in text || "new" in text -> "waiting"
            "check" in text || "refresh" in text -> "check"
            "update" in text || "history" in text -> "updates"
            "session" in text || "claude" in text -> "sessions"
            else -> "home"
        }
    }

    /** Android 13+: Android asks whether to add "Talk to Mochi" to Quick Settings. Answers how it went. */
    private fun addTalkTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < 33) return result.success("unsupported")
        val statusBar = getSystemService(StatusBarManager::class.java) ?: return result.success("unsupported")
        try {
            statusBar.requestAddTileService(
                ComponentName(this, TalkTileService::class.java),
                getString(R.string.mochi_tile_talk),
                Icon.createWithResource(this, R.drawable.ic_stat_mochi),
                mainExecutor,
            ) { code ->
                val answer = when (code) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "added"
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "already"
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "declined"
                    else -> "unavailable"
                }
                if (code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED ||
                    code == StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED
                ) {
                    getSharedPreferences(TalkTileService.PREFS, Context.MODE_PRIVATE).edit().putBoolean(TalkTileService.ADDED, true).apply()
                }
                result.success(answer)
            }
        } catch (error: Exception) {
            result.success("unavailable")
        }
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

        /** `LiveNotification.EXTRA_ACTION` in plugins/mochi_live_update. */
        const val LIVE_ACTION = "com.insideedge.mochi.LIVE_ACTION"

        /** The places `mochi://<place>` can open (the app's `AppPlace`). */
        val PLACES = setOf("home", "sessions", "updates", "talk", "waiting", "check")
    }
}
