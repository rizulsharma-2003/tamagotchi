// Mochi's global shortcuts (docs/SPRINT_2.md W4): show or hide the desktop pet (the Mac's ⌃⌥⌘P) and Ask Mochi (the
// Mac's ⌥Space), chosen in Settings. Registered with Windows' RegisterHotKey, which tells Mochi only that its own
// combination was pressed: no other keystroke is ever seen.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// A key combination: modifiers and one key (a Windows virtual-key code).
@immutable
class Hotkey {
  const Hotkey(this.key, {this.ctrl = false, this.alt = false, this.shift = false, this.win = false});

  final int key;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final bool win;

  /// The Mac's ⌃⌥⌘P: Ctrl+Alt+Win+P.
  static const Hotkey petDefault = Hotkey(0x50, ctrl: true, alt: true, win: true);

  /// The Mac's ⌥Space, moved off Alt+Space (Windows' window menu): Ctrl+Alt+Space.
  static const Hotkey askDefault = Hotkey(0x20, ctrl: true, alt: true);

  /// RegisterHotKey's modifier flags (MOD_ALT 1, MOD_CONTROL 2, MOD_SHIFT 4, MOD_WIN 8).
  int get modifiers => (alt ? 1 : 0) | (ctrl ? 2 : 0) | (shift ? 4 : 0) | (win ? 8 : 0);

  int get modifierCount => [ctrl, alt, shift, win].where((on) => on).length;

  /// "Ctrl+Alt+Win+P", in Windows' order.
  String get label => [if (ctrl) 'Ctrl', if (alt) 'Alt', if (shift) 'Shift', if (win) 'Win', keyName(key) ?? 'Key ${key.toRadixString(16)}'].join('+');

  /// The keys one by one, for key caps ("Ctrl", "Alt", "Win", "P").
  List<String> get keys => label.split('+');

  @override
  String toString() => label;

  @override
  bool operator ==(Object other) =>
      other is Hotkey && other.key == key && other.ctrl == ctrl && other.alt == alt && other.shift == shift && other.win == win;

  @override
  int get hashCode => Object.hash(key, ctrl, alt, shift, win);

  /// "Ctrl+Alt+Space" (any case, "Control", "Windows" and "Meta" too) back into a hotkey; null if it isn't one.
  static Hotkey? parse(String text) {
    final parts = text.split('+').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    var ctrl = false, alt = false, shift = false, win = false;
    for (final part in parts.take(parts.length - 1)) {
      switch (part.toLowerCase()) {
        case 'ctrl' || 'control':
          ctrl = true;
        case 'alt':
          alt = true;
        case 'shift':
          shift = true;
        case 'win' || 'windows' || 'meta' || 'super':
          win = true;
        default:
          return null;
      }
    }
    final key = keyCode(parts.last);
    if (key == null) return null;
    return Hotkey(key, ctrl: ctrl, alt: alt, shift: shift, win: win);
  }

  static final Map<int, String> _names = {
    for (var c = 0x41; c <= 0x5A; c++) c: String.fromCharCode(c),
    for (var d = 0x30; d <= 0x39; d++) d: String.fromCharCode(d),
    for (var f = 1; f <= 24; f++) 0x6F + f: 'F$f',
    0x20: 'Space',
    0x0D: 'Enter',
    0x09: 'Tab',
    0x1B: 'Esc',
    0x08: 'Backspace',
    0x2E: 'Delete',
    0x2D: 'Insert',
    0x24: 'Home',
    0x23: 'End',
    0x21: 'PageUp',
    0x22: 'PageDown',
    0x25: 'Left',
    0x26: 'Up',
    0x27: 'Right',
    0x28: 'Down',
    0x2C: 'PrintScreen',
    0xBC: ',',
    0xBE: '.',
    0xBF: '/',
    0xBA: ';',
    0xDE: "'",
    0xDB: '[',
    0xDD: ']',
    0xDC: r'\',
    0xBD: '-',
    0xBB: '=',
    0xC0: '`',
  };

  /// "P", "Space", "F5"; null for a key Mochi doesn't name.
  static String? keyName(int key) => _names[key];

