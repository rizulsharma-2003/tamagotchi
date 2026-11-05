import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'mochi_voice.dart';

/// The phone's text-to-speech, as the reader needs it.
abstract interface class SpeechEngine {
  /// Every voice the engine has (the reader picks English ones).
  Future<List<VoiceInfo>> voices();

  /// Says [text] and completes when it's been heard or [stop] cut it short.
  Future<void> speak(String text, {VoiceInfo? voice, double pitch = 1, double pace = 1});

  Future<void> stop();
}

/// Android's TextToSpeech through flutter_tts. Spoken on the phone unless the chosen voice needs the internet.
class FlutterTtsEngine implements SpeechEngine {
  FlutterTts? _tts;

  Future<FlutterTts> _engine() async {
    final existing = _tts;
    if (existing != null) return existing;
    final tts = FlutterTts();
    // speak() then completes when the utterance is done (or stopped), so sentences go one at a time.
    await tts.awaitSpeakCompletion(true);
    _tts = tts;
    return tts;
  }

  @override
  Future<List<VoiceInfo>> voices() async {
    try {
      final raw = await (await _engine()).getVoices;
      return [
        if (raw is List)
          for (final item in raw) ?VoiceInfo.fromMap(item),
      ];
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Mochi: no voices (${error.runtimeType})');
      return const [];
    }
  }

  @override
  Future<void> speak(String text, {VoiceInfo? voice, double pitch = 1, double pace = 1}) async {
    final tts = await _engine();
    if (voice != null) await tts.setVoice(voice.toMap());
    await tts.setPitch(pitch.clamp(0.5, 2.0));
    // flutter_tts maps Android's normal rate (1.0) to 0.5.
    await tts.setSpeechRate((0.5 * pace).clamp(0.1, 1.0));
    // Audio focus is the reader's (it stops on focus loss); flutter_tts's own request would ignore a loss.
    await tts.speak(text, focus: false);
  }

  @override
  Future<void> stop() async => (await _engine()).stop();
}
