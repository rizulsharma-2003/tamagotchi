// Reacts to what you do (docs/SPRINT_2.md X7, Mischief): Mochi notices three things about your PC and answers them on the
// taskbar, in its own stroll, with nothing new on the desktop, no new sounds and no notifications.
//
// - Music: while media is playing the stroll's free choice gains a bop (ui/pet/stroller.dart).
// - Calls: while the microphone is in use Mochi goes quiet (no zoomies, toys, landmark visits or speech bubbles; its sounds
//   are muted) and is back to normal about [ReactsDirector.calmAfter] after the microphone is free.
// - Editor or terminal: when the app you're using changes to one, Mochi gives one attentive look (at most once every
//   [ReactsDirector.perkEvery]).
//
// What is read, and nothing more: whether media is playing (never what), whether the microphone is in use (never which
// app) and the foreground app's process name (never its window title or contents). Nothing is stored, sent or logged but
// a state word in the stroll's debug log. It reads about every [ReactsDirector.every], and only while the extra is allowed
// by [MischiefGate] (the switches, full screen, quiet hours, focus, paused reactions, an unseen screen). Games and
// full-screen apps are the gate's business (W2): there is no game detection here.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'mischief.dart';

/// Whether media is playing now (the runner's WinRT media session; never what is playing).
abstract interface class MediaReader {
  Future<bool> playing();
}

/// Whether the microphone is in use now (the privacy consent store; never by which app).
abstract interface class MicReader {
  bool inUse();
}

/// The foreground app's process name ("Code.exe"), or null where it can't be read (never its window title or contents).
abstract interface class ForegroundApps {
  String? processName();
}

class NoMedia implements MediaReader {
  const NoMedia();

  @override
  Future<bool> playing() async => false;
}

class NoMic implements MicReader {
  const NoMic();

  @override
  bool inUse() => false;
}

class NoForegroundApp implements ForegroundApps {
  const NoForegroundApp();

  @override
  String? processName() => null;
}

/// One app's microphone use in the consent store: `LastUsedTimeStart` and `LastUsedTimeStop` (FILETIME values; a missing
/// one is null).
@immutable
class MicStamp {
  const MicStamp(this.start, this.stop);

  final int? start;
  final int? stop;

  /// It started and hasn't stopped: Windows writes a stop time of 0 while the microphone is open.
  bool get active => (start ?? 0) > 0 && stop == 0;
}

abstract final class MicConsent {
  /// The consent store's key (under HKEY_CURRENT_USER): each app that asked has a subkey, packaged apps directly and
  /// the others under [nonPackaged].
  static const String key = r'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone';
  static const String nonPackaged = 'NonPackaged';

  /// Any app is using the microphone now.
  static bool inUse(Iterable<MicStamp> stamps) => stamps.any((stamp) => stamp.active);
}

/// The editors and terminals Mochi perks up for (process names, matched without regard to case).
abstract final class EditorApps {
  static const List<String> names = [
    'Code.exe',
    'Code - Insiders.exe',
    'Cursor.exe',
    'devenv.exe',
    'idea64.exe',
    'pycharm64.exe',
    'WindowsTerminal.exe',
    'wt.exe',
    'pwsh.exe',
    'powershell.exe',
    'cmd.exe',
    'alacritty.exe',
    'wezterm-gui.exe',
  ];

  static final Set<String> _lower = {for (final name in names) name.toLowerCase()};

  /// [process] (a bare name, or a path: only its last part counts) is an editor or a terminal.
  static bool matches(String? process) {
    if (process == null) return false;
    final name = process.split(RegExp(r'[\\/]')).last.trim().toLowerCase();
    return _lower.contains(name);
  }
}

/// A development switch, `MOCHI_DESKTOP_REACTS=music|call|editor`, that forces one state (for the VM; the gate still
/// applies).
enum ReactsForce {
  music,
  call,
  editor;

  static ReactsForce? from(String? value) {
    final name = (value ?? '').trim().toLowerCase();
    for (final force in values) {
      if (force.name == name) return force;
    }
    return null;
  }
}

class ReactsDirector extends ChangeNotifier {
  ReactsDirector({
    required this.gate,
    this.media = const NoMedia(),
    this.mic = const NoMic(),
    this.apps = const NoForegroundApp(),
    this.force,
    DateTime Function()? clock,
    this.every = const Duration(seconds: 5),
    this.log,
  }) : _clock = clock ?? DateTime.now;

