import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// What the helper needs from the system to install an update or uninstall Mochi: wait for Mochi to quit, start it
/// again, stop the installed copy, and a few registry calls. Windows uses Win32 through dart:ffi; elsewhere (the macOS
/// development build and the tests) there are plain POSIX stand-ins or fakes.
abstract interface class ProcessControl {
  /// Waits until process [pid] has exited, for up to [timeout]. True when it's gone (or never existed).
  bool waitForExit(int pid, Duration timeout);

  /// The full path of [pid]'s executable; null when it isn't running or Windows won't say.
  String? executablePath(int pid);

  /// Ends [pid] at once and waits a moment for it to go. True when it's gone.
  bool terminate(int pid);

  /// Starts [executable] on its own: not a child of the helper, no console window.
  Future<void> launch(String executable, List<String> arguments, {String? workingDirectory});
}

ProcessControl systemProcessControl() => Platform.isWindows ? Win32ProcessControl() : const PosixProcessControl();

/// Windows: OpenProcess, WaitForSingleObject, QueryFullProcessImageNameW, TerminateProcess (kernel32).
class Win32ProcessControl implements ProcessControl {
  static const int _synchronize = 0x00100000;
  static const int _processTerminate = 0x0001;
  static const int _processQueryLimitedInformation = 0x1000;
  static const int _waitObject0 = 0;

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final int Function(int, int, int) _openProcess = _kernel32
      .lookupFunction<IntPtr Function(Uint32, Int32, Uint32), int Function(int, int, int)>('OpenProcess');
  static final int Function(int, int) _waitForSingleObject = _kernel32
      .lookupFunction<Uint32 Function(IntPtr, Uint32), int Function(int, int)>('WaitForSingleObject');
  static final int Function(int) _closeHandle = _kernel32.lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  static final int Function(int, int) _terminateProcess = _kernel32
      .lookupFunction<Int32 Function(IntPtr, Uint32), int Function(int, int)>('TerminateProcess');
  static final int Function(int, int, Pointer<Utf16>, Pointer<Uint32>) _queryFullProcessImageName = _kernel32
      .lookupFunction<Int32 Function(IntPtr, Uint32, Pointer<Utf16>, Pointer<Uint32>), int Function(int, int, Pointer<Utf16>, Pointer<Uint32>)>(
        'QueryFullProcessImageNameW',
      );

  @override
  bool waitForExit(int pid, Duration timeout) {
    final handle = _openProcess(_synchronize, 0, pid);
    // No such process (or one we may not wait on, which isn't Mochi's own): gone, as far as the update is concerned.
    if (handle == 0) return true;
    try {
      return _waitForSingleObject(handle, timeout.inMilliseconds) == _waitObject0;
    } finally {
      _closeHandle(handle);
    }
  }

  @override
  String? executablePath(int pid) {
    final handle = _openProcess(_processQueryLimitedInformation, 0, pid);
    if (handle == 0) return null;
    final buffer = calloc<Uint16>(32768).cast<Utf16>();
    final size = calloc<Uint32>()..value = 32768;
    try {
      if (_queryFullProcessImageName(handle, 0, buffer, size) == 0) return null;
      return buffer.toDartString(length: size.value);
    } finally {
      calloc.free(buffer);
      calloc.free(size);
      _closeHandle(handle);
    }
  }

  @override
  bool terminate(int pid) {
    final handle = _openProcess(_processTerminate | _synchronize, 0, pid);
    if (handle == 0) return true;
    try {
      _terminateProcess(handle, 1);
      return _waitForSingleObject(handle, 5000) == _waitObject0;
    } finally {
      _closeHandle(handle);
    }
  }

  @override
  Future<void> launch(String executable, List<String> arguments, {String? workingDirectory}) async {
    // Detached: DETACHED_PROCESS, so a console program gets no window, and it outlives the helper.
    await Process.start(executable, arguments, workingDirectory: workingDirectory, mode: ProcessStartMode.detached);
  }
}

/// macOS and Linux (the development build): `kill -0` to see whether a process is there, `ps` for its path.
class PosixProcessControl implements ProcessControl {
  const PosixProcessControl();

