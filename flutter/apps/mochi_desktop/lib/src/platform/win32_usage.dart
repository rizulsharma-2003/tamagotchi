// How this PC is being used, for Mochi's naps (docs/SPRINT_2.md W2; the Mac's MacUsageMonitor), read through dart:ffi:
//
// - the time since the last input: GetLastInputInfo against GetTickCount (only the time; what was typed or clicked is
//   never seen);
// - processor load: GetSystemTimes between samples, smoothed over about a minute (as on the Mac);
// - something keeping the screen on: a display power request (CallNtPowerInformation's SystemExecutionState has
//   ES_DISPLAY_REQUIRED while a video, a call or a presentation app holds one), or a full-screen app, game or
//   presentation (SHQueryUserNotificationState);
// - nobody here: the display off, the session locked or switched, or the PC going to sleep (the runner's
//   notifications, runner_system.dart), or the screen saver (SHQueryUserNotificationState's QUNS_NOT_PRESENT).

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../core/pc_rhythm.dart';
import 'runner_system.dart';

typedef _QueryNotificationStateNative = Int32 Function(Pointer<Int32> state);
typedef _QueryNotificationState = int Function(Pointer<Int32> state);

class Win32Usage implements UsageSampler {
  Win32Usage(this.system);

  final RunnerSystem system;
  double _load = 0;
  (int, int)? _previous;

  static const int _systemExecutionState = 16;
  static const int _esDisplayRequired = 0x00000002;
  static const int _qunsNotPresent = 1;
  static const Set<int> _qunsHeld = {2, 3, 4, 7}; // busy, Direct3D full screen, presentation mode, a full-screen app

  static final _QueryNotificationState _queryNotificationState = DynamicLibrary.open('shell32.dll')
      .lookupFunction<_QueryNotificationStateNative, _QueryNotificationState>('SHQueryUserNotificationState');

  @override
  bool get supported => true;

  @override
  Stream<void> get changes => system.changes;

  @override
  SystemActivity? sample() {
    final idle = idleSeconds();
    if (idle == null) return null;
    final instant = _cpu();
    if (instant != null) _load += (instant - _load) * 0.08;
    final state = notificationState();
    return SystemActivity(
      idleSeconds: idle,
      displaysAsleep: system.displayOn == false || system.locked || system.suspended || state == _qunsNotPresent,
      keepsDisplayAwake: displayRequired() || _qunsHeld.contains(state),
      cpuLoad: _load,
    );
  }

  /// Seconds since the last input in this session.
  static double? idleSeconds() {
    final info = calloc<LASTINPUTINFO>()..ref.cbSize = sizeOf<LASTINPUTINFO>();
    try {
      if (GetLastInputInfo(info) == 0) return null;
      return ((GetTickCount() - info.ref.dwTime) & 0xFFFFFFFF) / 1000;
    } finally {
      calloc.free(info);
    }
  }

  /// Whole-PC processor load since the last call (null the first time).
  double? _cpu() {
    final idle = calloc<FILETIME>(), kernel = calloc<FILETIME>(), user = calloc<FILETIME>();
    try {
      if (GetSystemTimes(idle, kernel, user) == 0) return null;
      int ticks(Pointer<FILETIME> time) => (time.ref.dwHighDateTime << 32) | time.ref.dwLowDateTime;
      // Kernel time includes the idle time.
      final total = ticks(kernel) + ticks(user);
      final busy = total - ticks(idle);
      final previous = _previous;
      _previous = (busy, total);
      if (previous == null || total <= previous.$2 || busy < previous.$1) return null;
      return (busy - previous.$1) / (total - previous.$2);
    } finally {
      calloc
        ..free(idle)
        ..free(kernel)
        ..free(user);
    }
  }

  /// An app asked Windows to keep the display on (a video, a call, a presentation).
  static bool displayRequired() {
    final state = calloc<Uint32>();
    try {
      if (CallNtPowerInformation(_systemExecutionState, nullptr, 0, state, sizeOf<Uint32>()) != 0) return false;
      return state.value & _esDisplayRequired != 0;
    } on Object {
      return false;
    } finally {
      calloc.free(state);
    }
  }

  /// A full-screen app, a game (Direct3D full screen) or a presentation has the screen (SHQueryUserNotificationState's
  /// busy, Direct3D full-screen and presentation states, as the taskbar pet keeps out of the way for): Mischief keeps
  /// still meanwhile.
  static bool fullScreenBusy() => const {2, 3, 4}.contains(notificationState());

  /// SHQueryUserNotificationState's answer (0 if it can't be read).
  static int notificationState() {
    final state = calloc<Int32>();
    try {
      if (_queryNotificationState(state) != S_OK) return 0;
      return state.value;
    } on Object {
      return 0;
    } finally {
      calloc.free(state);
    }
  }

  @override
  void dispose() {}
}
