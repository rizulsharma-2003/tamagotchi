// The native window and the tray icon, behind interfaces so the screens can be tested without them.
//
// Flutter 3.35 has one window per app, so the window has two forms: the desktop pet (small, frameless, transparent,
// always on top, not in the taskbar) and the main window (Mochi's sessions, Ask Mochi, pairing, settings). The window
// is frameless in both: the main window draws its own title bar and rounded corners. Closing it brings the pet back;
// Quit is in the tray menu.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Alignment, Colors;
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Which form the window has.
enum Surface { pet, main, hidden }

/// What the tray menu (and the pet's menu) can ask for.
enum ShellAction { showMain, closeWindow, pair, settings, quit }

abstract interface class DesktopShell {
  /// Shows [surface]: the pet at [petPosition] (screen coordinates; null: bottom left, just above the taskbar).
  Future<void> show(Surface surface, {Offset? petPosition});

  /// Moves the window with the mouse (call on a drag start).
  Future<void> startDragging();

  /// Where the window is now (to remember the pet's spot).
  Future<Offset?> position();

  /// Closes the window and ends the app.
  Future<void> quit();

  /// The tray menu, the window's close button and a second launch of the app (Windows) ask for these.
  Stream<ShellAction> get actions;
}

/// The size of each form, in logical pixels.
abstract final class SurfaceSizes {
  static const Size pet = Size(176, 200);
  static const Size main = Size(460, 720);
  static const Size mainMinimum = Size(400, 520);
}

/// window_manager and tray_manager (Windows; the macOS development build).
class NativeShell with WindowListener, TrayListener implements DesktopShell {
  NativeShell();

  final StreamController<ShellAction> _actions = StreamController.broadcast();
  Surface _surface = Surface.hidden;

  Surface get surface => _surface;

  /// The Windows runner sends `showMain` here when Mochi is launched a second time (windows/runner/flutter_window.cpp).
  static const MethodChannel _instance = MethodChannel('mochi/instance');

  @override
  Stream<ShellAction> get actions => _actions.stream;

  /// Call once before `runApp`'s first frame shows.
  Future<void> init() async {
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        title: 'Mochi',
        size: SurfaceSizes.pet,
        backgroundColor: Colors.transparent,
        skipTaskbar: true,
        titleBarStyle: TitleBarStyle.hidden,
        windowButtonVisibility: false,
      ),
    );
    await windowManager.setAsFrameless();
    await windowManager.setPreventClose(true);
    _instance.setMethodCallHandler((call) async {
      if (call.method == 'showMain') _actions.add(ShellAction.showMain);
    });
    await _initTray();
  }

  Future<void> _initTray() async {
    trayManager.addListener(this);
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray/tray_icon.ico' : 'assets/tray/tray_icon.png');
    if (!Platform.isLinux) await trayManager.setToolTip('Mochi');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: ShellAction.showMain.name, label: 'Show Mochi'),
          MenuItem(key: ShellAction.pair.name, label: 'Pair a Phone…'),
          MenuItem(key: ShellAction.settings.name, label: 'Settings'),
          MenuItem.separator(),
          MenuItem(key: ShellAction.quit.name, label: 'Quit Mochi'),
        ],
      ),
    );
  }

  @override
  Future<void> show(Surface surface, {Offset? petPosition}) async {
    final previous = _surface;
    _surface = surface;
    switch (surface) {
      case Surface.hidden:
        await windowManager.hide();
      case Surface.pet:
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setSkipTaskbar(true);
        await windowManager.setResizable(false);
        await windowManager.setHasShadow(false);
        await windowManager.setMinimumSize(SurfaceSizes.pet);
        await windowManager.setSize(SurfaceSizes.pet);
        if (petPosition != null) {
          await windowManager.setPosition(petPosition);
        } else {
          // Bottom left, just above the taskbar (the work area), where Windows 11 shows its widgets tile.
          await windowManager.setAlignment(Alignment.bottomLeft);
        }
        // Shown without taking the focus from whatever you're typing in.
        await windowManager.show(inactive: true);
      case Surface.main:
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setSkipTaskbar(false);
        await windowManager.setHasShadow(true);
        if (previous != Surface.main) {
          await windowManager.setMinimumSize(SurfaceSizes.mainMinimum);
          await windowManager.setSize(SurfaceSizes.main);
          await windowManager.center();
        }
        await windowManager.setResizable(true);
        await windowManager.show();
        await windowManager.focus();
    }
  }

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<Offset?> position() async {
    try {
      return await windowManager.getPosition();
    } on Object {
      return null;
    }
  }

  @override
  Future<void> quit() async {
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
    exit(0);
  }

  // The window's own close (Alt+F4, the taskbar's Close window): the main window goes back to the pet, the pet hides;
  // quitting is only in the tray menu.
  @override
  void onWindowClose() => _actions.add(ShellAction.closeWindow);

  // Windows: a left click opens Mochi, a right click shows the menu. macOS: a click shows the menu.
  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      _actions.add(ShellAction.showMain);
    } else {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final action = ShellAction.values.where((action) => action.name == menuItem.key).firstOrNull;
    if (action != null) _actions.add(action);
  }

  /// Development (`MOCHI_DESKTOP_OPEN=tray`): pops the tray menu up without a click, for screenshots.
  Future<void> popUpTrayMenu() => trayManager.popUpContextMenu();
}