  bool _running(int pid) {
    try {
      return Process.runSync('/bin/kill', ['-0', '$pid']).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  @override
  bool waitForExit(int pid, Duration timeout) {
    final watch = Stopwatch()..start();
    while (_running(pid)) {
      if (watch.elapsed >= timeout) return false;
      sleep(const Duration(milliseconds: 100));
    }
    return true;
  }

  @override
  String? executablePath(int pid) {
    try {
      final result = Process.runSync('/bin/ps', ['-o', 'comm=', '-p', '$pid']);
      final path = (result.stdout as String).trim();
      return result.exitCode == 0 && path.isNotEmpty ? path : null;
    } on ProcessException {
      return null;
    }
  }

  @override
  bool terminate(int pid) {
    Process.killPid(pid, ProcessSignal.sigkill);
    return waitForExit(pid, const Duration(seconds: 5));
  }

  @override
  Future<void> launch(String executable, List<String> arguments, {String? workingDirectory}) async {
    await Process.start(executable, arguments, workingDirectory: workingDirectory, mode: ProcessStartMode.detached);
  }
}

/// The few HKEY_CURRENT_USER calls the uninstall makes, and deleting the app folder once the helper has quit.
abstract interface class UninstallSystem {
  /// A REG_SZ value, or null.
  String? readString(String key, String name);

  /// Deletes a value; nothing happens when it isn't there.
  void deleteValue(String key, String name);

  /// Deletes a key and everything under it; nothing happens when it isn't there.
  void deleteKey(String key);

  /// Deletes [directory] a few seconds after the helper exits (the helper runs from inside it).
  Future<void> deleteAfterExit(String directory);
}

/// advapi32 through dart:ffi (HKEY_CURRENT_USER only), and a small batch file in %TEMP% for the folder.
class Win32UninstallSystem implements UninstallSystem {
  static const int _hkeyCurrentUser = 0x80000001;
  static const int _rrfRtRegSz = 0x00000002;
  static const int _errorSuccess = 0;

  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');
  static final int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>) _regGetValue =
      _advapi32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>, Uint32, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
        int Function(int, Pointer<Utf16>, Pointer<Utf16>, int, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)
      >('RegGetValueW');
  static final int Function(int, Pointer<Utf16>, Pointer<Utf16>) _regDeleteKeyValue = _advapi32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>), int Function(int, Pointer<Utf16>, Pointer<Utf16>)>(
        'RegDeleteKeyValueW',
      );
  static final int Function(int, Pointer<Utf16>) _regDeleteTree = _advapi32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>), int Function(int, Pointer<Utf16>)>('RegDeleteTreeW');
  static final int Function(int, Pointer<Utf16>) _regDeleteKey = _advapi32
      .lookupFunction<Int32 Function(IntPtr, Pointer<Utf16>), int Function(int, Pointer<Utf16>)>('RegDeleteKeyW');

  @override
  String? readString(String key, String name) => using((arena) {
    final subKey = key.toNativeUtf16(allocator: arena);
    final value = name.toNativeUtf16(allocator: arena);
    final size = arena<Uint32>()..value = 0;
    if (_regGetValue(_hkeyCurrentUser, subKey, value, _rrfRtRegSz, nullptr, nullptr, size) != _errorSuccess) return null;
    final data = arena<Uint8>(size.value + 2);
    if (_regGetValue(_hkeyCurrentUser, subKey, value, _rrfRtRegSz, nullptr, data, size) != _errorSuccess) return null;
    return data.cast<Utf16>().toDartString();
  });

  @override
  void deleteValue(String key, String name) => using((arena) {
    _regDeleteKeyValue(_hkeyCurrentUser, key.toNativeUtf16(allocator: arena), name.toNativeUtf16(allocator: arena));
  });

  @override
  void deleteKey(String key) => using((arena) {
    final subKey = key.toNativeUtf16(allocator: arena);
    _regDeleteTree(_hkeyCurrentUser, subKey);
    _regDeleteKey(_hkeyCurrentUser, subKey);
  });

  @override
  Future<void> deleteAfterExit(String directory) async {
    // cmd.exe can't take a quoted path inside /c's argument from Dart (its quoting differs), so the commands go in a
    // batch file that deletes itself.
    final script = File('${Directory.systemTemp.path}\\mochi-uninstall-${DateTime.now().millisecondsSinceEpoch}.cmd');
    script.writeAsStringSync(
      '@echo off\r\n'
      'ping -n 4 127.0.0.1 >nul\r\n'
      'rmdir /s /q "$directory" >nul 2>nul\r\n'
      '(goto) 2>nul & del "%~f0"\r\n',
    );
    await Process.start('cmd.exe', ['/c', script.path], mode: ProcessStartMode.detached);
  }
}
