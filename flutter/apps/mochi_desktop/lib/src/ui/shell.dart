// The native window and the tray icon, behind interfaces so the screens can be tested without them.
//
// Flutter 3.35 has one window per app, so the window has three forms: the desktop pet (small, frameless, transparent,
// always on top, not in the taskbar), the popover (the Mac's menu-bar popover: a flyout above the taskbar where Mochi
// is, opened by clicking it) and the main window (Mochi's sessions, Ask Mochi, pairing, settings). The window is
// frameless in all of them: the main window and the popover draw their own rounded corners. Closing it brings the pet back;
// Quit is in the tray menu. On Windows the pet strolls along the taskbar in a smaller window (ui/pet/taskbar_stroll.dart),
// moved through Win32 (`petWindow`).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show Alignment, Colors, Rect;
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../platform/taskbar.dart';
import '../platform/win32_taskbar.dart';

/// Which form the window has.
enum Surface { pet, popover, main, hidden }

/// What the tray menu (and the pet's menu) can ask for.
enum ShellAction {
  showMain,
  closeWindow,
  pair,
  settings,

  /// "Roam along the taskbar", switched on or off.
  toggleRoaming,

  /// "Back to the taskbar": roaming on again after Mochi was dragged off it.
  backToTaskbar,

  /// The popover lost the focus (a click somewhere else): it closes, as a flyout does.
  dismissPopover,
  quit,
}

abstract interface class DesktopShell {
  /// Shows [surface]: the pet at [petPosition] (screen coordinates; null: bottom left, just above the taskbar), with
  /// the window [petSize] big.
  Future<void> show(Surface surface, {Offset? petPosition, Size petSize = SurfaceSizes.pet});

  /// The pet's window for Win32 moves (Windows only; null elsewhere, where Mochi doesn't roam).
  PetWindow? get petWindow;

  /// Shows [surface]: the popover's top-left is [petPosition] and its size [petSize]; it takes the focus (and gives it
  /// back to the window that had it when it closes with the keyboard or a button).
  ///
  /// The size the main window form takes the next time it's shown: [SurfaceSizes.main] for Mochi's own pages,
  /// [SurfaceSizes.settings] for Settings. Changing it while the main window shows resizes it on the next [show].
  Size get mainSize;
  set mainSize(Size size);

  /// Ticks (or unticks) "Roam along the taskbar" in the tray menu.
  Future<void> setRoaming(bool roaming);

  /// Shows the tray's menu at the pointer (right-clicking Mochi in the taskbar, whose window is too small for its own).
  Future<void> popUpMenu();

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
  /// The pet standing still: Mochi with room for its speech bubble above.
  static const Size pet = Size(176, 200);

  /// The pet's window in the taskbar is Mochi's box (TaskbarStage.box, sized by the taskbar); with a speech bubble it
  /// grows upwards by [bubble] and widens to this.
  static const double taskbarBubbleWidth = 176;

  /// Never smaller than this in any pet form (Mochi's box in a small taskbar).
  static const Size petMinimum = Size(24, 24);

  /// Mochi's own box at the bottom of every pet window, and the bubble's room above it.
  static const double petStage = 144;
  static const double bubble = 56;

  /// How high Mochi's feet are above the bottom of its box, as a part of the box's height: room for its shadow when it
  /// stands still, barely any in the taskbar.
  static const double standingFeet = 0.06;
  static const double taskbarFeet = 0.03;

  /// How much of its box's height Mochi fills, standing and in the taskbar.
  static const double standingFill = 0.78;
  static const double taskbarFill = 0.92;

  static const Size main = Size(460, 720);
  static const Size mainMinimum = Size(400, 520);

  /// The Settings window: the Mac's Settings size, a sidebar and the open pane side by side.
  static const Size settings = Size(900, 660);

  /// The popover: the Mac popover's width, a little taller (it holds the toggles the Mac keeps in its menu too).
  static const Size popover = Size(360, 540);
}

/// window_manager and tray_manager (Windows; the macOS development build).
class NativeShell with WindowListener, TrayListener implements DesktopShell {
  NativeShell();

  final StreamController<ShellAction> _actions = StreamController.broadcast();
  Surface _surface = Surface.hidden;
  PetWindow? _petWindow;
  bool _roaming = true;

  @override
  Size mainSize = SurfaceSizes.main;

  /// The main window's size as last set here (null: it isn't showing).
  Size? _mainShown;

