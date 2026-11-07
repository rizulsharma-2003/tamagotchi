// What the Windows runner (windows/runner/flutter_window.cpp) tells Mochi about the PC over the `mochi/system`
// channel, and the global shortcuts it registers for Mochi:
//
// - `display`: the console display went off (0), on (1) or dimmed (2) (RegisterPowerSettingNotification with
//   GUID_CONSOLE_DISPLAY_STATE);
// - `session`: the session was locked, unlocked or switched (WTSRegisterSessionNotification's WTS_* codes);
// - `power`: the PC is going to sleep or woke (PBT_APMSUSPEND / PBT_APMRESUMEAUTOMATIC);
// - `hotkey`: one of Mochi's shortcuts was pressed (WM_HOTKEY with its id);
// - `state` (asked): the display and lock state now (the lock from WTSQuerySessionInformation at launch).
//
// The runner registers shortcuts with RegisterHotKey on its own window (`registerHotKey`, `unregisterHotKey`), so Windows
// tells Mochi only when one of its own combinations is pressed.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/hotkeys.dart';

class RunnerSystem implements HotkeyRegistrar {
  RunnerSystem({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('mochi/system') {
    _channel.setMethodCallHandler(_handle);
    unawaited(_readState());
  }

  final MethodChannel _channel;
  final StreamController<int> _pressed = StreamController.broadcast();
  final StreamController<void> _changes = StreamController.broadcast();

  /// The console display: on (true), off (false); null until the runner says.
  bool? displayOn;

  /// The session is locked (or another user is on the console).
  bool locked = false;

  /// The PC is going to sleep (until it wakes).
  bool suspended = false;

  /// The display, the lock or sleep changed.
  Stream<void> get changes => _changes.stream;

  Future<void> _readState() async {
    try {
      final state = await _channel.invokeMapMethod<String, Object?>('state');
      if (state == null) return;
      final display = state['display'];
      if (display is int && display >= 0) displayOn = display != 0;
      final lock = state['locked'];
      if (lock is int && lock >= 0) locked = lock == 1;
      _changes.add(null);
    } on Object catch (error) {
      debugPrint('Mochi: the PC state could not be read (${error.runtimeType})');
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'display':
        final state = call.arguments;
        if (state is int) displayOn = state != 0;
        _changes.add(null);
      case 'session':
        final code = call.arguments;
        if (code is int) {
          // WTS_SESSION_LOCK 7, WTS_SESSION_UNLOCK 8, WTS_CONSOLE_DISCONNECT 2 (another user switched in),
          // WTS_CONSOLE_CONNECT 1 (back).
          if (code == 7 || code == 2) locked = true;
          if (code == 8 || code == 1) locked = false;
        }
        _changes.add(null);
      case 'power':
        suspended = call.arguments == 'suspend';
        _changes.add(null);
      case 'hotkey':
        final id = call.arguments;
        if (id is int) _pressed.add(id);
    }
    return null;
  }

  @override
  bool get supported => true;

  @override
  Stream<int> get pressed => _pressed.stream;

  @override
  Future<bool> register(int id, Hotkey hotkey) async {
    try {
      return await _channel.invokeMethod<bool>('registerHotKey', {'id': id, 'modifiers': hotkey.modifiers, 'key': hotkey.key}) ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<void> unregister(int id) async {
    try {
      await _channel.invokeMethod<void>('unregisterHotKey', {'id': id});
    } on Object {
      // Gone with the window.
    }
  }
}
