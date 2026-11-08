// What the Windows runner (windows/runner/flutter_window.cpp) tells Mochi about the PC over the `mochi/system`
// channel, and the global shortcuts it registers for Mochi:
//
// - `display`: the console display went off (0), on (1) or dimmed (2) (RegisterPowerSettingNotification with
//   GUID_CONSOLE_DISPLAY_STATE);
// - `session`: the session was locked, unlocked or switched (WTSRegisterSessionNotification's WTS_* codes);
// - `power`: the PC is going to sleep or woke (PBT_APMSUSPEND / PBT_APMRESUMEAUTOMATIC);
// - `sessionEnding`: Windows is ending the session (WM_QUERYENDSESSION, WM_ENDSESSION): the nudges put any window back;
// - `hotkey`: one of Mochi's shortcuts was pressed (WM_HOTKEY with its id);
// - `toastActivated`: one of Mochi's Windows notifications was clicked (its `launch` argument; windows/runner/toasts.cpp);
// - `state` (asked): the display and lock state now (the lock from WTSQuerySessionInformation at launch).
//
// And Windows notifications through WinRT's ToastNotificationManager in the runner: `toastStart` (registers Mochi's
// click handler, a COM class), `toastShow` (XML, the AppUserModelID, a tag) and `toastSetting` (whether Windows lets
// Mochi's notifications show).
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

  final StreamController<void> _ending = StreamController.broadcast();

  /// Windows is ending the session (a log off, a shutdown or a restart).
  Stream<void> get sessionEnding => _ending.stream;

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
      case 'sessionEnding':
        _ending.add(null);
      case 'hotkey':
        final id = call.arguments;
        if (id is int) _pressed.add(id);
      case 'toastActivated':
        final argument = call.arguments;
        _toastClicks.add(argument is String ? argument : '');
    }
    return null;
  }

  final StreamController<String> _toastClicks = StreamController.broadcast();

  /// A Mochi notification was clicked: its argument.
  Stream<String> get toastClicks => _toastClicks.stream;

  /// Registers Mochi's click handler, the COM class [clsid] ("{…}").
  Future<bool> startToasts(String clsid) async {
    try {
      return await _channel.invokeMethod<bool>('toastStart', {'clsid': clsid}) ?? false;
    } on Object {
      return false;
    }
  }

  /// Shows a toast; Windows' HRESULT (0: shown).
  Future<int> showToast({required String appId, required String xml, required String tag}) async {
    try {
      return await _channel.invokeMethod<int>('toastShow', {'appId': appId, 'xml': xml, 'tag': tag}) ?? -1;
    } on Object {
      return -1;
    }
  }

  /// Windows' NotificationSetting for [appId] (0 on; 1 off for the app; 2 off for the user; 3 group policy; 4 the
  /// manifest), or -1.
  Future<int> toastSetting(String appId) async {
    try {
      return await _channel.invokeMethod<int>('toastSetting', {'appId': appId}) ?? -1;
    } on Object {
      return -1;
    }
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