  /// The window that had the focus before the popover opened (Windows), to give it back.
  int _focusBefore = 0;

  Surface get surface => _surface;

  @override
  PetWindow? get petWindow => _petWindow;

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
    if (Platform.isWindows) _petWindow = Win32PetWindow(await windowManager.getId());
    await _initTray();
  }

  Future<void> _initTray() async {
    trayManager.addListener(this);
    await trayManager.setIcon(Platform.isWindows ? 'assets/tray/tray_icon.ico' : 'assets/tray/tray_icon.png');
    if (!Platform.isLinux) await trayManager.setToolTip('Mochi');
    await trayManager.setContextMenu(Menu(items: trayItems(roaming: _roaming)));
  }

  /// The tray menu.
  static List<MenuItem> trayItems({required bool roaming}) => [
    MenuItem(key: ShellAction.showMain.name, label: 'Show Mochi'),
    MenuItem(key: ShellAction.pair.name, label: 'Pair a Phone…'),
    MenuItem(key: ShellAction.settings.name, label: 'Settings'),
    MenuItem.separator(),
    MenuItem.checkbox(key: ShellAction.toggleRoaming.name, label: 'Roam along the taskbar', checked: roaming),
    MenuItem(key: ShellAction.backToTaskbar.name, label: 'Back to the taskbar', disabled: roaming),
    MenuItem.separator(),
    MenuItem(key: ShellAction.quit.name, label: 'Quit Mochi'),
  ];

  @override
  Future<void> setRoaming(bool roaming) async {
    if (roaming == _roaming) return;
    _roaming = roaming;
    await trayManager.setContextMenu(Menu(items: trayItems(roaming: roaming)));
  }

  @override
  Future<void> show(Surface surface, {Offset? petPosition, Size petSize = SurfaceSizes.pet}) async {
    final previous = _surface;
    _surface = surface;
    if (surface != Surface.main) _mainShown = null;
    // Closing the popover with the keyboard or a button: the focus goes back where it was (a click elsewhere already
    // moved it).
    if (previous == Surface.popover && surface != Surface.main && surface != Surface.popover) {
      final before = _focusBefore;
      _focusBefore = 0;
      if (before != 0) _petWindow?.giveFocus(before);
    }
    switch (surface) {
      case Surface.hidden:
        await windowManager.hide();
      case Surface.pet:
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setSkipTaskbar(true);
        await windowManager.setResizable(false);
        await windowManager.setHasShadow(false);
        await windowManager.setMinimumSize(SurfaceSizes.petMinimum);
        await windowManager.setSize(petSize);
        if (petPosition != null) {
          await windowManager.setPosition(petPosition);
        } else {
          // Bottom left, just above the taskbar (the work area), where Windows 11 shows its widgets tile.
          await windowManager.setAlignment(Alignment.bottomLeft);
        }
        // Shown without taking the focus from whatever you're typing in.
        await windowManager.show(inactive: true);
      case Surface.popover:
        _focusBefore = _petWindow?.focusOwner() ?? 0;
        // A flyout: over everything, not in the taskbar, its own shadow and rounded corners, with the focus.
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setSkipTaskbar(true);
        await windowManager.setResizable(false);
        await windowManager.setHasShadow(false);
        await windowManager.setMinimumSize(SurfaceSizes.petMinimum);
        // On Windows the stroll has already put the window there, exactly, in one move (so nothing in it jumps);
        // elsewhere, one move and resize here.
        if (_petWindow == null && petPosition != null) await windowManager.setBounds(petPosition & petSize);
        await windowManager.show();
        await windowManager.focus();
      case Surface.main:
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setSkipTaskbar(false);
        await windowManager.setHasShadow(true);
        if (previous != Surface.main) {
          await windowManager.setMinimumSize(SurfaceSizes.mainMinimum);
          await windowManager.setSize(mainSize);
          await windowManager.center();
        } else if (_mainShown != mainSize) {
          // Settings opened from Mochi's window (or closed back to it): the new size, around the same centre.
          final bounds = await windowManager.getBounds();
          await windowManager.setBounds(Rect.fromCenter(center: bounds.center, width: mainSize.width, height: mainSize.height));
        }
        _mainShown = mainSize;
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

  // A click outside the popover (or another window coming forward) closes it, as a flyout does.
  @override
  void onWindowBlur() {
    if (_surface == Surface.popover) _actions.add(ShellAction.dismissPopover);
  }

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

  @override
  Future<void> popUpMenu() => trayManager.popUpContextMenu();
}
