// This process's processor time so far (Windows: GetProcessTimes, user plus kernel), for the development perf meter
// (ui/perf_meter.dart). Null elsewhere.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Microseconds of processor time this process has used (every thread, user and kernel), or null.
int? processCpuMicroseconds() {
  if (!Platform.isWindows) return null;
  final creation = calloc<FILETIME>();
  final exit = calloc<FILETIME>();
  final kernel = calloc<FILETIME>();
  final user = calloc<FILETIME>();
  try {
    if (GetProcessTimes(GetCurrentProcess(), creation, exit, kernel, user) == 0) return null;
    int ticks(Pointer<FILETIME> time) => (time.ref.dwHighDateTime << 32) | time.ref.dwLowDateTime;
    // 100-nanosecond units.
    return (ticks(kernel) + ticks(user)) ~/ 10;
  } finally {
    for (final pointer in [creation, exit, kernel, user]) {
      calloc.free(pointer);
    }
  }
}
