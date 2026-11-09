// "What's on my screen?" (docs/SPRINT_2.md X17): opt-in, per request, one window.
//
// - Settings › Assistant › "Let me show Mochi my screen" is off at first, and the button is hidden while it is.
// - The picture is of ONE window: the one you were using before Mochi's window or popover came up ([ForegroundMemory]),
//   never the whole screen and never automatic. It is taken only when the button is pressed.
// - It shows on a preview card (the window's program name only, Remove, Send); nothing leaves the PC until Send.
// - On Send it is written to Mochi's Assistant folder under a random name for Claude Code to read (the brain's Read gate
//   allows exactly that path for that request), and deleted when the request ends however it ends, and at startup.
//
// Never logged: the picture, its path, the window's title.

import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../platform/foreground_window.dart';
import 'ask_attach.dart';

/// Why a window couldn't be seen.
enum ScreenFailure { noWindow, minimised, cloaked, ours, shell, failed }

/// One window's picture (or why there isn't one).
class ScreenGrab {
  const ScreenGrab.seen({required Uint8List this.png, required String this.app}) : failure = null;
  const ScreenGrab.failed(ScreenFailure this.failure) : png = null, app = null;

  final Uint8List? png;
  final String? app;
  final ScreenFailure? failure;
}

/// Takes a picture of one window (PrintWindow on Windows; a fake in tests).
abstract interface class WindowCapturer {
  Future<ScreenGrab> capture(int hwnd);
}

/// No capture (the macOS development build).
class NoWindowCapturer implements WindowCapturer {
  const NoWindowCapturer();

  @override
  Future<ScreenGrab> capture(int hwnd) async => const ScreenGrab.failed(ScreenFailure.failed);
}

/// The last window you were using that isn't one of Mochi's: noted when Mochi's window or popover comes up (events that
/// already happen), never polled. The shell's desktop and taskbar and Mochi's own windows are not remembered.
class ForegroundMemory {
  ForegroundMemory(this._windows);

  final ForegroundWindows _windows;
  int _hwnd = 0;

  /// The remembered window (0: none).
  int get hwnd => _hwnd;

  /// Mochi's window or popover is coming up: look once at what has the focus.
  void note() {
    final window = _windows.read();
    if (window != null && window.kind == ForegroundKind.app && window.hwnd != 0) _hwnd = window.hwnd;
  }
}

/// A program name for a prompt and a card: letters, digits, spaces, `.`, `-` and `_`, no `.exe`, at most 40 characters.
abstract final class AppNames {
  static String clean(String? name) {
    var kept = (name ?? '').replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '').trim();
    if (kept.toLowerCase().endsWith('.exe')) kept = kept.substring(0, kept.length - 4).trim();
    if (kept.length > 40) kept = kept.substring(0, 40).trim();
    return kept.isEmpty ? 'that app' : kept;
  }
}

/// The button and its preview card. The Ask box shows both from here.
class ScreenPeek extends ChangeNotifier {
  ScreenPeek({
    required this.memory,
    required this.capturer,
    required bool Function() enabled,
    String Function()? petName,
  }) : _enabled = enabled,
       _petName = petName ?? (() => 'Mochi') {
    _was = enabled();
  }

  final ForegroundMemory memory;
  final WindowCapturer capturer;
  final bool Function() _enabled;
  final String Function() _petName;

  ScreenPreview? _preview;
  bool _busy = false;
  String? _note;
  int _generation = 0;

  /// Settings › Assistant › "Let me show Mochi my screen". Off: no button, no preview, nothing taken.
  bool get enabled => _enabled();

  /// The picture waiting for Send (null: none, or the switch is off).
  ScreenPreview? get preview => enabled ? _preview : null;
  bool get busy => _busy;

  /// Mochi's words when it couldn't see the window.
  String? get note => _note;

