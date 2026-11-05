// "Start Mochi with Windows" (Settings › General): a `Mochi` value under the signed-in user's Run key,
// HKCU\Software\Microsoft\Windows\CurrentVersion\Run, holding the quoted path of Mochi's exe. Task Manager's Startup apps
// can switch it off without deleting it (a flag under Explorer\StartupApproved\Run); switching it on here clears that
// flag. No admin rights, nothing outside this user. The registry sits behind [StartupRegistry], so the rules are tested
// anywhere with a fake; on the macOS development build there's no startup item ([UnsupportedStartup]).

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Whether Mochi starts when you sign in, and anything worth saying about it.
class StartupStatus {
  const StartupStatus({required this.enabled, this.note});

  final bool enabled;

  /// Why it isn't what it seems ("Turned off in Task Manager…"), if so.
  final String? note;

  @override
  bool operator ==(Object other) => other is StartupStatus && other.enabled == enabled && other.note == note;

  @override
  int get hashCode => Object.hash(enabled, note);

  @override
  String toString() => 'StartupStatus(${enabled ? 'on' : 'off'}${note == null ? '' : ', $note'})';
}

abstract interface class StartupItem {
  /// This system can start Mochi when you sign in (Windows).
  bool get supported;

  /// Read from the system each time (Task Manager may have changed it).
  StartupStatus status();

  /// Turns it on or off. Returns what went wrong, in words, or null.
  String? setEnabled(bool enabled);
}

/// The few registry calls the startup item needs, under HKEY_CURRENT_USER.
abstract interface class StartupRegistry {
  /// A REG_SZ value (null when it isn't there).
  String? readString(String key, String name);

  /// A REG_BINARY value (null when it isn't there).
  List<int>? readBinary(String key, String name);

  /// Writes a REG_SZ value, making the key if needed. Throws [StartupException] when Windows refuses.
  void writeString(String key, String name, String value);

  /// Deletes a value; nothing happens when it isn't there. Throws [StartupException] when Windows refuses.
  void delete(String key, String name);
}

class StartupException implements Exception {
  const StartupException(this.message);

  final String message;

  @override
  String toString() => 'StartupException: $message';
}

/// The Run-key startup item.
class RunKeyStartup implements StartupItem {
  RunKeyStartup({required this.registry, required this.executable});

  /// On this PC: the real registry and this exe.
  factory RunKeyStartup.system() => RunKeyStartup(registry: Win32StartupRegistry(), executable: Platform.resolvedExecutable);

  static const String runKey = r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const String approvedKey = r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  static const String valueName = 'Mochi';

  final StartupRegistry registry;

  /// Mochi's exe.
  final String executable;

  /// What Windows runs at sign-in: the exe, quoted (its folder may have spaces).
  String get command => '"$executable"';

  @override
  bool get supported => true;

  @override
  StartupStatus status() {
    final String? value;
    final List<int>? approved;
    try {
      value = registry.readString(runKey, valueName);
      approved = registry.readBinary(approvedKey, valueName);
    } on Object {
      return const StartupStatus(enabled: false, note: "Windows didn't say whether Mochi starts when you sign in.");
    }
    if (value == null) return const StartupStatus(enabled: false);
    // Task Manager › Startup apps keeps the entry and marks it off: an odd first byte.
    if (approved != null && approved.isNotEmpty && approved.first.isOdd) {
      return const StartupStatus(
        enabled: false,
        note: 'Turned off in Task Manager › Startup apps. Switching it on here turns it back on.',
      );
    }
    final target = _path(value);
    if (target.toLowerCase() != executable.toLowerCase()) {
      return StartupStatus(enabled: true, note: 'Starts the copy of Mochi at $target. Switch it off and on to start this one.');
    }
    return const StartupStatus(enabled: true);
  }

  @override
  String? setEnabled(bool enabled) {
    try {
      if (enabled) {
        registry.writeString(runKey, valueName, command);
      } else {
        registry.delete(runKey, valueName);
      }
      // Either way, Task Manager's "off" mark goes: on means on.
      registry.delete(approvedKey, valueName);
      return null;
    } on StartupException catch (error) {
      return error.message;
    } on Object catch (error) {
      return "Windows didn't let Mochi change its startup setting (${error.runtimeType}).";
    }
  }

