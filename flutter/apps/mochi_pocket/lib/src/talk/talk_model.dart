import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/pocket_model.dart';
import 'speech_listener.dart';

/// Where talking to Mochi is (the iPhone's `TalkModel.Phase`).
enum TalkPhase {
  idle,

  /// Mochi turns its ear towards you.
  approaching,
  listening,
  sending,

  /// Sent; waiting for the computer's answer.
  waiting,
  replied,
  failed;

  /// Talking takes over Mochi's pose in the room.
  bool get overridesPet => this != idle;
}

/// Press and hold Mochi (A3, the iPhone's iOS/MochiPocket/TalkModel.swift): it turns its ear towards you and listens,
/// on the phone; let go and what you said goes to your computer as a spoken command, where Ask Mochi carries it out.
/// The answer comes back here. Every state finds its way back to normal: a tap or Cancel stops it, sliding your finger
/// away cancels, and a computer that doesn't answer times out after [answerTimeout].
///
/// With TalkBack (or for anyone), the Talk button does the same without holding: tap to listen, Send when done.
class TalkModel extends ChangeNotifier {
  TalkModel({required this.model, required this.listener, DateTime Function()? clock, this.haptics = true})
    : _clock = clock ?? DateTime.now {
    model.addListener(_modelChanged);
    _problems = listener.problems.listen(_problem);
  }

  final PocketModel model;
  final SpeechListener listener;
  final DateTime Function() _clock;

  /// Buzz on hold, send and answer (off in tests).
  final bool haptics;

  /// The iPhone's 45 seconds.
  static const Duration answerTimeout = Duration(seconds: 45);

  TalkPhase _phase = TalkPhase.idle;
  DateTime _phaseStart = DateTime.fromMillisecondsSinceEpoch(0);
  String? _bubble;
  String _transcript = '';
  bool _byTap = false;
  bool _cancelArmed = false;
  bool _blocked = false;
  String? _waitingFor;

  /// Moves on with every new start or cancel, so a late result from an older one is dropped.
  int _generation = 0;
  bool _stopping = false;
  bool _askingAccess = false;
  Timer? _settle;
  Timer? _sendingTimer;
  Timer? _timeout;
  Timer? _listening;
  late final StreamSubscription<SpeechProblem> _problems;

  TalkPhase get phase => _phase;

  /// When the phase began (for Mochi's pose).
  DateTime get phaseStart => _phaseStart;

  /// What Mochi says above its head: what it hears, what it sent, the answer.
  String? get bubble => _bubble;
  String get transcript => _transcript;
  bool get isHolding => _phase == TalkPhase.approaching || _phase == TalkPhase.listening;
  bool get isBusy => _phase != TalkPhase.idle;

  /// Listening after a tap on Talk (Send and Cancel buttons) rather than while held.
  bool get byTap => _byTap && isHolding;

  /// Your finger slid away from Mochi: letting go now cancels.
  bool get cancelArmed => _cancelArmed && isHolding;

  /// The microphone is denied for good: the bubble's Settings button opens Mochi's page in Android's settings.
  bool get microphoneBlocked => _blocked && _phase == TalkPhase.failed;

  double get _seconds => _clock().millisecondsSinceEpoch / 1000;

  void _set(TalkPhase phase, {Object? bubble = _keep}) {
    _phase = phase;
    _phaseStart = _clock();
    if (bubble != _keep) _bubble = bubble as String?;
    if (phase != TalkPhase.failed) _blocked = false;
    notifyListeners();
  }

  static const Object _keep = Object();

  // MARK: Talking

