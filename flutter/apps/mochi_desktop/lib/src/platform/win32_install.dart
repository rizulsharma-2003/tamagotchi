// "Install Mochi" on Windows (docs/SPRINT_2.md W29): the Start-menu shortcut with Mochi's AppUserModelID (COM's
// IShellLink and IPropertyStore) and the Settings › Apps entry under HKEY_CURRENT_USER. Nothing needs admin rights.
// The rules are in update/self_install.dart, tested anywhere with a fake; this file is only the Win32 calls.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../update/self_install.dart';

/// `PKEY_AppUserModel_ID`: {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5.
const String _appUserModelFormat = '{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}';
const int _appUserModelIdProperty = 5;

class Win32InstallSystem implements InstallSystem {
  @override
  void createShortcut({
    required String path,
    required String target,
    required String workingDirectory,
    required String description,
    required String appUserModelId,
  }) {
    _initializeCom();
    using((arena) {
      final link = ShellLink.createInstance();
      _check(link.setPath(target.toNativeUtf16(allocator: arena)), 'set the shortcut’s target');
      _check(link.setWorkingDirectory(workingDirectory.toNativeUtf16(allocator: arena)), 'set the shortcut’s folder');
      _check(link.setDescription(description.toNativeUtf16(allocator: arena)), 'describe the shortcut');
      _check(link.setIconLocation(target.toNativeUtf16(allocator: arena), 0), 'set the shortcut’s icon');

      final store = IPropertyStore.from(link);
      final key = _appUserModelKey(arena);
      final value = arena<PROPVARIANT>();
      value.ref.vt = VT_LPWSTR;
      // SetValue copies the string, so it can be ours (freed with the arena), not CoTaskMem's.
      value.ref.pwszVal = appUserModelId.toNativeUtf16(allocator: arena);
      _check(store.setValue(key, value), 'give the shortcut Mochi’s app id');
      _check(store.commit(), 'save the shortcut’s app id');

      final file = IPersistFile.from(link);
      _check(file.save(path.toNativeUtf16(allocator: arena), TRUE), 'save the shortcut');
    });
  }

  /// The AppUserModelID a shortcut carries (null: none), for the Windows-only test and diagnostics.
  String? shortcutAppId(String path) {
    _initializeCom();
    return using((arena) {
      final link = ShellLink.createInstance();
      final file = IPersistFile.from(link);
      if (FAILED(file.load(path.toNativeUtf16(allocator: arena), STGM_READ))) return null;
      final store = IPropertyStore.from(link);
      final value = arena<PROPVARIANT>();
      if (FAILED(store.getValue(_appUserModelKey(arena), value))) return null;
      if (value.ref.vt != VT_LPWSTR || value.ref.pwszVal == nullptr) return null;
      final text = value.ref.pwszVal.toDartString();
      PropVariantClear(value);
      return text;
    });
  }

  @override
  void writeUninstallEntry(String key, Map<String, Object> values) => using((arena) {
    final subKey = key.toNativeUtf16(allocator: arena);
    for (final MapEntry(key: name, :value) in values.entries) {
      final valueName = name.toNativeUtf16(allocator: arena);
      final int result;
      if (value is int) {
        final data = arena<Uint32>()..value = value;
        result = RegSetKeyValue(HKEY_CURRENT_USER, subKey, valueName, REG_DWORD, data, sizeOf<Uint32>());
      } else {
        final text = value.toString();
        result = RegSetKeyValue(HKEY_CURRENT_USER, subKey, valueName, REG_SZ, text.toNativeUtf16(allocator: arena), (text.length + 1) * 2);
      }
      if (result != ERROR_SUCCESS) throw InstallException("Windows didn't let Mochi add itself to Settings › Apps (error $result).");
    }
  });

  @override
  void deleteUninstallEntry(String key) => using((arena) {
    final subKey = key.toNativeUtf16(allocator: arena);
    RegDeleteTree(HKEY_CURRENT_USER, subKey);
    RegDeleteKey(HKEY_CURRENT_USER, subKey);
  });

  @override
  String? readUninstallValue(String key, String name) => using((arena) {
    final subKey = key.toNativeUtf16(allocator: arena);
    final valueName = name.toNativeUtf16(allocator: arena);
    final size = arena<Uint32>();
    if (RegGetValue(HKEY_CURRENT_USER, subKey, valueName, RRF_RT_REG_SZ, nullptr, nullptr, size) != ERROR_SUCCESS) return null;
    final data = arena<Uint8>(size.value + 2);
    if (RegGetValue(HKEY_CURRENT_USER, subKey, valueName, RRF_RT_REG_SZ, nullptr, data, size) != ERROR_SUCCESS) return null;
    return data.cast<Utf16>().toDartString();
  });

  static Pointer<PROPERTYKEY> _appUserModelKey(Arena arena) {
    final key = arena<PROPERTYKEY>();
    key.ref.fmtid.setGUID(_appUserModelFormat);
    key.ref.pid = _appUserModelIdProperty;
    return key;
  }

  /// COM on this thread (the runner initialises it on the main thread already; then this is a no-op).
  static void _initializeCom() {
    final result = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(result) && result != RPC_E_CHANGED_MODE) throw InstallException('Windows couldn’t start COM (error $result).');
  }

  static void _check(int result, String what) {
    if (FAILED(result)) throw InstallException("Windows didn't let Mochi $what (error 0x${(result & 0xFFFFFFFF).toRadixString(16)}).");
  }
}
