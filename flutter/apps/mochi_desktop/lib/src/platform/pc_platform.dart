// What Ask Mochi's PC actions (lib/src/core/pc_actions.dart, W9) read and do on Windows.
//
// Windows, through dart:ffi (package:win32), on the UI thread, only when Ask Mochi is asked to:
//   EnumWindows                                     - the top-level windows, front to back
//   IsWindowVisible, GetWindowLongPtr(GWL_EXSTYLE),
//   GetWindow(GW_OWNER)                             - the windows Alt+Tab shows (no tool windows or owned dialogs)
//   DwmGetWindowAttribute(DWMWA_CLOAKED)            - not another virtual desktop's, not a suspended store app's
//   GetWindowThreadProcessId, GetCurrentProcessId   - not Mochi's own windows
//   GetClassName                                    - not the shell's four (compared, never kept)
//   GetWindowText                                   - the title, to match words against it here; it is never returned,
//                                                     logged, shown or sent anywhere
//   FindWindowEx("Windows.UI.Core.CoreWindow")      - the store app inside its ApplicationFrameHost window
//   OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION), QueryFullProcessImageName,
//   GetFileVersionInfoSize / GetFileVersionInfo / VerQueryValue - the program's name: the exe's FileDescription, or its
//                                                     file name without .exe
// To raise a window: IsIconic, ShowWindow(SW_RESTORE) only when it is minimised, SetForegroundWindow; when Windows refuses,
// AttachThreadInput to the foreground window's thread for that one call and detached again straight after. Nothing is
// ever closed, moved, minimised or resized, and no key or mouse input is ever sent to get the focus.
//
// The apps, music keys, volume and Task Scheduler tasks are the runner's (windows/runner/pc_actions.cpp and media.cpp), over
// the `mochi/system` channel: `pcListApps`, `pcLaunchApp` (an id from the last listing), `pcMediaKey`, `pcVolumeGet`,
// `pcVolumeSet`, `pcMute`, `pcListTasks` and `pcRunTask`.
//
// The macOS development build has none ([NoPcPlatform]); tests use a fake.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart';

import '../core/pc_actions.dart';

/// Ask Mochi's PC actions: the real ones on Windows, none elsewhere.
PcActions systemPcActions() => PcActionsImpl(Platform.isWindows ? WindowsPcPlatform() : const NoPcPlatform());

