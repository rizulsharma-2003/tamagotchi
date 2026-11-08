// What "Reacts to what you do" (docs/SPRINT_2.md X7, core/reacts.dart) reads from Windows, and no more:
//
// - Media: the runner's `isMediaPlaying` on the `mochi/system` channel (windows/runner/media.cpp: WinRT's
//   GlobalSystemMediaTransportControlsSessionManager, only whether the current session's status is Playing; never a title
//   or an artist).
// - The microphone: the privacy consent store in HKEY_CURRENT_USER (an app with a start time and a stop time of 0 is using
//   it now); only a bool leaves the reader, never which app.
// - The foreground app: GetForegroundWindow, GetWindowThreadProcessId, OpenProcess (limited query) and
//   QueryFullProcessImageName, reduced to the file name ("Code.exe"); never a window title or contents. Mochi's own
//   windows read as null. The same read of any window's handle ([windowProcessName]) serves X2's terminal tug.
//
// The macOS development build has none; tests use fakes.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import '../core/reacts.dart';

/// Asks the runner whether media is playing.
class RunnerMedia implements MediaReader {
  RunnerMedia({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('mochi/system');

  final MethodChannel _channel;

  @override
  Future<bool> playing() async {
    try {
      return await _channel.invokeMethod<bool>('isMediaPlaying') ?? false;
    } on Object {
      return false;
    }
  }
}

/// The microphone consent store through the registry.
class Win32Mic implements MicReader {
  /// A sanity cap on the apps looked at under each key.
  static const int most = 200;

  @override
  bool inUse() {
    try {
      final stamps = <MicStamp>[];
      _collect(MicConsent.key, stamps, skip: MicConsent.nonPackaged);
      _collect('${MicConsent.key}\\${MicConsent.nonPackaged}', stamps);
      return MicConsent.inUse(stamps);
    } on Object {
      return false;
    }
  }

  void _collect(String path, List<MicStamp> into, {String? skip}) {
    final key = calloc<IntPtr>();
    final name = calloc<Uint16>(512);
    final size = calloc<Uint32>();
    try {
      final subKey = path.toNativeUtf16();
      final opened = RegOpenKeyEx(HKEY_CURRENT_USER, subKey, 0, KEY_READ, key);
      calloc.free(subKey);
      if (opened != ERROR_SUCCESS) return;
      try {
        for (var index = 0; index < most; index++) {
          size.value = 512;
          if (RegEnumKeyEx(key.value, index, name.cast<Utf16>(), size, nullptr, nullptr, nullptr, nullptr) != ERROR_SUCCESS) break;
          final app = name.cast<Utf16>().toDartString(length: size.value);
          if (app == skip) continue;
          into.add(MicStamp(_qword('$path\\$app', 'LastUsedTimeStart'), _qword('$path\\$app', 'LastUsedTimeStop')));
        }
      } finally {
        RegCloseKey(key.value);
      }
    } finally {
      calloc.free(key);
      calloc.free(name);
      calloc.free(size);
    }
  }

  /// A QWORD value under HKEY_CURRENT_USER, or null.
  static int? _qword(String path, String value) {
    final subKey = path.toNativeUtf16();
    final valueName = value.toNativeUtf16();
    final data = calloc<Uint64>();
    final size = calloc<Uint32>()..value = 8;
    try {
      if (RegGetValue(HKEY_CURRENT_USER, subKey, valueName, RRF_RT_REG_QWORD, nullptr, data.cast(), size) != ERROR_SUCCESS) return null;
      return data.value;
    } finally {
      calloc.free(subKey);
      calloc.free(valueName);
      calloc.free(data);
      calloc.free(size);
    }
  }
}

/// The foreground app's process name.
class Win32ForegroundApp implements ForegroundApps {
  @override
  String? processName() {
    try {
      final window = GetForegroundWindow();
      return window == 0 ? null : windowProcessName(window);
    } on Object {
      return null;
    }
  }
}

/// The file name of the program that owns [window] ("Code.exe"), or null for one of Mochi's own windows or when Windows won't
/// say. Never a title or contents (X7 reads it for the foreground window, X2 for the windows it may nudge).
String? windowProcessName(int window) {
  final pid = calloc<Uint32>();
  final path = calloc<Uint16>(1024);
  final size = calloc<Uint32>();
  var process = 0;
  try {
    if (window == 0) return null;
    GetWindowThreadProcessId(window, pid);
    if (pid.value == 0 || pid.value == GetCurrentProcessId()) return null;
    process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid.value);
    if (process == 0) return null;
    size.value = 1024;
    if (QueryFullProcessImageName(process, 0, path.cast<Utf16>(), size) == 0) return null;
    final full = path.cast<Utf16>().toDartString(length: size.value);
    return full.split(RegExp(r'[\\/]')).last;
  } on Object {
    return null;
  } finally {
    if (process != 0) CloseHandle(process);
    calloc.free(pid);
    calloc.free(path);
    calloc.free(size);
  }
}

MediaReader systemMedia() => Platform.isWindows ? RunnerMedia() : const NoMedia();

MicReader systemMic() => Platform.isWindows ? Win32Mic() : const NoMic();

ForegroundApps systemForegroundApp() => Platform.isWindows ? Win32ForegroundApp() : const NoForegroundApp();