  static int? keyCode(String name) {
    final wanted = name.toLowerCase();
    for (final entry in _names.entries) {
      if (entry.value.toLowerCase() == wanted) return entry.key;
    }
    return switch (wanted) {
      'escape' => 0x1B,
      'return' => 0x0D,
      'del' => 0x2E,
      'pgup' => 0x21,
      'pgdn' => 0x22,
      _ => null,
    };
  }

  /// The virtual-key code for a key Flutter reports (null for modifiers and keys Mochi doesn't use).
  static int? keyFor(LogicalKeyboardKey key) {
    final id = key.keyId;
    final letter = id - LogicalKeyboardKey.keyA.keyId;
    if (letter >= 0 && letter < 26) return 0x41 + letter;
    final digit = id - LogicalKeyboardKey.digit0.keyId;
    if (digit >= 0 && digit < 10) return 0x30 + digit;
    const functions = [
      LogicalKeyboardKey.f1, LogicalKeyboardKey.f2, LogicalKeyboardKey.f3, LogicalKeyboardKey.f4, LogicalKeyboardKey.f5, //
      LogicalKeyboardKey.f6, LogicalKeyboardKey.f7, LogicalKeyboardKey.f8, LogicalKeyboardKey.f9, LogicalKeyboardKey.f10,
      LogicalKeyboardKey.f11, LogicalKeyboardKey.f12, LogicalKeyboardKey.f13, LogicalKeyboardKey.f14, LogicalKeyboardKey.f15,
      LogicalKeyboardKey.f16, LogicalKeyboardKey.f17, LogicalKeyboardKey.f18, LogicalKeyboardKey.f19, LogicalKeyboardKey.f20,
      LogicalKeyboardKey.f21, LogicalKeyboardKey.f22, LogicalKeyboardKey.f23, LogicalKeyboardKey.f24,
    ];
    final function = functions.indexOf(key);
    if (function >= 0) return 0x70 + function;
    final others = <LogicalKeyboardKey, int>{
      LogicalKeyboardKey.space: 0x20,
      LogicalKeyboardKey.enter: 0x0D,
      LogicalKeyboardKey.tab: 0x09,
      LogicalKeyboardKey.backspace: 0x08,
      LogicalKeyboardKey.delete: 0x2E,
      LogicalKeyboardKey.insert: 0x2D,
      LogicalKeyboardKey.home: 0x24,
      LogicalKeyboardKey.end: 0x23,
      LogicalKeyboardKey.pageUp: 0x21,
      LogicalKeyboardKey.pageDown: 0x22,
      LogicalKeyboardKey.arrowLeft: 0x25,
      LogicalKeyboardKey.arrowUp: 0x26,
      LogicalKeyboardKey.arrowRight: 0x27,
      LogicalKeyboardKey.arrowDown: 0x28,
      LogicalKeyboardKey.comma: 0xBC,
      LogicalKeyboardKey.period: 0xBE,
      LogicalKeyboardKey.slash: 0xBF,
      LogicalKeyboardKey.semicolon: 0xBA,
      LogicalKeyboardKey.quote: 0xDE,
      LogicalKeyboardKey.bracketLeft: 0xDB,
      LogicalKeyboardKey.bracketRight: 0xDD,
      LogicalKeyboardKey.backslash: 0xDC,
      LogicalKeyboardKey.minus: 0xBD,
      LogicalKeyboardKey.equal: 0xBB,
      LogicalKeyboardKey.backquote: 0xC0,
    };
    return others[key];
  }

  /// Whether [key] is one of the modifier keys (still choosing the combination).
  static bool isModifier(LogicalKeyboardKey key) => <LogicalKeyboardKey>{
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  }.contains(key);
}

/// Mochi's two shortcuts.
enum MochiShortcut {
  /// Show or hide the desktop pet.
  pet,

  /// Ask Mochi: Mochi's window with the question box ready.
  ask;

  /// The id it's registered with (RegisterHotKey's).
  int get id => index + 1;

