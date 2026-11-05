import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';

import '../model/app_settings.dart';
import '../services/platform_bridge.dart';
import 'agent_speech.dart';
import 'mochi_voice.dart';
import 'speech_engine.dart';

/// Reads "Waiting for you" out loud in Mochi's voice (iOS/MochiPocket/UpdatesReader.swift): the phone's own
/// text-to-speech with Mochi's character (pitch and pace), a sentence at a time with a short breath between them. A
/// second tap stops it. Like the iPhone, it keeps reading if you switch apps; leaving Updates or Settings stops it.
///
/// It holds audio focus while it talks (other sound ducks) and stops when something else takes the audio. With
/// TalkBack on, TalkBack reads the script itself instead, so two voices never talk over each other.
class UpdatesReader extends ChangeNotifier {
  UpdatesReader({
    required SpeechEngine engine,
    required AudioFocus focus,
    required AppSettings settings,
    String Function()? language,
    void Function(String text)? announce,
  }) : _engine = engine,
       _focus = focus,
       _settings = settings,
       _language = language ?? (() => PlatformDispatcher.instance.locale.toLanguageTag()),
       _announce = announce {
    _focusLost = focus.lost.listen((_) => stop());
  }

  final SpeechEngine _engine;
  final AudioFocus _focus;
  final AppSettings _settings;
  final String Function() _language;
  final void Function(String text)? _announce;
  late final StreamSubscription<void> _focusLost;

  /// The breath between sentences (the iPhone leaves 0.12 s).
  static const Duration pause = Duration(milliseconds: 120);

  bool _speaking = false;

  /// Which reading is current; an older one that's still finishing a sentence stops there.
  int _reading = 0;
  List<VoiceInfo>? _voices;

  bool get speaking => _speaking;

  /// The phone's English voices, best first (cached; [refreshVoices] reloads).
  Future<List<VoiceInfo>> voices() async => VoiceChoice.choices(_voices ??= await _engine.voices(), language: _language());

  Future<List<VoiceInfo>> refreshVoices() {
    _voices = null;
    return voices();
  }

  /// The voice that reads: the one chosen in Settings while it's installed, else the best English one.
  Future<VoiceInfo?> voice({String? chosen}) async =>
      VoiceChoice.pick(_voices ??= await _engine.voices(), chosen: chosen ?? _settings.voiceName, language: _language());

  /// Reads [items] (the card's waiting items), or stops if it's reading. [talkBack]: TalkBack is on.
  Future<void> toggle(List<AgentNote> items, {bool talkBack = false, String Function(DateTime time)? time}) async {
    if (_speaking) return stop();
    return say(AgentSpeech.script(items, time: time), talkBack: talkBack);
  }

  /// Says [text] in Mochi's voice: as set in Settings, or [character] and [voiceName] (a sample of a choice).
  Future<void> say(String text, {VoiceCharacter? character, String? voiceName, bool talkBack = false}) async {
    await stop();
    if (talkBack) {
      _announce?.call(text);
      return;
    }
    final reading = ++_reading;
    _setSpeaking(true);
    try {
      // During a call (or while something else holds the audio) the phone says no: Mochi stays quiet.
      if (!await _focus.request()) return _finish(reading);
      if (reading != _reading) return;
      final mood = character ?? _settings.character;
      final voice = await this.voice(chosen: voiceName);
      for (final (index, sentence) in AgentSpeech.sentences(text).indexed) {
        if (reading != _reading) return;
        if (index > 0) await Future<void>.delayed(pause);
        if (reading != _reading) return;
        await _engine.speak(sentence, voice: voice, pitch: mood.pitch, pace: mood.pace);
      }
    } on Object catch (error) {
      if (kDebugMode) debugPrint('Mochi: reading stopped (${error.runtimeType})');
    }
    await _finish(reading);
  }

  Future<void> stop() async {
    if (!_speaking) return;
    _reading++;
    _setSpeaking(false);
    try {
      await _engine.stop();
    } on Object {
      // Already quiet.
    }
    await _focus.abandon();
  }

  Future<void> _finish(int reading) async {
    if (reading != _reading) return;
    _reading++;
    _setSpeaking(false);
    await _focus.abandon();
  }

  void _setSpeaking(bool speaking) {
    if (_speaking == speaking) return;
    _speaking = speaking;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_focusLost.cancel());
    unawaited(stop());
    super.dispose();
  }
}