class WindowsPcPlatform implements PcPlatform {
  WindowsPcPlatform({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('mochi/system');

  final MethodChannel _channel;

  /// How long the runner gets to answer.
  static const Duration _patience = Duration(seconds: 30);

  /// The shell's own windows.
  static const Set<String> _shell = {'Progman', 'WorkerW', 'Shell_TrayWnd', 'Shell_SecondaryTrayWnd'};

  static final Pointer<NativeFunction<WNDENUMPROC>> _visit = Pointer.fromFunction<WNDENUMPROC>(_enumerate, 0);

  // The walk's scratch space and result, for the callback (which can't capture anything).
  static final List<PcWindow> _found = [];
  static final Map<int, ({String name, String exe})> _programs = {};
  static final Map<String, String> _descriptions = {};
  static Pointer<Int32>? _flag;
  static Pointer<Uint32>? _pid;
  static Pointer<Uint16>? _name;
  static Pointer<Uint16>? _text;
  static int _self = 0;

  // MARK: Windows

  @override
  List<PcWindow> windows() {
    _found.clear();
    _programs.clear();
    _flag = calloc<Int32>();
    _pid = calloc<Uint32>();
    _name = calloc<Uint16>(64);
    _text = calloc<Uint16>(_titleLength);
    _self = GetCurrentProcessId();
    try {
      EnumWindows(_visit, 0);
      return List.of(_found);
    } on Object {
      return const [];
    } finally {
      for (final pointer in [_flag, _pid, _name, _text]) {
        if (pointer != null) calloc.free(pointer);
      }
      _flag = null;
      _pid = null;
      _name = null;
      _text = null;
      _found.clear();
      _programs.clear();
    }
  }

  static const int _titleLength = 512;

  static int _enumerate(int hwnd, int _) {
    try {
      final window = _read(hwnd);
      if (window != null) _found.add(window);
    } on Object {
      // This window is left out.
    }
    return 1;
  }

  /// [hwnd] as a window Alt+Tab would show, with its program's name and its title (null: it isn't one).
  static PcWindow? _read(int hwnd) {
    final flag = _flag!, pid = _pid!, name = _name!, text = _text!;
    if (IsWindowVisible(hwnd) == 0) return null;
    final style = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
    final asksForButton = style & WS_EX_APPWINDOW != 0;
    if (style & WS_EX_TOOLWINDOW != 0 && !asksForButton) return null;
    if (GetWindow(hwnd, GW_OWNER) != 0 && !asksForButton) return null;
    if (DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, flag, sizeOf<Int32>()) == S_OK && flag.value != 0) return null;
    GetWindowThreadProcessId(hwnd, pid);
    if (pid.value == _self) return null;
    final length = GetClassName(hwnd, name.cast<Utf16>(), 64);
    if (length > 0 && _shell.contains(name.cast<Utf16>().toDartString())) return null;
    final size = GetWindowText(hwnd, text.cast<Utf16>(), _titleLength);
    if (size <= 0) return null;
    final title = text.cast<Utf16>().toDartString(length: size);
    final program = _program(hwnd, pid.value);
    if (program == null) return null;
    return PcWindow(hwnd: hwnd, program: program.name, exe: program.exe, title: title);
  }

  /// The name of the program that owns [hwnd] (process [pid]); a store app's window is owned by ApplicationFrameHost, so
  /// its own process is the one behind its CoreWindow child. Null when it can't be told.
  static ({String name, String exe})? _program(int hwnd, int pid) {
    var owner = pid;
    final path = _imagePath(owner);
    if (path == null) return null;
    if (path.toLowerCase().endsWith(r'\applicationframehost.exe')) {
      final inner = _coreWindowProcess(hwnd);
      if (inner == null) return null;
      owner = inner;
    }
    final known = _programs[owner];
    if (known != null) return known;
    final image = owner == pid ? path : _imagePath(owner);
    if (image == null) return null;
    final base = image.substring(image.lastIndexOf(RegExp(r'[\\/]')) + 1);
    final program = (name: _describe(image), exe: base.toLowerCase().endsWith('.exe') ? base.substring(0, base.length - 4) : base);
    _programs[owner] = program;
    return program;
  }

  static int? _coreWindowProcess(int frame) {
    final className = 'Windows.UI.Core.CoreWindow'.toNativeUtf16();
    final pid = calloc<Uint32>();
    try {
      final child = FindWindowEx(frame, 0, className, nullptr);
      if (child == 0) return null;
      GetWindowThreadProcessId(child, pid);
      return pid.value == 0 ? null : pid.value;
    } finally {
      calloc.free(className);
      calloc.free(pid);
    }
  }

  static String? _imagePath(int pid) {
    final path = calloc<Uint16>(1024);
    final size = calloc<Uint32>();
    var process = 0;
    try {
      process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
      if (process == 0) return null;
      size.value = 1024;
      if (QueryFullProcessImageName(process, 0, path.cast<Utf16>(), size) == 0) return null;
      return path.cast<Utf16>().toDartString(length: size.value);
    } finally {
      if (process != 0) CloseHandle(process);
      calloc.free(path);
      calloc.free(size);
    }
  }

  /// The program's name: the exe's FileDescription from its version info, else its file name without `.exe`.
  static String _describe(String image) {
    final known = _descriptions[image];
    if (known != null) return known;
    final base = image.substring(image.lastIndexOf(RegExp(r'[\\/]')) + 1);
    final fallback = base.toLowerCase().endsWith('.exe') ? base.substring(0, base.length - 4) : base;
    var name = '';
    try {
      name = _fileDescription(image)?.trim() ?? '';
    } on Object {
      name = '';
    }
    // Some programs describe themselves by their file name ("Notepad.exe" for Windows 11's Notepad).
    if (name.toLowerCase().endsWith('.exe')) name = name.substring(0, name.length - 4).trim();
    if (name.length > 60) name = name.substring(0, 60).trim();
    final result = name.isEmpty ? fallback : name;
    _descriptions[image] = result;
    return result;
  }

  static String? _fileDescription(String image) {
    final file = image.toNativeUtf16();
    final handle = calloc<Uint32>();
    Pointer<Uint8>? data;
    try {
      final size = GetFileVersionInfoSize(file, handle);
      if (size == 0) return null;
      data = calloc<Uint8>(size);
      if (GetFileVersionInfo(file, 0, size, data) == 0) return null;
      final languages = <String>[];
      final buffer = calloc<Pointer<Void>>();
      final length = calloc<Uint32>();
      final translation = r'\VarFileInfo\Translation'.toNativeUtf16();
      try {
        if (VerQueryValue(data, translation, buffer, length) != 0 && length.value >= 4) {
          final pair = buffer.value.cast<Uint16>().asTypedList(2);
          languages.add('${pair[0].toRadixString(16).padLeft(4, '0')}${pair[1].toRadixString(16).padLeft(4, '0')}'.toUpperCase());
        }
      } finally {
        calloc.free(translation);
      }
      languages.addAll(const ['040904B0', '040904E4', '000004B0']);
      try {
        for (final language in languages) {
          final query = '\\StringFileInfo\\$language\\FileDescription'.toNativeUtf16();
          try {
            if (VerQueryValue(data, query, buffer, length) != 0 && length.value > 1) {
              final text = buffer.value.cast<Utf16>().toDartString();
              if (text.trim().isNotEmpty) return text;
            }
          } finally {
            calloc.free(query);
          }
        }
      } finally {
        calloc.free(buffer);
        calloc.free(length);
      }
      return null;
    } finally {
      calloc.free(file);
      calloc.free(handle);
      if (data != null) calloc.free(data);
    }
  }

  @override
  bool raise(int hwnd) {
    final pid = calloc<Uint32>();
    var attached = 0;
    final me = GetCurrentThreadId();
    try {
      if (IsWindow(hwnd) == 0) return false;
      // Only a minimised window is restored (to the size it had); nothing is moved, resized or closed.
      if (IsIconic(hwnd) != 0) ShowWindow(hwnd, SW_RESTORE);
      if (SetForegroundWindow(hwnd) != 0) return true;
      // Windows refused: share the foreground window's input state for this one call. No key or mouse input is sent.
      final foreground = GetForegroundWindow();
      final other = foreground == 0 ? 0 : GetWindowThreadProcessId(foreground, pid);
      if (other != 0 && other != me && AttachThreadInput(me, other, TRUE) != 0) attached = other;
      final raised = SetForegroundWindow(hwnd) != 0;
      return raised || GetForegroundWindow() == hwnd;
    } on Object {
      return false;
    } finally {
      if (attached != 0) AttachThreadInput(me, attached, FALSE);
      calloc.free(pid);
    }
  }

  // MARK: The runner's

  Future<Map<String, Object?>?> _ask(String method, [Map<String, Object?>? arguments]) async {
    try {
      return await _channel.invokeMapMethod<String, Object?>(method, arguments).timeout(_patience);
    } on Object catch (error) {
      debugPrint('Mochi: the PC action could not be asked (${error.runtimeType})');
      return null;
    }
  }

  static bool _ok(Map<String, Object?>? answer) => answer?['status'] == 'ok';

  @override
  Future<List<PcApp>?> apps() async {
    final answer = await _ask('pcListApps');
    if (!_ok(answer)) return null;
    final list = answer!['apps'];
    if (list is! List) return null;
    return [
      for (final entry in list)
        if (entry is Map && entry['name'] is String && entry['id'] is String) PcApp(entry['name'] as String, entry['id'] as String),
    ];
  }

  @override
  Future<bool> launch(String id) async => _ok(await _ask('pcLaunchApp', {'id': id}));

  @override
  Future<bool> mediaKey(String key) async {
    try {
      return await _channel.invokeMethod<bool>('pcMediaKey', {'key': key}).timeout(_patience) ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<double?> volume() async {
    final answer = await _ask('pcVolumeGet');
    if (!_ok(answer)) return null;
    final level = answer!['level'];
    return level is num ? level.toDouble().clamp(0.0, 1.0) : null;
  }

  @override
  Future<bool> setVolume(double level) async => _ok(await _ask('pcVolumeSet', {'level': level.clamp(0.0, 1.0).toDouble()}));

  @override
  Future<bool> setMuted(bool muted) async => _ok(await _ask('pcMute', {'muted': muted}));

  @override
  Future<PcTasks> tasks() async {
    final answer = await _ask('pcListTasks');
    final status = answer?['status'];
    if (status == 'noFolder') return const PcTasks(PcTaskState.noFolder);
    if (status != 'ok') return const PcTasks(PcTaskState.failed);
    final list = answer!['tasks'];
    return PcTasks(PcTaskState.ok, [if (list is List) ...list.whereType<String>()]);
  }

  @override
  Future<PcTaskRun> runTask(String name) async {
    final answer = await _ask('pcRunTask', {'name': name});
    return switch (answer?['status']) {
      'ok' => PcTaskRun.started,
      'noFolder' => PcTaskRun.noFolder,
      'notFound' => PcTaskRun.notFound,
      _ => PcTaskRun.failed,
    };
  }
}