  /// The button was pressed: take one picture of the remembered window. The only way a picture is ever taken.
  Future<void> look() async {
    if (!enabled || _busy) return;
    final generation = ++_generation;
    _busy = true;
    _note = null;
    _preview = null;
    notifyListeners();
    final pet = _petName();
    final hwnd = memory.hwnd;
    String? note;
    ScreenPreview? preview;
    if (hwnd == 0) {
      note = "$pet doesn't know which window you were using. Press Mochi's shortcut while you're in that window, then try again.";
    } else {
      try {
        final grab = await capturer.capture(hwnd);
        final png = grab.png;
        if (png != null && png.isNotEmpty) {
          preview = ScreenPreview(png: png, app: AppNames.clean(grab.app));
        } else {
          note = "$pet couldn't see that window (${switch (grab.failure) {
            ScreenFailure.minimised => 'it is minimised',
            ScreenFailure.cloaked => "it isn't showing",
            ScreenFailure.noWindow => 'it is gone',
            ScreenFailure.ours || ScreenFailure.shell => 'it is part of Windows or Mochi',
            _ => 'Windows would not let me'
          }}).";
        }
      } on Object {
        note = "$pet couldn't see that window.";
      }
    }
    // Removed, or asked again, while the picture was being taken: this answer is out of date.
    if (generation != _generation) return;
    _busy = false;
    _preview = preview;
    _note = note;
    notifyListeners();
  }

  bool? _was;

  /// The settings changed: when the switch went off, any picture waiting (or being taken) is dropped at once, and the box
  /// hides its button.
  void settingsChanged() {
    final now = enabled;
    if (now == (_was ?? now)) {
      _was = now;
      return;
    }
    _was = now;
    if (!now) {
      _generation++;
      _busy = false;
      _preview = null;
      _note = null;
    }
    notifyListeners();
  }

  /// Remove on the preview card, or the picture was sent.
  void remove() {
    _generation++;
    if (_preview == null && !_busy && _note == null) return;
    _busy = false;
    _preview = null;
    _note = null;
    notifyListeners();
  }
}

/// Where a picture is written for Claude Code to read, and taken away again.
abstract interface class ScreenshotStore {
  /// Writes [png] under a random name; the path, or null when it couldn't.
  String? write(Uint8List png);

  /// Deletes [path] (only ever a path [write] gave).
  void delete(String path);

  /// Deletes every leftover picture (a request cut short by a crash or a power cut).
  void sweep();
}

/// Mochi's Assistant folder (`%LOCALAPPDATA%\Mochi\Assistant`), where the brain runs: `mochi-screen-<32 hex>.png`.
class FolderScreenshotStore implements ScreenshotStore {
  FolderScreenshotStore(this.directory, {Random? random}) : _random = random ?? Random.secure();

  final String directory;
  final Random _random;

  /// What [write] names its files; [sweep] deletes exactly these.
  static final RegExp pattern = RegExp(r'^mochi-screen-[0-9a-f]{32}\.png$');

  @override
  String? write(Uint8List png) {
    try {
      Directory(directory).createSync(recursive: true);
      final name = 'mochi-screen-${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}.png';
      final path = '$directory${Platform.pathSeparator}$name';
      File(path).writeAsBytesSync(png, flush: true);
      return path;
    } on Object {
      return null;
    }
  }

  @override
  void delete(String path) {
    try {
      // Only ever one of this store's own files (its folder, a name it gave), never another path.
      final cut = path.lastIndexOf(RegExp(r'[\\/]'));
      if (cut <= 0 || !pattern.hasMatch(path.substring(cut + 1))) return;
      String same(String folder) => folder.replaceAll('/', r'\').toLowerCase();
      if (same(path.substring(0, cut)) != same(directory)) return;
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // Left for the next start's sweep.
    }
  }

  @override
  void sweep() {
    try {
      final folder = Directory(directory);
      if (!folder.existsSync()) return;
      for (final entry in folder.listSync(followLinks: false)) {
        if (entry is File && pattern.hasMatch(entry.uri.pathSegments.last)) delete(entry.path);
      }
    } on Object {
      // Nothing to clean, or not readable now.
    }
  }
}
