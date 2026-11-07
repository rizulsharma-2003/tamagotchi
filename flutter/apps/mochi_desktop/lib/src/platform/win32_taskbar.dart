// The taskbar stroll's Win32 calls (platform/taskbar.dart has the interfaces). Everything here runs on Windows only;
// callers go through `systemTaskbar()` and `DesktopShell.petWindow`, which give nothing elsewhere.
//
// - Where the taskbar is: SHAppBarMessage(ABM_GETTASKBARPOS) for its edge and rect, ABM_GETSTATE for auto-hide.
// - What's on it: UI Automation on `Shell_TrayWnd` (every element's bounding rectangle: the widgets tile, Start,
//   search, the app buttons, the tray, fetched in one cross-process call with a cache request), on a worker thread;
//   for the estimate when that fails, the tray's `TrayNotifyWnd` child window and Explorer's `TaskbarAl` (alignment)
//   and `TaskbarDa` (widgets) settings. Whether it's worth measuring again: the top-level app windows (EnumWindows:
//   the ones with a taskbar button, and their titles' lengths, never the titles) and the tray's rectangle.
// - The main screen: MonitorFromPoint(0, 0, MONITOR_DEFAULTTOPRIMARY), GetMonitorInfo (its rect and work area) and
//   GetDpiForMonitor (its display scale).
// - Full-screen apps and presentations: SHQueryUserNotificationState.
// - The pet's window: SetWindowPos with SWP_NOACTIVATE | SWP_NOZORDER (| SWP_NOSIZE for a step), so it never takes the
//   focus; SetWindowPos(HWND_TOPMOST) to stay over the taskbar; WS_EX_LAYERED | WS_EX_TRANSPARENT to let clicks
//   through to the taskbar except on Mochi.
// - Changing its size without a flash: a copy of the screen there (BitBlt) in a click-through layered window of its own
//   (UpdateLayeredWindow) in front of it, while the window itself is cloaked (DwmSetWindowAttribute(DWMWA_CLOAK)),
//   with DwmFlush between the steps so each is on screen before the next.
// - timeBeginPeriod(1) while the popover's transitions run.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'taskbar.dart';

/// `APPBARDATA` (shellapi.h), with its `RECT` spelled out.
final class _AppBarData extends Struct {
  @Uint32()
  external int cbSize;

  @IntPtr()
  external int hWnd;

  @Uint32()
  external int uCallbackMessage;

  @Uint32()
  external int uEdge;

  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;

  @IntPtr()
  external int lParam;
}

typedef _AppBarMessageNative = UintPtr Function(Uint32 message, Pointer<_AppBarData> data);
typedef _AppBarMessage = int Function(int message, Pointer<_AppBarData> data);
typedef _QueryNotificationStateNative = Int32 Function(Pointer<Int32> state);
typedef _QueryNotificationState = int Function(Pointer<Int32> state);

/// The taskbar and the screen, read through Win32 (each call takes microseconds, apart from SHAppBarMessage's round
/// trip to Explorer and UI Automation's walk of the taskbar, which runs on another thread).
class Win32TaskbarInfo implements TaskbarInfo {
  static const int _abmGetState = 0x4;
  static const int _abmGetTaskbarPos = 0x5;
  static const int _absAutoHide = 0x1;
  static const int _qunsBusy = 2;
  static const int _qunsRunningD3dFullScreen = 3;
  static const int _qunsPresentationMode = 4;

  static final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
  static final _AppBarMessage _appBarMessage = _shell32.lookupFunction<_AppBarMessageNative, _AppBarMessage>('SHAppBarMessage');
  static final _QueryNotificationState _queryNotificationState = _shell32
      .lookupFunction<_QueryNotificationStateNative, _QueryNotificationState>('SHQueryUserNotificationState');

  /// `Shell_TrayWnd`, found again on each reading (Explorer may have restarted).
  int _tray = 0;

  @override
  bool get available => true;

