// "What's on my screen?" (docs/SPRINT_2.md X17): a picture of ONE window, through PrintWindow. Called only when the user
// presses the button, with the handle the foreground memory kept (core/screen_peek.dart); never the whole screen, never on
// a timer.
//
// Win32 calls, in order:
//   IsWindow, IsWindowVisible, IsIconic          - the window is still there, showing, not minimised
//   GetWindowThreadProcessId, GetCurrentProcessId - not one of Mochi's own windows
//   GetClassName                                  - not the desktop or a taskbar (the shell's four classes)
//   DwmGetWindowAttribute(DWMWA_CLOAKED)          - not cloaked (another virtual desktop, a suspended app)
//   GetWindowRect                                 - its size (refused when empty or over 16384 px)
//   GetDC(NULL), CreateCompatibleDC, CreateDIBSection (32 bit, top down), SelectObject
//   PrintWindow(hwnd, memoryDC, PW_RENDERFULLCONTENT) - the window draws itself into the bitmap (also GPU-drawn ones)
//   OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION), QueryFullProcessImageName - the program's file name only
// Then the pixels are made opaque, scaled so the long side is at most 1600 px, and PNG-encoded by Flutter's own encoder.
// Every handle is released; the window's title is never read; nothing is logged.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../core/screen_peek.dart';

/// PrintWindow's PW_RENDERFULLCONTENT: windows that draw with the GPU (browsers, Electron) are captured too.
const int _renderFullContent = 2;

/// The most pixels on the long side of the picture that goes to Claude.
const int maxPictureSide = 1600;

WindowCapturer systemWindowCapturer() => Platform.isWindows ? Win32WindowCapturer() : const NoWindowCapturer();

class Win32WindowCapturer implements WindowCapturer {
  static const Set<String> _shell = {'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd'};

  @override
  Future<ScreenGrab> capture(int hwnd) async {
    try {
      final refused = _refuse(hwnd);
      if (refused != null) return ScreenGrab.failed(refused);
      final raw = _grab(hwnd);
      if (raw == null) return const ScreenGrab.failed(ScreenFailure.failed);
      final png = await encode(raw.bgra, raw.width, raw.height);
      if (png == null) return const ScreenGrab.failed(ScreenFailure.failed);
      return ScreenGrab.seen(png: png, app: _programName(hwnd));
    } on Object {
      return const ScreenGrab.failed(ScreenFailure.failed);
    }
  }

  /// Why [hwnd] can't be pictured (null: it can).
  static ScreenFailure? _refuse(int hwnd) {
    if (hwnd == 0 || IsWindow(hwnd) == 0 || IsWindowVisible(hwnd) == 0) return ScreenFailure.noWindow;
    final pid = calloc<Uint32>();
    final name = calloc<Uint16>(40);
    final cloaked = calloc<Uint32>();
    try {
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == GetCurrentProcessId()) return ScreenFailure.ours;
      final length = GetClassName(hwnd, name.cast<Utf16>(), 40);
      if (length > 0 && _shell.contains(name.cast<Utf16>().toDartString())) return ScreenFailure.shell;
      if (IsIconic(hwnd) != 0) return ScreenFailure.minimised;
      if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, cloaked, sizeOf<Uint32>()) == 0 && cloaked.value != 0) return ScreenFailure.cloaked;
      return null;
    } finally {
      calloc.free(pid);
      calloc.free(name);
      calloc.free(cloaked);
    }
  }

  /// The window's pixels (BGRA, top row first), or null.
  static ({Uint8List bgra, int width, int height})? _grab(int hwnd) {
    final rect = calloc<RECT>();
    final info = calloc<BITMAPINFO>();
    final bits = calloc<Pointer>();
    var screen = 0, memory = 0, bitmap = 0, previous = 0;
    try {
      if (GetWindowRect(hwnd, rect) == 0) return null;
      final width = rect.ref.right - rect.ref.left, height = rect.ref.bottom - rect.ref.top;
      if (width <= 0 || height <= 0 || width > 16384 || height > 16384) return null;
      screen = GetDC(NULL);
      if (screen == 0) return null;
      memory = CreateCompatibleDC(screen);
      if (memory == 0) return null;
      info.ref.bmiHeader
        ..biSize = sizeOf<BITMAPINFOHEADER>()
        ..biWidth = width
        ..biHeight = -height
        ..biPlanes = 1
        ..biBitCount = 32
        ..biCompression = BI_RGB;
      bitmap = CreateDIBSection(memory, info, DIB_RGB_COLORS, bits, NULL, 0);
      if (bitmap == 0 || bits.value == nullptr) return null;
      previous = SelectObject(memory, bitmap);
      if (PrintWindow(hwnd, memory, _renderFullContent) == 0) return null;
      // Copied out before the bitmap is released.
      return (bgra: Uint8List.fromList(bits.value.cast<Uint8>().asTypedList(width * height * 4)), width: width, height: height);
    } finally {
      if (previous != 0) SelectObject(memory, previous);
      if (bitmap != 0) DeleteObject(bitmap);
      if (memory != 0) DeleteDC(memory);
      if (screen != 0) ReleaseDC(NULL, screen);
      calloc.free(rect);
      calloc.free(info);
      calloc.free(bits);
    }
  }

  /// The program's file name without its folder and `.exe` ("chrome"); empty when it can't be read.
  static String _programName(int hwnd) {
    final pid = calloc<Uint32>();
    final path = calloc<Uint16>(1024);
    final size = calloc<Uint32>();
    var process = 0;
    try {
      GetWindowThreadProcessId(hwnd, pid);
      process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid.value);
      if (process == 0) return '';
      size.value = 1024;
      if (QueryFullProcessImageName(process, 0, path.cast<Utf16>(), size) == 0) return '';
      final full = path.cast<Utf16>().toDartString(length: size.value);
      return AppNames.clean(full.substring(full.lastIndexOf(RegExp(r'[\\/]')) + 1));
    } finally {
      if (process != 0) CloseHandle(process);
      calloc.free(pid);
      calloc.free(path);
      calloc.free(size);
    }
  }

  /// [bgra] made opaque, scaled so its long side is at most [maxPictureSide], as a PNG (null: it couldn't be encoded).
  static Future<Uint8List?> encode(Uint8List bgra, int width, int height) async {
    final scale = math.min(1.0, maxPictureSide / math.max(width, height));
    final opaque = bgra.buffer.asUint32List(bgra.offsetInBytes, width * height);
    // PrintWindow leaves the alpha of many windows at 0.
    for (var i = 0; i < opaque.length; i++) {
      opaque[i] |= 0xFF000000;
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      bgra,
      width,
      height,
      ui.PixelFormat.bgra8888,
      done.complete,
      targetWidth: math.max(1, (width * scale).round()),
      targetHeight: math.max(1, (height * scale).round()),
      allowUpscaling: false,
    );
    final image = await done.future;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data == null ? null : data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  }
}
