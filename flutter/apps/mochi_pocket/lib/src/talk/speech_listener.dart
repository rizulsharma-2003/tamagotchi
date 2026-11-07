import 'dart:async';

import 'package:flutter/services.dart';

/// The microphone permission, as hold to talk needs to know it.
enum MicAccess {
  granted,

  /// Not asked yet, or Android may ask again.
  ask,

  /// Denied for good: only Mochi's page in Android's settings can allow it.
  blocked,
}

/// Why listening didn't work, in words for Mochi's bubble.
class SpeechProblem implements Exception {
  const SpeechProblem(this.message);

  final String message;

  @override
  String toString() => 'SpeechProblem: $message';
}

/// Hold-to-talk speech recognition (the iPhone's `PhoneListener`): on the phone where it can be, only while you hold
/// Mochi, with the words as they're heard.
abstract interface class SpeechListener {
  Future<MicAccess> access();

  /// Asks for the microphone (Android's question), in context: the first time you talk to Mochi.
  Future<MicAccess> requestAccess();

  /// Starts listening; [heard] gets all the words so far, as they come. Throws [SpeechProblem].
  Future<void> start({required void Function(String text) heard});

  /// You let go: the words, or null when nothing was heard. Never waits more than [stopWait], so Mochi can't get stuck
  /// listening.
  Future<String?> stop();

  /// Nothing is sent; the microphone stops.
  void cancel();

  /// Something went wrong while listening (the network, the microphone): what to say.
  Stream<SpeechProblem> get problems;

  /// Mochi's page in Android's settings, where a blocked microphone can be allowed.
  Future<void> openSettings();
}

/// How long [SpeechListener.stop] waits for the recognizer's last words (the iPhone waits two seconds too).
const Duration stopWait = Duration(seconds: 2);

/// Android's SpeechRecognizer through MainActivity's `com.insideedge.mochi/speech` (SpeechChannel.kt).
class PlatformSpeechListener implements SpeechListener {
  PlatformSpeechListener() {
    _channel.setMethodCallHandler(_received);
  }

  static const MethodChannel _channel = MethodChannel('com.insideedge.mochi/speech');

  void Function(String text)? _heard;
  String _latest = '';
  Completer<String?>? _done;
  final StreamController<SpeechProblem> _problems = StreamController.broadcast();

  Future<void> _received(MethodCall call) async {
    final arguments = call.arguments is Map ? (call.arguments as Map).cast<String, Object?>() : const <String, Object?>{};
    switch (call.method) {
      case 'heard':
        final text = arguments['text'];
        if (text is String && text.isNotEmpty) {
          _latest = text;
          _heard?.call(text);
        }
      case 'done':
        final text = arguments['text'];
        final words = text is String && text.trim().isNotEmpty ? text.trim() : null;
        final done = _done;
        if (done != null && !done.isCompleted) done.complete(words ?? _orNull(_latest));
      case 'error':
        final code = arguments['code'];
        _heard = null;
        final done = _done;
        if (done != null && !done.isCompleted) {
          done.complete(_orNull(_latest));
        } else {
          _problems.add(SpeechProblem(explain(code is int ? code : -1)));
        }
    }
  }

  static String? _orNull(String text) => text.trim().isEmpty ? null : text.trim();

  /// SpeechRecognizer's error codes, in Mochi's words.
  static String explain(int code) => switch (code) {
    9 => "I can't hear you: allow the microphone for Mochi in Android's settings.",
    1 || 2 || 4 || 11 => "I couldn't hear you: your phone's speech recognizer needs the internet right now.",
    3 => "The microphone isn't working right now.",
    8 || 10 => 'Something else is listening. Try again in a moment.',
    12 || 13 => "Speech isn't available in your phone's language yet.",
    _ => "I couldn't listen just now. Try again, or type it.",
  };

  @override
  Future<MicAccess> access() async => _parse(await _invoke<String>('access'));

  @override
  Future<MicAccess> requestAccess() async => _parse(await _invoke<String>('requestAccess'));

  static MicAccess _parse(String? name) => MicAccess.values.where((access) => access.name == name).firstOrNull ?? MicAccess.ask;

  @override
  Future<void> start({required void Function(String text) heard}) async {
    final available = await _channel.invokeMapMethod<String, Object?>('available').catchError((Object _) => null);
    if (available == null || available['available'] != true) {
      throw const SpeechProblem("Talking to Mochi needs a speech recognizer on this phone (Google's speech services).");
    }
    _latest = '';
    _done = null;
    _heard = heard;
    try {
      await _channel.invokeMethod<bool>('start');
    } on PlatformException {
      _heard = null;
      throw const SpeechProblem("I couldn't listen just now. Try again, or type it.");
    }
  }

  @override
  Future<String?> stop() async {
    final done = _done = Completer<String?>();
    await _invoke<void>('stop');
    final words = await done.future.timeout(stopWait, onTimeout: () => _orNull(_latest));
    _heard = null;
    _channel.invokeMethod<void>('cancel').ignore();
    return words;
  }

  @override
  void cancel() {
    _heard = null;
    final done = _done;
    if (done != null && !done.isCompleted) done.complete(null);
    _channel.invokeMethod<void>('cancel').ignore();
  }

  @override
  Stream<SpeechProblem> get problems => _problems.stream;

  @override
  Future<void> openSettings() => _invoke<void>('openSettings');

  static Future<T?> _invoke<T>(String method) async {
    try {
      return await _channel.invokeMethod<T>(method);
    } on MissingPluginException {
      return null;
    }
  }
}
