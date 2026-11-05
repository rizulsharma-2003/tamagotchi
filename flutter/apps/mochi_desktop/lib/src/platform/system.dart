// Small things the desktop app asks the operating system: the PC's name, whether animations are turned off, opening a
// link. Each sits behind a function or interface so tests (and the macOS development build) can stand in.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/ask_mochi.dart' show UrlOpener;
import 'win32.dart';

/// How the phones and the relay list this computer: the Windows PC name (`COMPUTERNAME`, "DESKTOP-4K2J9"), or on the
/// macOS development build the Mac's name with a note that it's the Flutter app.
String computerName({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  if (Platform.isWindows) {
    final name = env['COMPUTERNAME'];
    return name == null || name.isEmpty ? Platform.localHostname : name;
  }
  if (Platform.isMacOS) {
    try {
      final result = Process.runSync('/usr/sbin/scutil', ['--get', 'ComputerName']);
      final name = (result.stdout as String).trim();
      if (result.exitCode == 0 && name.isNotEmpty) return '$name (Mochi Desktop)';
    } on Object {
      // Fall through.
    }
  }
  return Platform.localHostname;
}

/// Whether the system asks for less motion: Windows' "Animation effects" off, or macOS' Reduce Motion. Flutter's
/// `MediaQuery.disableAnimations` doesn't follow these on the desktop, so the app asks, at launch and every minute.
class SystemMotion extends ValueNotifier<bool> {
  SystemMotion({bool Function()? read, Duration interval = const Duration(minutes: 1)}) : _read = read ?? _readSystem, super(false) {
    refresh();
    _timer = Timer.periodic(interval, (_) => refresh());
  }

  final bool Function() _read;
  Timer? _timer;

  /// True when animations should be calmer.
  bool get reduced => value;

  void refresh() {
    try {
      value = _read();
    } on Object {
      // Keep the last answer.
    }
  }

  static bool _readSystem() {
    if (Platform.isWindows) return WindowsAnimationSetting.enabled() == false;
    if (Platform.isMacOS) {
      final result = Process.runSync('/usr/bin/defaults', ['read', 'com.apple.universalaccess', 'reduceMotion']);
      return result.exitCode == 0 && (result.stdout as String).trim() == '1';
    }
    return false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

/// Opens https links in the default browser: `rundll32 url.dll,FileProtocolHandler` on Windows (no shell, so `&` in
/// a link is safe), `open` on macOS.
class SystemUrlOpener implements UrlOpener {
  const SystemUrlOpener();

  @override
  Future<bool> open(Uri url) async {
    if (url.scheme != 'https') return false;
    try {
      final result = Platform.isWindows
          ? await Process.run('rundll32', ['url.dll,FileProtocolHandler', url.toString()])
          : await Process.run('/usr/bin/open', [url.toString()]);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }
}