  String get title => switch (this) {
    pet => 'Show or hide the desktop pet',
    ask => 'Ask Mochi',
  };

  Hotkey get defaultHotkey => switch (this) {
    pet => Hotkey.petDefault,
    ask => Hotkey.askDefault,
  };
}

/// Why a combination can't be Mochi's: the words Settings shows.
abstract final class HotkeyConflicts {
  /// Combinations Windows (or its standard tools) already uses, and what for.
  static final Map<Hotkey, String> reserved = {
    const Hotkey(0x20, alt: true): 'opens the window menu in Windows (and PowerToys Run)',
    const Hotkey(0x09, alt: true): 'switches windows',
    const Hotkey(0x09, alt: true, shift: true): 'switches windows',
    const Hotkey(0x09, ctrl: true, alt: true): 'shows Windows’ window switcher',
    const Hotkey(0x1B, alt: true): 'cycles through windows',
    const Hotkey(0x73, alt: true): 'closes the window you’re in',
    const Hotkey(0x1B, ctrl: true): 'opens Start',
    const Hotkey(0x1B, ctrl: true, shift: true): 'opens Task Manager',
    const Hotkey(0x2E, ctrl: true, alt: true): 'is Windows’ security screen',
    const Hotkey(0x53, win: true, shift: true): 'takes a screenshot with Snipping Tool',
    const Hotkey(0x4D, win: true, shift: true): 'restores minimised windows',
    for (final arrow in const [0x25, 0x26, 0x27, 0x28]) Hotkey(arrow, win: true, shift: true): 'moves or stretches windows',
    const Hotkey(0x44, win: true, ctrl: true): 'adds a virtual desktop',
    const Hotkey(0x73, win: true, ctrl: true): 'closes a virtual desktop',
    const Hotkey(0x25, win: true, ctrl: true): 'switches virtual desktops',
    const Hotkey(0x27, win: true, ctrl: true): 'switches virtual desktops',
    const Hotkey(0x0D, win: true, ctrl: true): 'turns Narrator on or off',
    const Hotkey(0x4F, win: true, ctrl: true): 'opens the on-screen keyboard',
    const Hotkey(0x43, win: true, ctrl: true): 'turns colour filters on or off',
    const Hotkey(0x51, win: true, ctrl: true): 'opens Quick Assist',
    const Hotkey(0x46, win: true, ctrl: true): 'searches for PCs on a network',
    const Hotkey(0x42, win: true, ctrl: true, shift: true): 'restarts the graphics driver',
    const Hotkey(0x52, win: true, alt: true): 'records with Game Bar',
    const Hotkey(0x47, win: true, alt: true): 'records with Game Bar',
    const Hotkey(0x2C, win: true, alt: true): 'takes a screenshot with Game Bar',
    const Hotkey(0x42, win: true, alt: true): 'turns HDR on or off',
    const Hotkey(0x4B, win: true, alt: true): 'mutes your microphone in calls',
    const Hotkey(0x44, win: true, alt: true): 'shows the date and time',
    const Hotkey(0x26, win: true, alt: true): 'snaps windows',
    const Hotkey(0x28, win: true, alt: true): 'snaps windows',
  };

  /// Null when [hotkey] can be Mochi's [shortcut]; otherwise why not. [other] is Mochi's other shortcut.
  static String? problem(Hotkey hotkey, {required MochiShortcut shortcut, Hotkey? other}) {
    final label = hotkey.label;
    final reason = reserved[hotkey];
    if (reason != null) {
      return hotkey == const Hotkey(0x20, alt: true)
          ? '$label $reason. Try ${Hotkey.askDefault.label}.'
          : '$label $reason. Pick another shortcut.';
    }
    // Windows keeps Win with a number for the taskbar's apps (with Shift, Ctrl or Alt too).
    if (hotkey.win && hotkey.key >= 0x30 && hotkey.key <= 0x39 && !(hotkey.ctrl && hotkey.alt)) {
      return '$label opens an app on the taskbar. Pick another shortcut.';
    }
    if (hotkey.win && hotkey.modifierCount == 1) {
      return 'Win with one key belongs to Windows. Add Ctrl, Alt or Shift.';
    }
    if (!hotkey.win && !(hotkey.ctrl && hotkey.alt)) {
      return '$label belongs to the app you’re in. Use Ctrl+Alt or Win with another key.';
    }
    if (other != null && hotkey == other) {
      final otherName = MochiShortcut.values.firstWhere((value) => value != shortcut).title;
      return '$label is already Mochi’s shortcut for “$otherName”.';
    }
    return null;
  }
}