  /// The exe in a Run value: the quoted part, or everything before the first argument.
  static String _path(String value) {
    final text = value.trim();
    if (text.startsWith('"')) {
      final end = text.indexOf('"', 1);
      return end > 0 ? text.substring(1, end) : text.substring(1);
    }
    final space = text.toLowerCase().indexOf('.exe ');
    return space > 0 ? text.substring(0, space + 4) : text;
  }
}

/// Anywhere but Windows (the macOS development build): Mochi doesn't start itself.
class UnsupportedStartup implements StartupItem {
  const UnsupportedStartup();

  @override
  bool get supported => false;

  @override
  StartupStatus status() => const StartupStatus(enabled: false, note: 'Starting with Windows works in Mochi for Windows.');

  @override
  String? setEnabled(bool enabled) => 'Starting with Windows works in Mochi for Windows.';
}

/// The startup item for this computer.
StartupItem systemStartup() => Platform.isWindows ? RunKeyStartup.system() : const UnsupportedStartup();

/// The registry through package:win32 (RegGetValueW, RegSetKeyValueW, RegDeleteKeyValueW), HKEY_CURRENT_USER only.
class Win32StartupRegistry implements StartupRegistry {
  @override
  String? readString(String key, String name) {
    final bytes = _read(key, name, RRF_RT_REG_SZ);
    if (bytes == null || bytes.length < 2) return bytes == null ? null : '';
    final units = <int>[for (var i = 0; i + 1 < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
    final end = units.indexOf(0);
    return String.fromCharCodes(end < 0 ? units : units.sublist(0, end));
  }

  @override
  List<int>? readBinary(String key, String name) => _read(key, name, RRF_RT_REG_BINARY);

  List<int>? _read(String key, String name, int type) => using((arena) {
    final subKey = key.toNativeUtf16(allocator: arena);
    final value = name.toNativeUtf16(allocator: arena);
    final size = arena<Uint32>();
    var result = RegGetValue(HKEY_CURRENT_USER, subKey, value, type, nullptr, nullptr, size);
    if (result == ERROR_FILE_NOT_FOUND || result == ERROR_PATH_NOT_FOUND) return null;
    if (result != ERROR_SUCCESS) throw StartupException('Windows refused to read the startup setting (error $result).');
    if (size.value == 0) return const <int>[];
    final data = arena<Uint8>(size.value);
    result = RegGetValue(HKEY_CURRENT_USER, subKey, value, type, nullptr, data, size);
    if (result == ERROR_FILE_NOT_FOUND || result == ERROR_PATH_NOT_FOUND) return null;
    if (result != ERROR_SUCCESS) throw StartupException('Windows refused to read the startup setting (error $result).');
    return List<int>.of(data.asTypedList(size.value));
  });

  @override
  void writeString(String key, String name, String value) => using((arena) {
    final data = value.toNativeUtf16(allocator: arena);
    // The size in bytes, with the closing null.
    final bytes = (value.length + 1) * 2;
    final result = RegSetKeyValue(
      HKEY_CURRENT_USER,
      key.toNativeUtf16(allocator: arena),
      name.toNativeUtf16(allocator: arena),
      REG_SZ,
      data,
      bytes,
    );
    if (result != ERROR_SUCCESS) throw StartupException("Windows didn't let Mochi add itself to your startup apps (error $result).");
  });

  @override
  void delete(String key, String name) => using((arena) {
    final result = RegDeleteKeyValue(HKEY_CURRENT_USER, key.toNativeUtf16(allocator: arena), name.toNativeUtf16(allocator: arena));
    if (result != ERROR_SUCCESS && result != ERROR_FILE_NOT_FOUND && result != ERROR_PATH_NOT_FOUND) {
      throw StartupException("Windows didn't let Mochi remove itself from your startup apps (error $result).");
    }
  });
}
