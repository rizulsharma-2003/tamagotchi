// What Desktop icon play (docs/SPRINT_2.md X5, core/icon_play.dart) asks of Windows. Moving a user's own desktop icons is
// delicate, so this file says exactly what is read and what is not:
//
// - The runner's `desktopIcons` and `moveDesktopIcon` on the `mochi/system` channel (windows/runner/desktop_icons.cpp: the
//   shell's own IFolderView2 of the desktop, every call on one worker thread; the answer comes back on the UI thread).
//   Dart sees only whether Auto arrange, "Align icons to grid" and "Show desktop icons" are on, the cell size and the icon
//   size, and for each of at most 64 icons an opaque id (a hash of its item id) and where it is. Icon names, paths and
//   contents are never read into Dart, kept, logged or sent.
// - Whether the desktop or a taskbar is the foreground window: GetForegroundWindow and GetClassName against four class
//   names (Progman, WorkerW, Shell_TrayWnd, Shell_SecondaryTrayWnd), and nothing else about any window.
// - Whether a mouse button is down: GetAsyncKeyState for the three buttons.
//
// The macOS development build has none ([NoDesktopIcons]); tests use a fake.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

/// One desktop icon: an opaque id and the top-left of its cell, in screen physical pixels.
@immutable
class DesktopIcon {
  const DesktopIcon(this.id, this.x, this.y);

  final String id;
  final int x, y;

  @override
  bool operator ==(Object other) => other is DesktopIcon && other.id == id && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(id, x, y);
}

/// What one read of the desktop says.
@immutable
class IconsRead {
  const IconsRead({
    required this.autoArrange,
    required this.grid,
    required this.hidden,
    required this.cellWidth,
    required this.cellHeight,
    required this.iconSize,
    required this.icons,
    this.more = false,
  });

  /// "Auto arrange icons", "Align icons to grid", and icons hidden ("Show desktop icons" off).
  final bool autoArrange, grid, hidden;

  /// One icon's cell, and the icon image's side, in physical pixels.
  final int cellWidth, cellHeight, iconSize;

  /// At most [most] icons.
  final List<DesktopIcon> icons;

  /// The desktop has icons this read does not list (more than [most], or one whose place was not known): nothing here is
  /// safe to call free.
  final bool more;

  static const int most = 64;

  /// The icon with [id], or null.
  DesktopIcon? find(String id) {
    for (final icon in icons) {
      if (icon.id == id) return icon;
    }
    return null;
  }

  /// The runner's answer, or null when it is not one (a malformed map, no cell, no icons size, a repeated id).
  static IconsRead? fromJson(Object? json) {
    if (json is! Map) return null;
    final spacing = json['spacing'], size = json['iconSize'], list = json['icons'];
    if (spacing is! List || spacing.length != 2 || spacing[0] is! int || spacing[1] is! int || size is! int || list is! List) return null;
    final width = spacing[0] as int, height = spacing[1] as int;
    if (width <= 0 || height <= 0 || size <= 0) return null;
    final icons = <DesktopIcon>[];
    final seen = <String>{};
    var more = json['more'] == true;
    for (final entry in list) {
      if (entry is! Map) return null;
      final id = entry['id'], x = entry['x'], y = entry['y'];
      if (id is! String || id.isEmpty || x is! int || y is! int) return null;
      if (!seen.add(id)) {
        more = true;
        continue;
      }
      if (icons.length >= most) {
        more = true;
        continue;
      }
      icons.add(DesktopIcon(id, x, y));
    }
    return IconsRead(
      autoArrange: json['autoArrange'] == true,
      grid: json['grid'] == true,
      hidden: json['hidden'] == true,
      cellWidth: width,
      cellHeight: height,
      iconSize: size,
      icons: icons,
      more: more,
    );
  }
}

/// The few things icon play asks of Windows.
abstract interface class DesktopIcons {
  /// The desktop now, or null on any failure (no desktop view, Explorer restarting, a call that was replaced by a newer one).
  Future<IconsRead?> read();

  /// Moves icon [id] (from the latest [read]) so its cell's top-left is at ([x], [y]) (screen pixels), without selecting or
  /// focusing it. False when the shell would not, or on any failure; the icon is then read again before anything is
  /// believed.
  Future<bool> move(String id, int x, int y);

  /// The desktop (Progman, WorkerW) or a taskbar is the foreground window: you are using the desktop.
  bool usingDesktop();

  /// A mouse button is down.
  bool mouseDown();
}

/// Where icon play can't run (the macOS development build): there is no desktop to read.
class NoDesktopIcons implements DesktopIcons {
  const NoDesktopIcons();

  @override
  Future<IconsRead?> read() async => null;

  @override
  Future<bool> move(String id, int x, int y) async => false;

  @override
  bool usingDesktop() => false;

  @override
  bool mouseDown() => false;
}

/// The runner's shell calls, and the two window reads above through Win32.
class RunnerDesktopIcons implements DesktopIcons {
  RunnerDesktopIcons({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('mochi/system');

  final MethodChannel _channel;

  /// The shell's own windows: the desktop and the taskbars.
  static const Set<String> _desktopClasses = {'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd'};

  @override
  Future<IconsRead?> read() async {
    try {
      return IconsRead.fromJson(await _channel.invokeMethod<Object?>('desktopIcons'));
    } on Object {
      return null;
    }
  }

  @override
  Future<bool> move(String id, int x, int y) async {
    try {
      return await _channel.invokeMethod<bool>('moveDesktopIcon', {'id': id, 'x': x, 'y': y}) ?? false;
    } on Object {
      return false;
    }
  }

  @override
  bool usingDesktop() {
    final name = calloc<Uint16>(40);
    try {
      final window = GetForegroundWindow();
      if (window == 0) return false;
      final length = GetClassName(window, name.cast<Utf16>(), 40);
      return length > 0 && _desktopClasses.contains(name.cast<Utf16>().toDartString());
    } on Object {
      // Can't tell: assume the desktop is in use, so nothing moves.
      return true;
    } finally {
      calloc.free(name);
    }
  }

  @override
  bool mouseDown() {
    try {
      for (final button in const [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON]) {
        if (GetAsyncKeyState(button) & 0x8000 != 0) return true;
      }
      return false;
    } on Object {
      // Can't tell: assume it is, so nothing moves.
      return true;
    }
  }
}

DesktopIcons systemDesktopIcons() => Platform.isWindows ? RunnerDesktopIcons() : const NoDesktopIcons();