  @override
  TaskbarReading? read() {
    final data = calloc<_AppBarData>();
    final origin = calloc<POINT>();
    final info = calloc<MONITORINFO>();
    final dpiX = calloc<Uint32>();
    final dpiY = calloc<Uint32>();
    try {
      data.ref.cbSize = sizeOf<_AppBarData>();
      if (_appBarMessage(_abmGetTaskbarPos, data) == 0) return null;
      final edge = switch (data.ref.uEdge) {
        0 => TaskbarEdge.left,
        1 => TaskbarEdge.top,
        2 => TaskbarEdge.right,
        _ => TaskbarEdge.bottom,
      };
      final bounds = PixelRect(data.ref.left, data.ref.top, data.ref.right, data.ref.bottom);
      final autoHide = _appBarMessage(_abmGetState, data) & _absAutoHide != 0;
      // (0, 0) is always on the main screen.
      final monitor = MonitorFromPoint(origin.ref, MONITOR_DEFAULTTOPRIMARY);
      info.ref.cbSize = sizeOf<MONITORINFO>();
      if (monitor == 0 || GetMonitorInfo(monitor, info) == 0) return null;
      final screen = info.ref.rcMonitor;
      final work = info.ref.rcWork;
      final scale = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, dpiX, dpiY) == S_OK && dpiX.value > 0 ? dpiX.value / 96 : 1.0;
      _tray = _findWindow('Shell_TrayWnd', 0);
      return TaskbarReading(
        edge: edge,
        bounds: bounds,
        monitor: PixelRect(screen.left, screen.top, screen.right, screen.bottom),
        workArea: PixelRect(work.left, work.top, work.right, work.bottom),
        autoHide: autoHide,
        scale: scale,
        tray: _tray == 0 ? null : _windowRect(_findWindow('TrayNotifyWnd', _tray)),
        centred: _explorerSetting('TaskbarAl') != 0,
        widgets: _explorerSetting('TaskbarDa') != 0,
      );
    } on Object {
      return null;
    } finally {
      for (final pointer in <Pointer<NativeType>>[data, origin, info, dpiX, dpiY]) {
        calloc.free(pointer);
      }
    }
  }

  @override
  Future<List<PixelRect>?> buttons() async {
    final tray = _tray != 0 ? _tray : _findWindow('Shell_TrayWnd', 0);
    if (tray == 0) return null;
    try {
      return await Isolate.run(() => _automationRects(tray));
    } on Object {
      return null;
    }
  }

  /// The app windows with a taskbar button (visible, not owned or with WS_EX_APPWINDOW, not tool windows, not cloaked),
  /// with their titles' lengths (a button with a label is as wide as its title), and the tray's rectangle.
  @override
  Object? fingerprint() {
    _windows.clear();
    try {
      EnumWindows(_enumWindows, 0);
      final tray = _tray == 0 ? null : _windowRect(_findWindow('TrayNotifyWnd', _tray));
      return Object.hashAll([..._windows, tray]);
    } on Object {
      return null;
    } finally {
      _windows.clear();
    }
  }

  static final List<int> _windows = [];
  static final Pointer<NativeFunction<WNDENUMPROC>> _enumWindows = Pointer.fromFunction<WNDENUMPROC>(_visit, 0);

  static int _visit(int hwnd, int _) {
    if (IsWindowVisible(hwnd) == 0) return 1;
    final style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    if (style & WS_EX_TOOLWINDOW != 0) return 1;
    if (GetWindow(hwnd, GW_OWNER) != 0 && style & WS_EX_APPWINDOW == 0) return 1;
    final cloaked = calloc<Int32>();
    try {
      if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, cloaked, sizeOf<Int32>()) == S_OK && cloaked.value != 0) return 1;
    } finally {
      calloc.free(cloaked);
    }
    _windows
      ..add(hwnd)
      ..add(GetWindowTextLength(hwnd));
    return 1;
  }

  @override
  bool fullscreenBusy() {
    final state = calloc<Int32>();
    try {
      if (_queryNotificationState(state) != S_OK) return false;
      return state.value == _qunsBusy || state.value == _qunsRunningD3dFullScreen || state.value == _qunsPresentationMode;
    } on Object {
      return false;
    } finally {
      calloc.free(state);
    }
  }

  @override
  bool taskbarInFront() => _tray != 0 && GetForegroundWindow() == _tray;

  @override
  (int, int)? cursor() {
    final point = calloc<POINT>();
    try {
      return GetCursorPos(point) == 0 ? null : (point.ref.x, point.ref.y);
    } finally {
      calloc.free(point);
    }
  }

  /// A top-level window ([parent] 0) or a child window of class [className], or 0.
  static int _findWindow(String className, int parent) {
    final name = className.toNativeUtf16();
    try {
      return parent == 0 ? FindWindow(name, nullptr) : FindWindowEx(parent, 0, name, nullptr);
    } finally {
      calloc.free(name);
    }
  }

  static PixelRect? _windowRect(int hwnd) {
    if (hwnd == 0) return null;
    final rect = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rect) == 0) return null;
      final result = PixelRect(rect.ref.left, rect.ref.top, rect.ref.right, rect.ref.bottom);
      return result.isEmpty ? null : result;
    } finally {
      calloc.free(rect);
    }
  }

  /// A DWORD under HKCU\…\Explorer\Advanced (null if it isn't set: Windows 11's defaults, centred with widgets).
  static int? _explorerSetting(String value) {
    final key = r'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'.toNativeUtf16();
    final name = value.toNativeUtf16();
    final data = calloc<Uint32>();
    final size = calloc<Uint32>()..value = sizeOf<Uint32>();
    try {
      return RegGetValue(HKEY_CURRENT_USER, key, name, RRF_RT_REG_DWORD, nullptr, data.cast(), size) == ERROR_SUCCESS
          ? data.value
          : null;
    } finally {
      for (final pointer in <Pointer<NativeType>>[key, name, data, size]) {
        calloc.free(pointer);
      }
    }
  }
}

