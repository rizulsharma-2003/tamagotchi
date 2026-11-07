package com.insideedge.mochi

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Hold to talk (the iPhone's PhoneListener): Android's SpeechRecognizer, on the phone itself when it can
 * (`createOnDeviceSpeechRecognizer` on Android 13+, otherwise the phone's recognizer asked to prefer offline). The
 * microphone runs only while you hold Mochi (or until you tap Send), and what's heard streams to Dart as you speak.
 *
 * The channel `com.insideedge.mochi/speech`:
 * - `access` / `requestAccess`: the microphone permission, `granted`, `ask` (not asked yet, or may ask again) or
 *   `blocked` (denied for good: only Android's settings can allow it). The question is asked when you first talk.
 * - `available`: `{available, onDevice}`.
 * - `start`: listens. Recognizers stop at a pause; while you still hold Mochi it listens again and keeps what it heard.
 *   Events to Dart: `heard` (all the words so far), `done` (the words, after `stop`), `error` (the recognizer's code).
 * - `stop`: you let go; the last words come as `done`. `cancel`: nothing is sent. `openSettings`: Mochi's app settings.
 */
class SpeechChannel(private val activity: Activity, messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL).also { it.setMethodCallHandler(this) }
    private val prefs = activity.getSharedPreferences("mochi_speech", Context.MODE_PRIVATE)

    private var recognizer: SpeechRecognizer? = null
    private var onDevice = false

    /** Words from earlier stretches of this hold (the recognizer stopped at a pause and listened again). */
    private var committed = ""
    private var partial = ""

    /** Still held: listen again after a pause. */
    private var wanted = false

    /** Let go: the next result is the last. */
    private var stopping = false
    private var restarts = 0
    private var pendingAccess: MethodChannel.Result? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "access" -> result.success(access())
            "requestAccess" -> requestAccess(result)
            "available" -> result.success(
                mapOf(
                    "available" to SpeechRecognizer.isRecognitionAvailable(activity),
                    "onDevice" to (Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)),
                ),
            )
            "start" -> {
                start()
                result.success(onDevice)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            "cancel" -> {
                cancel()
                result.success(null)
            }
            "openSettings" -> {
                activity.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // MARK: The microphone

    private fun granted() = activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun access(): String = when {
        granted() -> "granted"
        !prefs.getBoolean(ASKED, false) -> "ask"
        activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> "ask"
        else -> "blocked"
    }

    private fun requestAccess(result: MethodChannel.Result) {
        if (granted()) return result.success("granted")
        pendingAccess?.success(access())
        pendingAccess = result
        prefs.edit().putBoolean(ASKED, true).apply()
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), REQUEST_MICROPHONE)
    }

    /** MainActivity hands over the answer to [requestAccess]. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_MICROPHONE) return false
        pendingAccess?.success(access())
        pendingAccess = null
        return true
    }

    // MARK: Listening

    private fun start() {
        cancel()
        committed = ""
        partial = ""
        wanted = true
        stopping = false
        restarts = 0
        begin(preferOnDevice = true)
    }

    private fun begin(preferOnDevice: Boolean) {
        recognizer?.destroy()
        val useOnDevice = preferOnDevice && Build.VERSION.SDK_INT >= 33 && SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
        val made = if (useOnDevice && Build.VERSION.SDK_INT >= 33) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        } else {
            SpeechRecognizer.createSpeechRecognizer(activity)
        }
        onDevice = useOnDevice
        made.setRecognitionListener(listener)
        recognizer = made
        made.startListening(
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, activity.packageName)
                // A pause while you hold Mochi isn't the end (a hint; recognizers may stop sooner, then it listens again).
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 4000L)
                putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS, 4000L)
            },
        )
    }

    private fun stop() {
        wanted = false
        stopping = true
        val listening = recognizer
        if (listening == null) finish() else listening.stopListening()
    }

    fun cancel() {
        wanted = false
        stopping = false
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
    }

    private fun words(): String = listOf(committed, partial).filter { it.isNotBlank() }.joinToString(" ").trim()

    /** The last words of this hold go to Dart, and the recognizer goes. */
    private fun finish() {
        val text = words()
        recognizer?.destroy()
        recognizer = null
        stopping = false
        channel.invokeMethod("done", mapOf("text" to text))
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            channel.invokeMethod("ready", mapOf("onDevice" to onDevice))
        }

        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: return
            if (text.isBlank()) return
            partial = text
            channel.invokeMethod("heard", mapOf("text" to words()))
        }

        override fun onResults(results: Bundle?) {
            val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            committed = listOf(committed, if (text.isNullOrBlank()) partial else text).filter { it.isNotBlank() }.joinToString(" ")
            partial = ""
            if (wanted && restarts < MAX_RESTARTS) {
                // Still held: it stopped at a pause. Listen again, keeping what was said.
                restarts += 1
                channel.invokeMethod("heard", mapOf("text" to words()))
                begin(preferOnDevice = onDevice)
            } else {
                finish()
            }
        }

        override fun onError(error: Int) {
            val nothingYet = committed.isBlank() && partial.isBlank()
            when {
                // The on-device recognizer can't (no language pack yet, busy): the phone's own recognizer, preferring offline.
                onDevice && nothingYet && wanted && error !in listOf(
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS, SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                ) -> begin(preferOnDevice = false)
                // A pause with nothing new: still held, listen again; let go, that's all.
                error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
                    if (wanted && restarts < MAX_RESTARTS) {
                        restarts += 1
                        begin(preferOnDevice = onDevice)
                    } else {
                        finish()
                    }
                stopping -> finish()
                else -> {
                    recognizer?.destroy()
                    recognizer = null
                    wanted = false
                    channel.invokeMethod("error", mapOf("code" to error))
                }
            }
        }
    }

    private companion object {
        const val CHANNEL = "com.insideedge.mochi/speech"
        const val ASKED = "askedMicrophone"
        const val REQUEST_MICROPHONE = 0x4D49
        const val MAX_RESTARTS = 30
    }
}
