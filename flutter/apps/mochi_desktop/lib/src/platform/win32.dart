// The few Win32 calls the Windows app needs, through dart:ffi (no plugin): DPAPI for the Link credentials and the
// "Animation effects" setting. Every function here only runs on Windows; callers check Platform.isWindows first.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// `DATA_BLOB`.
final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;

  external Pointer<Uint8> pbData;
}

typedef _CryptProtectNative =
    Int32 Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _CryptProtect =
    int Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Utf16> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _CryptUnprotectNative =
    Int32 Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      Uint32 flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _CryptUnprotect =
    int Function(
      Pointer<_DataBlob> dataIn,
      Pointer<Pointer<Utf16>> description,
      Pointer<_DataBlob> entropy,
      Pointer<Void> reserved,
      Pointer<Void> prompt,
      int flags,
      Pointer<_DataBlob> dataOut,
    );
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> memory);
typedef _SystemParametersInfoNative = Int32 Function(Uint32 action, Uint32 parameter, Pointer<Void> value, Uint32 winIni);
typedef _SystemParametersInfo = int Function(int action, int parameter, Pointer<Void> value, int winIni);

/// The Windows Data Protection API: data sealed for the signed-in Windows user on this PC. Another user, or another
/// PC (a copied file), can't open it.
abstract final class Dpapi {
  static const int _uiForbidden = 0x1;

  static final DynamicLibrary _crypt32 = DynamicLibrary.open('crypt32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final _CryptProtect _protect = _crypt32.lookupFunction<_CryptProtectNative, _CryptProtect>('CryptProtectData');
  static final _CryptUnprotect _unprotect = _crypt32.lookupFunction<_CryptUnprotectNative, _CryptUnprotect>('CryptUnprotectData');
  static final Pointer<Void> Function(Pointer<Void>) _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeNative>('LocalFree');

  /// [data] sealed with [entropy] mixed in. Throws [StateError] when Windows refuses.
  static Uint8List protect(List<int> data, {required List<int> entropy}) =>
      _call(data, entropy, (input, extra, output) => _protect(input, nullptr, extra, nullptr, nullptr, _uiForbidden, output));

  /// Opens what [protect] sealed (same user, same PC, same [entropy]). Throws [StateError] when it can't.
  static Uint8List unprotect(List<int> data, {required List<int> entropy}) =>
      _call(data, entropy, (input, extra, output) => _unprotect(input, nullptr, extra, nullptr, nullptr, _uiForbidden, output));

  static Uint8List _call(List<int> data, List<int> entropy, int Function(Pointer<_DataBlob>, Pointer<_DataBlob>, Pointer<_DataBlob>) call) {
    final input = calloc<_DataBlob>(), extra = calloc<_DataBlob>(), output = calloc<_DataBlob>();
    final inputBytes = calloc<Uint8>(data.isEmpty ? 1 : data.length), extraBytes = calloc<Uint8>(entropy.isEmpty ? 1 : entropy.length);
    try {
      inputBytes.asTypedList(data.length).setAll(0, data);
      extraBytes.asTypedList(entropy.length).setAll(0, entropy);
      input.ref
        ..cbData = data.length
        ..pbData = inputBytes;
      extra.ref
        ..cbData = entropy.length
        ..pbData = extraBytes;
      if (call(input, extra, output) == 0) throw StateError('Windows Data Protection refused');
      final result = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
      _localFree(output.ref.pbData.cast());
      return result;
    } finally {
      for (final pointer in <Pointer<NativeType>>[input, extra, output, inputBytes, extraBytes]) {
        calloc.free(pointer);
      }
    }
  }
}

/// Windows' Settings › Accessibility › Visual effects › Animation effects.
abstract final class WindowsAnimationSetting {
  static const int _getClientAreaAnimation = 0x1042;

  /// False when the user turned animation effects off (null if it can't be read).
  static bool? enabled() {
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final call = user32.lookupFunction<_SystemParametersInfoNative, _SystemParametersInfo>('SystemParametersInfoW');
      final value = calloc<Int32>();
      try {
        if (call(_getClientAreaAnimation, 0, value.cast(), 0) == 0) return null;
        return value.value != 0;
      } finally {
        calloc.free(value);
      }
    } on Object {
      return null;
    }
  }
}