/// Every UI Automation element under the taskbar window [tray], as screen rectangles (runs in a worker isolate). One
/// cross-process call fetches every element with its rectangle (FindAllBuildCache with a cache request for the
/// bounding rectangle, elements not kept live), instead of a call into Explorer for each. COM objects are released
/// here, not left to finalizers.
List<PixelRect>? _automationRects(int tray) {
  final initialized = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  final held = <Pointer<COMObject>>[];
  Pointer<COMObject> out() {
    final pointer = calloc<COMObject>();
    held.add(pointer);
    return pointer;
  }

  void release(Pointer<COMObject> pointer) {
    if (pointer.ref.isNull) return;
    IUnknown(pointer)
      ..detach()
      ..release();
  }

  try {
    final automation = CUIAutomation.createInstance()..detach();
    held.add(automation.ptr);
    final root = out();
    if (FAILED(automation.elementFromHandle(tray, root.cast())) || root.ref.isNull) return null;
    final condition = out();
    if (FAILED(automation.createTrueCondition(condition.cast()))) return null;
    final found = out();
    final element = IUIAutomationElement(root)..detach();
    final request = out();
    if (FAILED(automation.createCacheRequest(request.cast())) || request.ref.isNull) return null;
    final cache = IUIAutomationCacheRequest(request)..detach();
    if (FAILED(cache.addProperty(UIA_BoundingRectanglePropertyId))) return null;
    // IUIAutomationCacheRequest::put_AutomationElementMode (vtable slot 11): AutomationElementMode_None, only the cache.
    (request.ref.vtable + 11).cast<Pointer<NativeFunction<Int32 Function(Pointer, Int32)>>>().value.asFunction<int Function(Pointer, int)>()(
      request.ref.lpVtbl,
      0,
    );
    if (FAILED(element.findAllBuildCache(TreeScope_Descendants, condition.ref.lpVtbl.cast(), request.ref.lpVtbl.cast(), found.cast())) ||
        found.ref.isNull) {
      return null;
    }
    final array = IUIAutomationElementArray(found)..detach();
    final rects = <PixelRect>[];
    final rect = calloc<RECT>();
    try {
      for (var i = 0; i < array.length; i++) {
        final item = calloc<COMObject>();
        try {
          if (FAILED(array.getElement(i, item.cast())) || item.ref.isNull) continue;
          // IUIAutomationElement::get_CachedBoundingRectangle (vtable slot 75), into memory this function owns.
          final hr = (item.ref.vtable + 75)
              .cast<Pointer<NativeFunction<Int32 Function(Pointer, Pointer<RECT>)>>>()
              .value
              .asFunction<int Function(Pointer, Pointer<RECT>)>()(item.ref.lpVtbl, rect);
          if (SUCCEEDED(hr)) rects.add(PixelRect(rect.ref.left, rect.ref.top, rect.ref.right, rect.ref.bottom));
        } finally {
          release(item);
          calloc.free(item);
        }
      }
    } finally {
      calloc.free(rect);
    }
    return rects;
  } on Object {
    return null;
  } finally {
    for (final pointer in held.reversed) {
      release(pointer);
      calloc.free(pointer);
    }
    if (initialized == S_OK || initialized == S_FALSE) CoUninitialize();
  }
}

