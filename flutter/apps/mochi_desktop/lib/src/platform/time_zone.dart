// This PC's time zone by its IANA name ("Asia/Kolkata"), as the Mac's `TimeZone.current.identifier`: Mochi Cloud's
// MOCHI_TIMEZONE (docs/SPRINT_2.md W5) says when your morning is. Windows names its zones its own way ("India Standard
// Time"), so the name comes from ICU, which ships with Windows 10 (1903) and later (icu.dll's ucal_getDefaultTimeZone,
// the IANA zone it maps the PC's zone to). Elsewhere it's the system's /etc/localtime link (the macOS build). If neither
// answers, a fixed offset ("Etc/GMT-1"), or UTC.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _DefaultZoneNative = Int32 Function(Pointer<Uint16> result, Int32 capacity, Pointer<Int32> status);
typedef _DefaultZone = int Function(Pointer<Uint16> result, int capacity, Pointer<Int32> status);

abstract final class TimeZoneName {
  /// Old names ICU still gives for a few zones, and the names Apple (and the tz database) use now.
  static const Map<String, String> renamed = {
    'Asia/Calcutta': 'Asia/Kolkata',
    'Asia/Katmandu': 'Asia/Kathmandu',
    'Asia/Saigon': 'Asia/Ho_Chi_Minh',
    'Asia/Rangoon': 'Asia/Yangon',
    'Europe/Kiev': 'Europe/Kyiv',
    'America/Godthab': 'America/Nuuk',
    'Atlantic/Faeroe': 'Atlantic/Faroe',
    'Pacific/Truk': 'Pacific/Chuuk',
    'Pacific/Ponape': 'Pacific/Pohnpei',
    'America/Buenos_Aires': 'America/Argentina/Buenos_Aires',
    'America/Indianapolis': 'America/Indiana/Indianapolis',
  };

  /// This PC's zone.
  static String current({DateTime Function()? now}) {
    final name = Platform.isWindows ? _icu() : _localtime();
    if (name != null && name.contains('/')) return renamed[name] ?? name;
    return fixed((now ?? DateTime.now)().timeZoneOffset);
  }

  /// A whole-hour offset as an IANA fixed zone (their signs are the other way round: UTC+1 is "Etc/GMT-1"); UTC when
  /// the offset isn't whole hours.
  static String fixed(Duration offset) {
    if (offset.inMinutes % 60 != 0) return 'UTC';
    final hours = offset.inHours;
    if (hours == 0) return 'UTC';
    return 'Etc/GMT${hours > 0 ? '-' : '+'}${hours.abs()}';
  }

  static String? _icu() {
    final result = calloc<Uint16>(128);
    final status = calloc<Int32>();
    try {
      final icu = DynamicLibrary.open('icu.dll');
      final zone = icu.lookupFunction<_DefaultZoneNative, _DefaultZone>('ucal_getDefaultTimeZone');
      final length = zone(result, 128, status);
      if (status.value > 0 || length <= 0 || length > 127) return null;
      return String.fromCharCodes(result.asTypedList(length));
    } on Object {
      return null;
    } finally {
      calloc.free(result);
      calloc.free(status);
    }
  }

  static String? _localtime() {
    try {
      final target = Link('/etc/localtime').targetSync();
      final at = target.indexOf('zoneinfo/');
      return at < 0 ? null : target.substring(at + 'zoneinfo/'.length);
    } on Object {
      return null;
    }
  }
}