/// Registers Mochi's shortcuts with Windows and says when one is pressed (RegisterHotKey through the runner, a fake in
/// tests). [supported] is false on the macOS development build.
abstract interface class HotkeyRegistrar {
  bool get supported;

  /// False when the combination is taken (by another app, or by Windows).
  Future<bool> register(int id, Hotkey hotkey);
  Future<void> unregister(int id);

  /// The id of a shortcut that was pressed.
  Stream<int> get pressed;
}

class UnsupportedHotkeys implements HotkeyRegistrar {
  const UnsupportedHotkeys();

  @override
  bool get supported => false;

  @override
  Future<bool> register(int id, Hotkey hotkey) async => false;

  @override
  Future<void> unregister(int id) async {}

  @override
  Stream<int> get pressed => const Stream.empty();
}

/// Keeps Windows' registrations in step with Settings and runs a shortcut's action when it's pressed. Says when a
/// combination couldn't be registered (another app has it).
class Hotkeys extends ChangeNotifier {
  Hotkeys({required this.registrar, required Hotkey? Function(MochiShortcut) chosen, required void Function(MochiShortcut) onPressed})
    : _chosen = chosen,
      _onPressed = onPressed;

  final HotkeyRegistrar registrar;
  final Hotkey? Function(MochiShortcut) _chosen;
  final void Function(MochiShortcut) _onPressed;

  final Map<MochiShortcut, Hotkey> _registered = {};
  final Map<MochiShortcut, String> _problems = {};
  StreamSubscription<int>? _pressed;
  bool _suspended = false;
  bool _started = false;

  /// Why [shortcut] isn't working (another app has its combination), or null.
  String? problem(MochiShortcut shortcut) => _problems[shortcut];

  /// The combination Windows has for [shortcut] right now.
  Hotkey? registered(MochiShortcut shortcut) => _registered[shortcut];

  /// While Settings records a new combination, Mochi's own shortcuts let the keys through.
  bool get suspended => _suspended;

  Future<void> start() async {
    if (_started || !registrar.supported) return;
    _started = true;
    _pressed = registrar.pressed.listen((id) {
      if (_suspended) return;
      final shortcut = MochiShortcut.values.where((value) => value.id == id).firstOrNull;
      if (shortcut != null) _onPressed(shortcut);
    });
    await apply();
  }

  /// Registers what Settings has chosen (again, after a change).
  Future<void> apply() async {
    if (!_started) return;
    var changed = false;
    for (final shortcut in MochiShortcut.values) {
      final wanted = _suspended ? null : _chosen(shortcut);
      final current = _registered[shortcut];
      if (wanted == current && (wanted != null || !_problems.containsKey(shortcut))) continue;
      if (current != null) {
        await registrar.unregister(shortcut.id);
        _registered.remove(shortcut);
      }
      _problems.remove(shortcut);
      if (wanted != null) {
        if (await registrar.register(shortcut.id, wanted)) {
          _registered[shortcut] = wanted;
        } else {
          _problems[shortcut] = '${wanted.label} is already used by another app. Pick another shortcut.';
        }
      }
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// Settings is recording a combination: Mochi's shortcuts are let go until [resume].
  Future<void> suspend() async {
    if (_suspended) return;
    _suspended = true;
    await apply();
    notifyListeners();
  }

  Future<void> resume() async {
    if (!_suspended) return;
    _suspended = false;
    await apply();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_pressed?.cancel());
    for (final shortcut in _registered.keys.toList()) {
      unawaited(registrar.unregister(shortcut.id));
    }
    _registered.clear();
    super.dispose();
  }
}