// user32's UpdateLayeredWindow (package:win32 has only the Indirect form).
final int Function(int, int, Pointer<POINT>, Pointer<SIZE>, int, Pointer<POINT>, int, Pointer<BLENDFUNCTION>, int) _updateLayeredWindow =
    DynamicLibrary.open('user32.dll').lookupFunction<
      Int32 Function(IntPtr, IntPtr, Pointer<POINT>, Pointer<SIZE>, IntPtr, Pointer<POINT>, Uint32, Pointer<BLENDFUNCTION>, Uint32),
      int Function(int, int, Pointer<POINT>, Pointer<SIZE>, int, Pointer<POINT>, int, Pointer<BLENDFUNCTION>, int)
    >('UpdateLayeredWindow');

// winmm's timer resolution (not in package:win32).
final DynamicLibrary _winmm = DynamicLibrary.open('winmm.dll');
final int Function(int) _timeBeginPeriod = _winmm.lookupFunction<Uint32 Function(Uint32), int Function(int)>('timeBeginPeriod');
final int Function(int) _timeEndPeriod = _winmm.lookupFunction<Uint32 Function(Uint32), int Function(int)>('timeEndPeriod');

/// The Flutter window (its HWND from window_manager's `getId`), placed with SetWindowPos.
class Win32PetWindow implements PetWindow {
  Win32PetWindow(this.hwnd);

  final int hwnd;

  static const int _quiet = SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER;

  @override
  void move(int left, int top) => SetWindowPos(hwnd, 0, left, top, 0, 0, _quiet | SWP_NOSIZE);

  // A resize sends the window WM_SIZE, which waits until Flutter has drawn a frame at the new size; Flutter's UI runs
  // on this (the window's) thread, so the resize is asked for from another thread instead, and the window handles it
  // from its message loop as it would a resize with the mouse. (A move sends no WM_SIZE, so it's made right here.)
  @override
  Future<void> setFrame(PixelRect frame) {
    final hwnd = this.hwnd;
    final (left, top, width, height) = (frame.left, frame.top, frame.width, frame.height);
    return Isolate.run(() {
      SetWindowPos(hwnd, 0, left, top, width, height, _quiet);
    });
  }

