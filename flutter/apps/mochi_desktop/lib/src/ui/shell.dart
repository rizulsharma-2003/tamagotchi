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
import 'dart:math' as math;

import 'package:flutter/material.dart' show Alignment, Colors, Rect;
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/desktop_settings.dart' show PetSize, DesktopStyle;
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

  /// The fun features (the Mac's status menu): start or stop a focus session, the Games window.
  focus,
  games,
  recap,
  decorate,

  /// Where Mochi lives (the Mac's menu-bar styles): roaming the taskbar, playing in its spot there, or as the classic
  /// tray icon.
  roamTaskbar,
  playInSpot,
  trayIcon,

  /// The popover lost the focus (a click somewhere else): it closes, as a flyout does.
  dismissPopover,
  /// A verified update is waiting: install it now (Mochi quits and starts again).
  restartToUpdate,

  /// The main window was resized (a drag on its edge ended): remember the size.
  windowResized,
  quit,
}

/// An edge or corner of the window, for resizing it by hand.
enum WindowEdge { top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight }

abstract interface class DesktopShell {
  /// Shows [surface]: the pet at [petPosition] (screen coordinates; null: bottom left, just above the taskbar), with
  /// the window [petSize] big, or exactly at [petFrame] (physical pixels, Windows), above other windows or not ([onTop]).
  Future<void> show(Surface surface, {Offset? petPosition, Size petSize = SurfaceSizes.pet, bool onTop = true, PixelRect? petFrame});

  /// The pet's window for Win32 moves (Windows only; null elsewhere, where Mochi doesn't roam).
  PetWindow? get petWindow;

  /// Shows [surface]: the popover's top-left is [petPosition] and its size [petSize]; it takes the focus (and gives it
  /// back to the window that had it when it closes with the keyboard or a button).
  ///
  /// The size the main window form takes the next time it's shown: [SurfaceSizes.main] for Mochi's own pages,
  /// [SurfaceSizes.settings] for Settings. Changing it while the main window shows resizes it on the next [show].
  Size get mainSize;
  set mainSize(Size size);

  /// Ticks where Mochi lives in the tray menu.
  Future<void> setStyle(DesktopStyle style);

  /// The tray icon: the app's own, or (the classic tray icon) a picture of Mochi as it is now ([path], an .ico file),
  /// and what it says when you point at it.
  Future<void> setTrayIcon({String? path, required String tooltip});

  /// Shows (or hides) "Restart to Update" at the top of the tray menu.
  Future<void> setUpdateReady(bool ready);

  /// "Start Focus" or "Stop Focus" in the tray menu, as a focus session runs or not.
  Future<void> setFocusing(bool focusing);

  /// Shows the tray's menu at the pointer (right-clicking Mochi in the taskbar, whose window is too small for its own).
  Future<void> popUpMenu();

  /// Moves the window with the mouse (call on a drag start).
  Future<void> startDragging();

  /// Resizes the window with the mouse from [edge] (call on a drag start on an edge: the window has no frame of its
  /// own to grab).
  Future<void> startResizing(WindowEdge edge);

  /// The window's size now (logical pixels).
  Future<Size?> size();

  /// Where the window is now (to remember the pet's spot).
  Future<Offset?> position();

  /// Closes the window and ends the app.
  Future<void> quit();

  /// The tray menu, the window's close button and a second launch of the app (Windows) ask for these.
  Stream<ShellAction> get actions;
}

/// The size of each form, in logical pixels.
abstract final class SurfaceSizes {
  /// The pet standing still (at its medium size): Mochi with room for its speech bubble above.
  static const Size pet = Size(176, 200);

  /// The desktop pet at [size]: its box, and room for the bubble above it (never narrower than the bubble).
  static Size standing(PetSize size) =>
      Size(math.max(pet.width, (size.stage * pet.width / petStage).roundToDouble()), size.stage + bubble);

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

  /// The Games page: the Mac's Games window (572 × 512 points) with the title bar.
  static const Size games = Size(600, 600);

  /// Today's Recap: the Mac's recap window (470 × 660 points) with the title bar.
  static const Size recap = Size(480, 740);
}

/// window_manager and tray_manager (Windows; the macOS development build).
class NativeShell with WindowListener, TrayListener implements DesktopShell {
  NativeShell();