  /// Your finger is on Mochi (or you tapped Talk, [byTap]): Mochi turns its ear and listens. The first time, Android
  /// asks for the microphone.
  Future<void> earHeld({bool byTap = false}) async {
    if (isHolding || _stopping || _askingAccess) return;
    _reset();
    final ticket = _generation;
    _transcript = '';
    _byTap = byTap;
    _cancelArmed = false;
    _buzz(HapticFeedback.mediumImpact);
    _set(TalkPhase.approaching, bubble: "I'm listening…");
    var access = await listener.access();
    if (ticket != _generation) return;
    if (access == MicAccess.ask) {
      _askingAccess = true;
      var releasedEarly = false;
      _releasedWhileAsking = () => releasedEarly = true;
      access = await listener.requestAccess();
      _askingAccess = false;
      _releasedWhileAsking = null;
      if (ticket != _generation) return;
      // Your finger left Mochi while Android asked: start again now that Mochi can hear.
      if (access == MicAccess.granted && (releasedEarly || !byTap)) {
        _set(TalkPhase.idle, bubble: 'Thanks! Now press and hold me and talk.');
        _settleAfter(const Duration(seconds: 4));
        return;
      }
    }
    if (access != MicAccess.granted) {
      _fail(
        access == MicAccess.blocked
            ? "I can't hear you: allow the microphone for Mochi in Android's settings."
            : "I can't hear you without the microphone. Hold me again to allow it.",
        blocked: access == MicAccess.blocked,
      );
      return;
    }
    try {
      await listener.start(
        heard: (text) {
          if (!isHolding || ticket != _generation) return;
          _transcript = text;
          _bubble = text;
          notifyListeners();
        },
      );
    } on SpeechProblem catch (problem) {
      listener.cancel();
      if (isHolding && ticket == _generation) _fail(problem.message);
      return;
    }
    if (!isHolding || ticket != _generation) {
      listener.cancel();
      return;
    }
    // Mochi finishes turning its ear (the iPhone's 0.8 s), then listens.
    final turned = _clock().difference(_phaseStart);
    _listening = Timer(Duration(milliseconds: math.max(0, 800 - turned.inMilliseconds)), () {
      if (ticket == _generation && _phase == TalkPhase.approaching) _set(TalkPhase.listening);
    });
  }

  void Function()? _releasedWhileAsking;

  /// The system took the gesture away (a dialog, the notification shade): while Android asks for the microphone that's
  /// your finger leaving; otherwise nothing half-heard is sent.
  void fingerLost() {
    if (_askingAccess) {
      _releasedWhileAsking?.call();
    } else if (isHolding && !_byTap) {
      cancel();
    }
  }

  /// Your finger slid away from Mochi (true) or back (false): letting go away from Mochi cancels.
  void slid({required bool away}) {
    if (!isHolding || _cancelArmed == away) return;
    _cancelArmed = away;
    if (away) _buzz(HapticFeedback.selectionClick);
    notifyListeners();
  }

  /// You let go (or tapped Send): what you said goes to your computer.
  Future<void> earReleased() async {
    if (_askingAccess) {
      _releasedWhileAsking?.call();
      return;
    }
    if (!isHolding) return;
    if (_cancelArmed) {
      cancel();
      return;
    }
    _listening?.cancel();
    final ticket = _generation;
    // Out of listening at once: a tap from here cancels instead of releasing twice.
    _set(TalkPhase.sending, bubble: _transcript.isEmpty ? '…' : '“$_transcript”');
    _stopping = true;
    final heard = await listener.stop() ?? (_transcript.isEmpty ? null : _transcript);
    _stopping = false;
    if (ticket != _generation) return;
    final text = heard?.trim();
    if (text == null || text.length <= 1) {
      _set(TalkPhase.idle, bubble: "I didn't catch that. Hold me and talk.");
      _settleAfter(const Duration(seconds: 3));
      return;
    }
    _buzz(HapticFeedback.lightImpact);
    _send(text);
  }