  @override
  PixelRect? frame() {
    final rect = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rect) == 0) return null;
      return PixelRect(rect.ref.left, rect.ref.top, rect.ref.right, rect.ref.bottom);
    } finally {
      calloc.free(rect);
    }
  }

  @override
  void raise() =>
      SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER);

  // A layered window with WS_EX_TRANSPARENT lets the mouse through. A window made layered shows nothing until it's
  // given its opacity, so it gets that (fully opaque: Flutter's own transparency stays as it was) the first time; after
  // that only WS_EX_TRANSPARENT changes, as the pointer comes and goes.
  @override
  void setClickThrough(bool through) {
    final style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    if (through && style & WS_EX_LAYERED == 0) {
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, style | WS_EX_LAYERED);
      SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
    }
    final layered = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    final next = through ? layered | WS_EX_TRANSPARENT : layered & ~WS_EX_TRANSPARENT;
    if (next != layered) SetWindowLongPtr(hwnd, GWL_EXSTYLE, next);
  }

  @override
  int focusOwner() {
    final owner = GetForegroundWindow();
    return owner == hwnd ? 0 : owner;
  }

  @override
  void giveFocus(int window) {
    if (window == 0 || IsWindow(window) == 0 || GetForegroundWindow() != hwnd) return;
    SetForegroundWindow(window);
  }

  bool _precise = false;

  /// The picture in front of the window while it changes size (0: none), and the guard that takes it down if nothing
  /// else does.
  int _curtain = 0;
  Timer? _curtainGuard;

  @override
  bool cover() {
    if (_curtain != 0) return true;
    final rect = frame();
    if (rect == null || rect.width <= 0 || rect.height <= 0) return false;
    final (width, height) = (rect.width, rect.height);
    final screen = GetDC(NULL);
    final memory = CreateCompatibleDC(screen);
    final info = calloc<BITMAPINFO>();
    final bits = calloc<Pointer>();
    final at = calloc<POINT>();
    final origin = calloc<POINT>();
    final size = calloc<SIZE>();
    final className = 'STATIC'.toNativeUtf16();
    final title = ''.toNativeUtf16();
    var bitmap = 0, previous = 0, curtain = 0;
    try {
      info.ref.bmiHeader
        ..biSize = sizeOf<BITMAPINFOHEADER>()
        ..biWidth = width
        ..biHeight = -height
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = BI_RGB;
      bitmap = CreateDIBSection(memory, info, DIB_RGB_COLORS, bits, NULL, 0);
      if (bitmap == 0) return false;
      previous = SelectObject(memory, bitmap);
      // What's on screen there now: Mochi (and Patch) over the taskbar.
      if (BitBlt(memory, 0, 0, width, height, screen, rect.left, rect.top, SRCCOPY) == 0) return false;
      curtain = CreateWindowEx(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
        className,
        title,
        WS_POPUP,
        rect.left,
        rect.top,
        width,
        height,
        NULL,
        NULL,
        GetModuleHandle(nullptr),
        nullptr,
      );
      if (curtain == 0) return false;
      at.ref
        ..x = rect.left
        ..y = rect.top;
      size.ref
        ..cx = width
        ..cy = height;
      if (_updateLayeredWindow(curtain, screen, at, size, memory, origin, 0, nullptr, ULW_OPAQUE) == 0) {
        DestroyWindow(curtain);
        return false;
      }
      ShowWindow(curtain, SW_SHOWNOACTIVATE);
      SetWindowPos(curtain, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE);
      _curtain = curtain;
    } finally {
      if (previous != 0) SelectObject(memory, previous);
      if (bitmap != 0) DeleteObject(bitmap);
      DeleteDC(memory);
      ReleaseDC(NULL, screen);
      for (final pointer in [info, bits, at, origin, size, className, title]) {
        calloc.free(pointer);
      }
    }
    // The picture is on screen; then the window goes out of sight behind it.
    DwmFlush();
    _cloak(true);
    _curtainGuard = Timer(const Duration(seconds: 2), uncover);
    return true;
  }

  @override
  void uncover() {
    _curtainGuard?.cancel();
    _curtainGuard = null;
    if (_curtain == 0) return;
    // Flutter's frame at the new size is on screen (out of sight); the window comes back, then the picture goes.
    DwmFlush();
    _cloak(false);
    DwmFlush();
    DestroyWindow(_curtain);
    _curtain = 0;
  }

  void _cloak(bool on) {
    final value = calloc<Int32>()..value = on ? 1 : 0;
    try {
      DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, value, sizeOf<Int32>());
    } finally {
      calloc.free(value);
    }
  }

  // Since Windows 10 2004 this only changes this process's timers, and only while it's asked for (each begin has its
  // end).
  @override
  void preciseTimers(bool on) {
    if (on == _precise) return;
    _precise = on;
    on ? _timeBeginPeriod(1) : _timeEndPeriod(1);
  }

  @override
  void settle() {
    final style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    final next = style & ~(WS_EX_LAYERED | WS_EX_TRANSPARENT);
    if (next != style) SetWindowLongPtr(hwnd, GWL_EXSTYLE, next);
  }
}
