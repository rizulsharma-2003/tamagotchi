// The focus buddy on this PC (Sprint 2 W15), as the Mac's FocusController (Sources/App/Features/Focus) runs it: a
// Pomodoro timer; Mochi naps while you focus (so does the taskbar's Mochi), wakes you for a stretch at the break,
// stretches and gets playful, and is back to napping for the next block. While a focus block runs only the sounds for
// what needs you still play (Reactions asks [focusing]). mochi_world's `FocusBuddy` keeps the phases (checked against
// the Mac's fixture) and says what to show at each one; this keeps it going, keeps the completed blocks for the daily
// recap in `focus-log.json` in Mochi's folder (a week, as the Mac keeps them) and the settings under the Mac's key,
// `focus`.
//
// It moves on once a second while a session runs and the screen can be seen. While it can't be seen, nothing runs but
// one timer for the end of the phase (so the break still comes on time); when a phase ended more than ten minutes
// before it was noticed (the PC was asleep), the session ends quietly and the block isn't counted, as on the Mac.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'desktop_settings.dart';
import 'desktop_world.dart';
import 'json_store.dart';
import 'pc_rhythm.dart';

class DesktopFocus extends ChangeNotifier {
  DesktopFocus({required this.settings, required this.world, required this.rhythm, JsonStore? store, this.retentionDays = 7})
    : store = store ?? MemoryJsonStore() {
    log = w.FocusLog(retentionDays: retentionDays)..load(this.store.read(), now: world.world.date);
    buddy = w.FocusBuddy(world.world, settings: settings.focus, log: log, computer: 'PC');
    _settings = settings.focus;
    settings.addListener(_settingsChanged);
    rhythm.addListener(_schedule);
  }

  final DesktopSettings settings;
  final DesktopWorld world;
  final PcRhythm rhythm;

  /// Where the completed blocks are kept (`focus-log.json`).
  final JsonStore store;

  /// Days of focus blocks kept (the Mac's history retention, a week).
  final int retentionDays;

  /// Completed focus blocks, for the daily recap.
  late final w.FocusLog log;

  late final w.FocusBuddy buddy;

  late w.FocusSettings _settings;

  /// A focus session is running (a focus block or a break).
  bool get running => buddy.isRunning;

  /// The phase now, with its start and length (null with no session).
  w.FocusStatus? get status => world.world.focus;

  /// A focus block (not a break) is running: only the sounds for what needs you play.
  bool get focusing => status?.phase == w.FocusPhase.focus;

  /// Blocks before the long break.
  int get cycles => buddy.timer.durations.cyclesBeforeLongBreak;

  /// For a menu item: "Start Focus" or "Stop Focus (Break 4:12 left)".
  String get menuTitle => buddy.menuTitle;

  /// Starts a focus session, or stops the running one.
  void toggle() => _act(buddy.toggle);

  /// Starts a session ([durations]: seconds instead of the settings' minutes, for a quick look).
  void begin({w.FocusDurations? durations}) => _act(() => buddy.begin(durations: durations));

  void stop() => _act(buddy.stop);

  /// Ends the current phase now (a skipped focus block isn't counted).
  void skip() => _act(buddy.skip);

  /// Moves on (once a second, and at the end of a phase nobody could see).
  void tick() => _act(buddy.tick);

  ({bool running, w.FocusPhase? phase, int? cycle})? _shown;

  void _act(void Function() action) {
    if (_disposed) return;
    final logged = log.blocks.length;
    action();
    world.noteChanged();
    if (log.blocks.length != logged && log.persists) store.write(log.toJson());
    _schedule();
    final shown = (running: running, phase: status?.phase, cycle: status?.cycle);
    if (shown != _shown) {
      _shown = shown;
      notifyListeners();
    }
  }

  void _settingsChanged() {
    final next = settings.focus;
    if (next == _settings) return;
    _settings = next;
    // Naps and sounds at once; the lengths from the next session on.
    buddy.settings = next;
    world.noteChanged();
  }

  Timer? _timer;
  Object? _scheduled;

  /// Once a second while a session runs and the screen can be seen; one wake at the phase's end while it can't; nothing
  /// with no session.
  void _schedule() {
    if (_disposed) return;
    final unseen = rhythm.unseen;
    final ends = buddy.timer.running?.endsAt;
    final plan = !running ? null : (unseen ? ends : 'every second');
    if (plan == _scheduled) return;
    _scheduled = plan;
    _timer?.cancel();
    _timer = null;
    if (plan == null) return;
    if (!unseen) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
    } else if (ends != null) {
      final wait = ends.difference(world.world.date) + const Duration(milliseconds: 200);
      _timer = Timer(wait.isNegative ? Duration.zero : wait, () {
        _scheduled = null;
        tick();
      });
    }
  }

  /// A timer is running (tests: nothing ticks without a session, or while the screen can't be seen).
  bool get ticking => _timer?.isActive ?? false;

  /// Ticks every second (rather than one wake at the phase's end).
  bool get everySecond => _scheduled == 'every second';

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    settings.removeListener(_settingsChanged);
    rhythm.removeListener(_schedule);
    super.dispose();
  }
}