  final StreamController<ShellAction> _actions = StreamController.broadcast();
  Surface _surface = Surface.hidden;
  PetWindow? _petWindow;
  DesktopStyle _style = DesktopStyle.roam;
  bool _updateReady = false;
  bool _focusing = false;

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
    await _menu();
  }

  Future<void> _menu() => trayManager.setContextMenu(Menu(items: trayItems(style: _style, updateReady: _updateReady, focusing: _focusing)));

  static const String _appIcon = 'assets/tray/tray_icon.ico';
  String? _trayIcon;
  String? _tooltip;

  @override
  Future<void> setTrayIcon({String? path, required String tooltip}) async {
    final icon = path ?? (Platform.isWindows ? _appIcon : 'assets/tray/tray_icon.png');
    if (icon != _trayIcon) {
      _trayIcon = icon;
      // An absolute path is used as it is (tray_manager joins it to the assets folder otherwise).
      await trayManager.setIcon(icon);
    }
    if (tooltip != _tooltip && !Platform.isLinux) {
      _tooltip = tooltip;
      await trayManager.setToolTip(tooltip);
    }
  }

  /// The tray menu.
  static List<MenuItem> trayItems({required DesktopStyle style, bool updateReady = false, bool focusing = false}) => [
    if (updateReady) ...[MenuItem(key: ShellAction.restartToUpdate.name, label: 'Restart to Update'), MenuItem.separator()],
    MenuItem(key: ShellAction.showMain.name, label: 'Show Mochi'),
    MenuItem(key: ShellAction.pair.name, label: 'Pair a Phone…'),
    MenuItem(key: ShellAction.settings.name, label: 'Settings'),
    MenuItem.separator(),
    MenuItem(key: ShellAction.focus.name, label: focusing ? 'Stop Focus' : 'Start Focus'),
    MenuItem(key: ShellAction.games.name, label: 'Games…'),
    MenuItem(key: ShellAction.recap.name, label: 'Today’s Recap…'),
    MenuItem(key: ShellAction.decorate.name, label: 'Decorate the Room…'),
    MenuItem.separator(),
    // Where Mochi lives, as the Mac's status menu lists its styles.
    MenuItem.checkbox(key: ShellAction.roamTaskbar.name, label: DesktopStyle.roam.title, checked: style == DesktopStyle.roam),
    MenuItem.checkbox(key: ShellAction.playInSpot.name, label: DesktopStyle.spot.title, checked: style == DesktopStyle.spot),
    MenuItem.checkbox(key: ShellAction.trayIcon.name, label: DesktopStyle.icon.title, checked: style == DesktopStyle.icon),
    MenuItem.separator(),
    MenuItem(key: ShellAction.quit.name, label: 'Quit Mochi'),
  ];

  @override
  Future<void> setStyle(DesktopStyle style) async {
    if (style == _style) return;
    _style = style;
    await _menu();
  }

  @override
  Future<void> setFocusing(bool focusing) async {
    if (focusing == _focusing) return;
    _focusing = focusing;
    await _menu();
  }

  @override
  Future<void> setUpdateReady(bool ready) async {
    if (ready == _updateReady) return;
    _updateReady = ready;
    await _menu();
    if (!Platform.isLinux) await trayManager.setToolTip(ready ? 'Mochi: an update is ready' : 'Mochi');
  }

  @override
  Future<void> show(Surface surface, {Offset? petPosition, Size petSize = SurfaceSizes.pet, bool onTop = true, PixelRect? petFrame}) async {
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
        await _form(onTop: onTop, skipTaskbar: true, resizable: false, shadow: false);
        await windowManager.setMinimumSize(SurfaceSizes.petMinimum);
        // Back from the popover on Windows, the stroll has already put the window back exactly where it was.
        final window = _petWindow;
        if (window != null && petFrame != null) {
          // Exactly, in physical pixels on the display it goes to (its place there).
          await window.setFrame(petFrame);
        } else if (previous != Surface.popover || window == null) {
          await windowManager.setSize(petSize);
          if (petPosition != null) {
            await windowManager.setPosition(petPosition);
          } else {
            // Bottom left, just above the taskbar (the work area), where Windows 11 shows its widgets tile.
            await windowManager.setAlignment(Alignment.bottomLeft);
          }
        }
        // Shown without taking the focus from whatever you're typing in.
        if (previous != Surface.pet && previous != Surface.popover) await windowManager.show(inactive: true);
      case Surface.popover:
        _focusBefore = _petWindow?.focusOwner() ?? 0;
        // A flyout: over everything, not in the taskbar, its own rounded corners, with the focus.
        await _form(onTop: true, skipTaskbar: true, resizable: false, shadow: false);
        await windowManager.setMinimumSize(SurfaceSizes.petMinimum);
        // On Windows the stroll has already put the window there, exactly, in one move (so nothing in it jumps);
        // elsewhere, one move and resize here.
        if (_petWindow == null && petPosition != null) await windowManager.setBounds(petPosition & petSize);
        if (previous == Surface.hidden || previous == Surface.main) await windowManager.show();
        await windowManager.focus();
      case Surface.main:
        await _form(onTop: false, skipTaskbar: false, resizable: _resizable ?? false, shadow: true);
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
        if (_resizable != true) {
          await windowManager.setResizable(true);
          _resizable = true;
        }
        await windowManager.show();
        await windowManager.focus();
    }
  }

  bool? _onTop, _skipTaskbar, _resizable, _shadow;

  /// The window's form, changing only what differs: each of these calls makes Windows redo something (taking the
  /// taskbar's tab away repaints the taskbar, and always-on-top activates the window), and the pet and the popover
  /// share them all, so going between those two changes nothing.
  Future<void> _form({required bool onTop, required bool skipTaskbar, required bool resizable, required bool shadow}) async {
    if (_onTop != onTop) {
      await windowManager.setAlwaysOnTop(onTop);
      _onTop = onTop;
    }
    if (_skipTaskbar != skipTaskbar) {
      await windowManager.setSkipTaskbar(skipTaskbar);
      _skipTaskbar = skipTaskbar;
    }
    if (_resizable != resizable) {
      await windowManager.setResizable(resizable);
      _resizable = resizable;
    }
    if (_shadow != shadow) {
      await windowManager.setHasShadow(shadow);
      _shadow = shadow;
    }
  }

  @override
  Future<void> startDragging() => windowManager.startDragging();

  @override
  Future<void> startResizing(WindowEdge edge) => windowManager.startResizing(switch (edge) {
    WindowEdge.top => ResizeEdge.top,
    WindowEdge.bottom => ResizeEdge.bottom,
    WindowEdge.left => ResizeEdge.left,
    WindowEdge.right => ResizeEdge.right,
    WindowEdge.topLeft => ResizeEdge.topLeft,
    WindowEdge.topRight => ResizeEdge.topRight,
    WindowEdge.bottomLeft => ResizeEdge.bottomLeft,
    WindowEdge.bottomRight => ResizeEdge.bottomRight,
  });

  @override
  Future<Size?> size() async {
    try {
      return await windowManager.getSize();
    } on Object {
      return null;
    }
  }

  @override
  void onWindowResized() {
    if (_surface == Surface.main) _actions.add(ShellAction.windowResized);
  }

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
