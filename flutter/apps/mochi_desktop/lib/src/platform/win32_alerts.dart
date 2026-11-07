// Windows notifications and Mochi's sounds (docs/SPRINT_2.md W1).
//
// Toasts: WinRT's ToastNotificationManager, called by the runner through WRL (windows/runner/toasts.cpp; no plugin, no
// ATL), for an unpackaged app identified by the AppUserModelID `InsideEdge.Mochi`: the installed copy's Start-menu
// shortcut carries it, the runner sets it on the process (windows/runner/main.cpp), and Mochi registers it under
// HKCU\Software\Classes\AppUserModelId with its name, icon and the COM class that hears clicks (CustomActivator; the
// runner registers the class while Mochi runs, and the installer registers Mochi.exe as its LocalServer32, so a click in
// the notification centre starts Mochi if it isn't running). Running from where it was downloaded, Mochi has no
// Start-menu entry and sets none of this up: Settings says so and offers to install.
//
// Sounds: the Mac's synthesized tones as a WAV in memory, played with winmm's PlaySound (asynchronous, no default sound
// if it fails), silent when Windows' sound scheme is "No Sounds".

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:mochi_wire/mochi_wire.dart' show InstallLayout;
import 'package:win32/win32.dart';

import '../core/sounds.dart';
import '../core/toasts.dart';
import 'runner_system.dart';

typedef _GetAppIdNative = Int32 Function(Pointer<Pointer<Utf16>> id);
typedef _GetAppId = int Function(Pointer<Pointer<Utf16>> id);

/// The AppUserModelID this process runs as (the runner sets it before any window), for Settings › Developer; null if
/// none was set or it can't be read.
String? processAppUserModelId() {
  try {
    final get = DynamicLibrary.open('shell32.dll').lookupFunction<_GetAppIdNative, _GetAppId>('GetCurrentProcessExplicitAppUserModelID');
    final id = calloc<Pointer<Utf16>>();
    try {
      if (get(id) != S_OK || id.value == nullptr) return null;
      final text = id.value.toDartString();
      CoTaskMemFree(id.value.cast());
      return text;
    } finally {
      calloc.free(id);
    }
  } on Object {
    return null;
  }
}

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

  /// Writes REG_SZ values under [key] (made if needed); false if Windows refused.
  static bool writeStrings(String key, Map<String, String> values) => using((arena) {
    final subKey = key.toNativeUtf16(allocator: arena);
    for (final MapEntry(key: name, :value) in values.entries) {
      final result = RegSetKeyValue(
        HKEY_CURRENT_USER,
        subKey,
        name.toNativeUtf16(allocator: arena),
        REG_SZ,
        value.toNativeUtf16(allocator: arena),
        (value.length + 1) * 2,
      );
      if (result != ERROR_SUCCESS) return false;
    }
    return true;
  });
}

class Win32Toasts implements ToastService {
  Win32Toasts({required this.system, required bool Function() installed, required String executable})
    : _installed = installed,
      _executable = executable;

  final RunnerSystem system;
  final bool Function() _installed;
  final String _executable;
  bool _started = false;
  bool _failed = false;
  ToastAvailability _availability = ToastAvailability.notInstalled;
  StreamSubscription<String>? _clicks;

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
      await refresh();
      return;
    }
    _clicks ??= system.toastClicks.listen((argument) => onOpen(ToastTarget.parse(argument)));
    // Windows' record of Mochi's identity: its name and icon on each notification, and the class that hears clicks.
    final registered = UserRegistry.writeStrings(InstallLayout.appUserModelIdKey, {
      'DisplayName': InstallLayout.displayName,
      if (File(_icon).existsSync()) 'IconUri': _icon,
      'CustomActivator': InstallLayout.toastActivatorClsid,
    });
    _started = registered && await system.startToasts(InstallLayout.toastActivatorClsid);
    _failed = !_started;
    if (_failed) debugPrint('Mochi: Windows notifications could not be set up');
    await refresh();
  }

  @override
  Future<void> refresh() async {
    if (!_installed()) {
      _availability = ToastAvailability.notInstalled;
      return;
    }
    if (_failed || !_started) {
      _availability = ToastAvailability.failed;
      return;
    }
    // Windows' own answer (NotificationSetting), else what its Settings keep in the registry.
    _availability = switch (await system.toastSetting(InstallLayout.appUserModelId)) {
      0 => ToastAvailability.ready,
      1 => ToastAvailability.offForMochi,
      2 || 3 => ToastAvailability.offForAll,
      4 => ToastAvailability.failed,
      _ =>
        UserRegistry.dword(_allApps, 'ToastEnabled') == 0
            ? ToastAvailability.offForAll
            : UserRegistry.dword(_appSettings, 'Enabled') == 0
            ? ToastAvailability.offForMochi
            : ToastAvailability.ready,
    };
  }

  @override
  Future<bool> show(Toast toast) async {
    if (!_started || !_availability.works) return false;
    final result = await system.showToast(appId: InstallLayout.appUserModelId, xml: toast.xml(), tag: '${toast.tag}');
    if (result != 0) debugPrint('Mochi: a Windows notification could not be shown (0x${(result & 0xFFFFFFFF).toRadixString(16)})');
    return result == 0;
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
    unawaited(_clicks?.cancel());
    _clicks = null;
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
