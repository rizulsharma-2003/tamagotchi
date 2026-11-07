// Windows notifications and Mochi's sounds (docs/SPRINT_2.md W1).
//
// Toasts: flutter_local_notifications_windows (C++/WinRT ToastNotificationManager), for an unpackaged app identified by
// the AppUserModelID `InsideEdge.Mochi`: the installed copy's Start-menu shortcut carries it, the runner sets it on the
// process (windows/runner/main.cpp), and the plugin registers it under HKCU\Software\Classes\AppUserModelId with Mochi's
// name, icon and the COM class that hears clicks (the installer registers that class's LocalServer32, so a click in the
// notification centre starts Mochi if it isn't running). Running from where it was downloaded, Mochi has no Start-menu
// entry and doesn't set any of this up: Settings says so and offers to install.
//
// Sounds: the Mac's synthesized tones as a WAV in memory, played with winmm's PlaySound (asynchronous, no default sound
// if it fails), silent when Windows' sound scheme is "No Sounds".

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'package:mochi_wire/mochi_wire.dart' show InstallLayout;
import 'package:win32/win32.dart';

import '../core/sounds.dart';
import '../core/toasts.dart';

/// The COM class Windows calls when one of Mochi's toasts is clicked (registered by the plugin while Mochi runs, and
/// by the installer as Mochi.exe's LocalServer32).
const String toastActivatorGuid = 'd67ae0d6-41e2-4d4b-961e-faec8753952d';

/// HKEY_CURRENT_USER values (DWORDs and strings), or null.
abstract final class UserRegistry {
  static int? dword(String key, String name) => using((arena) {
    final data = arena<Uint32>();
    final size = arena<Uint32>()..value = sizeOf<Uint32>();
    final result = RegGetValue(
      HKEY_CURRENT_USER,
      key.toNativeUtf16(allocator: arena),
      name.toNativeUtf16(allocator: arena),
      RRF_RT_REG_DWORD,
      nullptr,
      data,
      size,
    );
    return result == ERROR_SUCCESS ? data.value : null;
  });

  static String? string(String key, String name) => using((arena) {
    final size = arena<Uint32>()..value = 0;
    final subKey = key.toNativeUtf16(allocator: arena);
    final value = name.toNativeUtf16(allocator: arena);
    if (RegGetValue(HKEY_CURRENT_USER, subKey, value, RRF_RT_REG_SZ, nullptr, nullptr, size) != ERROR_SUCCESS) return null;
    final buffer = arena<Uint8>(size.value + 2);
    if (RegGetValue(HKEY_CURRENT_USER, subKey, value, RRF_RT_REG_SZ, nullptr, buffer, size) != ERROR_SUCCESS) return null;
    return buffer.cast<Utf16>().toDartString();
  });
}

class Win32Toasts implements ToastService {
  Win32Toasts({required bool Function() installed, required String executable}) : _installed = installed, _executable = executable;

  final bool Function() _installed;
  final String _executable;
  FlutterLocalNotificationsWindows? _plugin;
  bool _failed = false;
  ToastAvailability _availability = ToastAvailability.notInstalled;

  static const String _appSettings = r'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\InsideEdge.Mochi';
  static const String _allApps = r'Software\Microsoft\Windows\CurrentVersion\PushNotifications';

  @override
  ToastAvailability get availability => _availability;

  /// Mochi's icon for its notifications: the tray icon that ships in the app's assets.
  String get _icon =>
      [File(_executable).parent.path, 'data', 'flutter_assets', 'assets', 'tray', 'tray_icon.ico'].join(Platform.pathSeparator);

  @override
  Future<void> start(void Function(ToastTarget target) onOpen) async {
    if (!_installed()) {
      refresh();
      return;
    }
    try {
      final plugin = FlutterLocalNotificationsWindows();
      final ready = await plugin.initialize(
        settings: WindowsInitializationSettings(
          appName: 'Mochi',
          appUserModelId: InstallLayout.appUserModelId,
          guid: toastActivatorGuid,
          iconPath: File(_icon).existsSync() ? _icon : null,
        ),
        onDidReceiveNotificationResponse: (response) => onOpen(ToastTarget.parse(response.payload)),
      );
      _plugin = ready ? plugin : null;
      _failed = !ready;
    } on Object catch (error) {
      debugPrint('Mochi: Windows notifications could not be set up (${error.runtimeType})');
      _failed = true;
    }
    refresh();
  }

  @override
  void refresh() {
    if (!_installed()) {
      _availability = ToastAvailability.notInstalled;
    } else if (_failed || _plugin == null) {
      _availability = ToastAvailability.failed;
    } else if (UserRegistry.dword(_allApps, 'ToastEnabled') == 0) {
      _availability = ToastAvailability.offForAll;
    } else if (UserRegistry.dword(_appSettings, 'Enabled') == 0) {
      _availability = ToastAvailability.offForMochi;
    } else {
      _availability = ToastAvailability.ready;
    }
  }

  @override
  Future<bool> show(Toast toast) async {
    final plugin = _plugin;
    if (plugin == null || !_availability.works) return false;
    try {
      await plugin.showRawXml(id: toast.tag, xml: toast.xml());
      return true;
    } on Object catch (error) {
      debugPrint('Mochi: a Windows notification could not be shown (${error.runtimeType})');
      return false;
    }
  }

  @override
  Future<void> openSystemSettings() async {
    try {
      await Process.run('explorer.exe', ['ms-settings:notifications']);
    } on ProcessException {
      // Nothing to open.
    }
  }

  @override
  void dispose() {
    _plugin?.dispose();
    _plugin = null;
  }
}

class Win32SoundOutput implements SoundOutput {
  /// Each WAV handed to PlaySound stays in native memory while Mochi runs: an asynchronous PlaySound reads it as it plays,
  /// and Mochi's sounds are few and small (a set of cues at a handful of volumes).
  final Map<Uint8List, Pointer<Uint8>> _native = Map.identity();

  @override
  bool get supported => true;

  /// "No Sounds" in Windows' Sound settings (the scheme `.None`) keeps Mochi silent too.
  @override
  bool get systemSoundsOn => UserRegistry.string(r'AppEvents\Schemes', '') != '.None';

  @override
  void play(Uint8List wav) {
    final memory = _native.putIfAbsent(wav, () {
      final pointer = calloc<Uint8>(wav.length);
      pointer.asTypedList(wav.length).setAll(0, wav);
      return pointer;
    });
    PlaySound(memory.cast(), 0, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
  }
}