  final MischiefGate gate;
  final MediaReader media;
  final MicReader mic;
  final ForegroundApps apps;
  final ReactsForce? force;
  final DateTime Function() _clock;

  /// How often the three are read (W30).
  final Duration every;

  /// The stroll's debug log: a state word, nothing else (set by the app when `stroll-debug` is on).
  void Function(String message)? log;

  /// Mochi comes back to normal this long after the microphone was last seen in use.
  static const Duration calmAfter = Duration(seconds: 10);

  /// An editor or terminal comes to the front: at most one look this often.
  static const Duration perkEvery = Duration(minutes: 10);

  Timer? _timer;
  bool _started = false;
  bool _polling = false;
  bool _music = false;
  DateTime? _quietUntil;
  bool _calling = false;
  String? _lastApp;
  bool _baselined = false;
  DateTime? _lastPerk;
  final StreamController<void> _perks = StreamController.broadcast(sync: true);

  /// Polls so far (tests, the perf meter).
  int polls = 0;

  /// Media is playing (and Mochi may bop).
  bool get music => _music;

  /// The microphone is in use, or was a moment ago: Mochi is quiet.
  bool get calling => _calling;

  /// The reads are scheduled (tests: not while the gate is closed).
  bool get reading => _timer != null;

  /// An editor or terminal came to the front and Mochi may look up (once per [perkEvery]).
  Stream<void> get perks => _perks.stream;

  /// What Mochi's reacting to, for the perf meter ("calm, music" in its label): null when nothing.
  String? get label => _calling ? 'call' : (_music ? 'music' : null);

  bool get _allowed => gate.may(MischiefExtra.reacts);

  /// Starts watching the gate.
  void start() {
    if (_started) return;
    _started = true;
    gate.addListener(_sync);
    _sync();
  }

  /// Starts or stops the regular read to match the gate.
  void _sync() {
    if (!_started) return;
    if (_allowed) {
      if (_timer == null) {
        _timer = Timer.periodic(every, (_) => unawaited(poll()));
        unawaited(poll());
      }
    } else {
      _timer?.cancel();
      _timer = null;
      _clear();
    }
  }

  /// Forgets what was seen (the gate closed): nothing is read, Mochi is back to normal.
  void _clear() {
    final was = label;
    _music = false;
    _calling = false;
    _quietUntil = null;
    _lastApp = null;
    _baselined = false;
    if (was != null) {
      log?.call('reacts: none');
      notifyListeners();
    }
  }

  /// Reads the three now, unless the gate is closed (public for the tests).
  Future<void> poll() async {
    if (_polling || !_started) return;
    if (!_allowed) {
      _clear();
      return;
    }
    _polling = true;
    try {
      polls++;
      var playing = force == ReactsForce.music;
      if (!playing) {
        try {
          playing = await media.playing();
        } on Object {
          playing = false;
        }
      }
      // The gate may have closed while the runner answered.
      if (!_started || !_allowed) {
        _clear();
        return;
      }
      final now = _clock();
      var using = force == ReactsForce.call;
      if (!using) {
        try {
          using = mic.inUse();
        } on Object {
          using = false;
        }
      }
      if (using) _quietUntil = now.add(calmAfter);
      final quiet = _quietUntil != null && now.isBefore(_quietUntil!);
      String? app;
      if (force == ReactsForce.editor) {
        app = EditorApps.names.first;
        _baselined = true;
        _lastApp = null;
      } else {
        try {
          app = apps.processName();
        } on Object {
          app = null;
        }
      }
      final key = app?.toLowerCase();
      final changed = _baselined && key != null && key != _lastApp;
      _baselined = true;
      _lastApp = key;
      if (changed && !quiet && EditorApps.matches(app)) {
        final last = _lastPerk;
        if (last == null || now.difference(last) >= perkEvery) {
          _lastPerk = now;
          log?.call('reacts: editor');
          _perks.add(null);
        }
      }
      if (playing != _music || quiet != _calling) {
        _music = playing;
        _calling = quiet;
        log?.call('reacts: ${label ?? 'none'}');
        notifyListeners();
      }
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _started = false;
    gate.removeListener(_sync);
    _timer?.cancel();
    _timer = null;
    unawaited(_perks.close());
    super.dispose();
  }
}