  void _send(String text) {
    // Unpaired, there's no way to the computer at all: say so now rather than wait for an answer that can't come.
    if (!model.paired) {
      _fail('Pair me with your Mac or PC first: Settings › Mochi Link.');
      return;
    }
    _set(TalkPhase.sending, bubble: '“$text”');
    final id = model.send(text, typed: false);
    if (id == null) {
      _fail("That didn't go. Try again in a moment.");
      return;
    }
    _waitingFor = id;
    final ticket = _generation;
    _sendingTimer = Timer(const Duration(milliseconds: 1100), () {
      if (ticket != _generation || _phase != TalkPhase.sending) return;
      _set(TalkPhase.waiting, bubble: 'Sending to ${model.host.yours}…');
    });
    _timeout = Timer(answerTimeout + const Duration(milliseconds: 1100), () {
      if (ticket != _generation || (_phase != TalkPhase.waiting && _phase != TalkPhase.sending)) return;
      _waitingFor = null;
      _fail("${model.host.yoursCapitalized} didn't answer. Is it awake and online?");
    });
  }

  /// Back to normal right away (a tap on Mochi, Cancel or Stop).
  void cancel() {
    listener.cancel();
    _reset();
    _askingAccess = false;
    _releasedWhileAsking = null;
    _set(TalkPhase.idle, bubble: null);
  }

  /// The app left the screen: an unfinished hold is cancelled (nothing is sent while you can't see it).
  void paused() {
    if (isHolding || _askingAccess) cancel();
  }

  /// Opens Mochi's page in Android's settings (a blocked microphone).
  Future<void> openSettings() => listener.openSettings();

  /// Follows the computer's answers (the iPhone's `linkChanged`).
  void _modelChanged() {
    final waitingFor = _waitingFor;
    if (waitingFor == null) return;
    final exchange = model.exchanges.where((exchange) => exchange.id == waitingFor).firstOrNull;
    if (exchange == null) return;
    switch (exchange.state) {
      case ExchangeState.sending:
        break;
      case ExchangeState.working:
        if (_phase == TalkPhase.waiting || _phase == TalkPhase.sending) {
          _bubble = '${model.host.yoursCapitalized} is on it…';
          notifyListeners();
        }
      case ExchangeState.done || ExchangeState.failed:
        _waitingFor = null;
        _sendingTimer?.cancel();
        _timeout?.cancel();
        final ok = exchange.state == ExchangeState.done;
        _buzz(ok ? HapticFeedback.mediumImpact : HapticFeedback.heavyImpact);
        _set(ok ? TalkPhase.replied : TalkPhase.failed, bubble: exchange.reply ?? (ok ? 'Done!' : "That didn't work."));
        _settleAfter(const Duration(seconds: 8));
    }
  }

  void _problem(SpeechProblem problem) {
    if (isHolding) _fail(problem.message);
  }

  void _fail(String message, {bool blocked = false}) {
    listener.cancel();
    _listening?.cancel();
    _buzz(HapticFeedback.heavyImpact);
    _set(TalkPhase.failed, bubble: message);
    _blocked = blocked;
    notifyListeners();
    _settleAfter(blocked ? const Duration(seconds: 10) : const Duration(seconds: 5));
  }

  void _reset() {
    _generation += 1;
    _settle?.cancel();
    _sendingTimer?.cancel();
    _timeout?.cancel();
    _listening?.cancel();
    _waitingFor = null;
    _byTap = false;
    _cancelArmed = false;
  }

  void _settleAfter(Duration delay) {
    _settle?.cancel();
    _settle = Timer(delay, () {
      if (isHolding || _phase == TalkPhase.sending || _phase == TalkPhase.waiting) return;
      _set(TalkPhase.idle, bubble: null);
    });
  }

  void _buzz(Future<void> Function() feedback) {
    if (haptics) unawaited(feedback());
  }

  /// Seconds since the phase began, for the pose.
  double elapsed() => math.max(0, _seconds - _phaseStart.millisecondsSinceEpoch / 1000);

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    unawaited(_problems.cancel());
    _reset();
    listener.cancel();
    super.dispose();
  }
}
