// Saving and copying a picture the app drew (the recap card, W16): never a screen capture. On Windows the picture goes on
// the clipboard as a PNG (for apps that keep its transparent corners) and as a bitmap on white (for the rest, such as
// Paint), and is saved to your Downloads folder (Windows' own Downloads, wherever you moved it), with a number added
// when the name is taken; File Explorer can then show it. Elsewhere (the macOS development build) it's saved to
// ~/Downloads and not copied.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// A picture to export: the PNG, and its pixels on white (straight RGBA, row by row from the top).
class ExportedImage {
  const ExportedImage({required this.png, required this.rgbaOnWhite, required this.width, required this.height});

  final Uint8List png;
  final Uint8List rgbaOnWhite;
  final int width;
  final int height;
}

abstract interface class ImageExport {
  /// The clipboard can take a picture here.
  bool get canCopy;

  /// Puts [image] on the clipboard; false if it couldn't.
  Future<bool> copy(ExportedImage image);

  /// Saves [png] in the Downloads folder as [name] (a number added if it's taken). The path, or null if it couldn't.
  Future<String?> save(Uint8List png, String name);

  /// Shows the saved file in the file manager.
  Future<void> reveal(String path);

  static ImageExport system({required int Function() owner}) => Platform.isWindows ? Win32ImageExport(owner: owner) : const FolderImageExport();
}

/// Saves into a Downloads folder; no clipboard (the macOS development build, and the base for Windows').
class FolderImageExport implements ImageExport {
  const FolderImageExport({this.folder});

  /// Where pictures go (null: Downloads in the home folder).
  final String? folder;

  String? get downloads {
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    return folder ?? (home == null ? null : '$home${Platform.pathSeparator}Downloads');
  }

  @override
  bool get canCopy => false;

  @override
  Future<bool> copy(ExportedImage image) async => false;

  @override
  Future<String?> save(Uint8List png, String name) async {
    final dir = downloads;
    if (dir == null) return null;
    try {
      final folder = Directory(dir);
      if (!folder.existsSync()) folder.createSync(recursive: true);
      final path = freePath(dir, name);
      await File(path).writeAsBytes(png, flush: true);
      return path;
    } on Object {
      return null;
    }
  }

  /// [name] in [dir], or "name 2.png", "name 3.png"… when it's taken.
  static String freePath(String dir, String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    final extension = dot < 0 ? '' : name.substring(dot);
    var path = '$dir${Platform.pathSeparator}$name';
    for (var n = 2; File(path).existsSync() && n < 1000; n++) {
      path = '$dir${Platform.pathSeparator}$stem $n$extension';
    }
    return path;
  }

  @override
  Future<void> reveal(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', ['/select,', path], mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.run('/usr/bin/open', ['-R', path]);
      }
    } on ProcessException {
      // Nothing to show it in.
    }
  }
}

/// Windows: the clipboard (PNG and a bitmap on white) and the user's own Downloads folder.
class Win32ImageExport extends FolderImageExport {
  Win32ImageExport({required this.owner});

  /// Mochi's window (the clipboard's owner).
  final int Function() owner;

  @override
  bool get canCopy => true;

  @override
  String? get downloads => _knownDownloads() ?? super.downloads;

  static String? _knownDownloads() {
    final id = GUIDFromString(FOLDERID_Downloads);
    final path = calloc<Pointer<Utf16>>();
    try {
      if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DEFAULT, NULL, path))) return null;
      final found = path.value.toDartString();
      CoTaskMemFree(path.value.cast());
      return found.isEmpty ? null : found;
    } on Object {
      return null;
    } finally {
      free(id);
      free(path);
    }
  }

  @override
  Future<bool> copy(ExportedImage image) async {
    if (OpenClipboard(owner()) == 0) return false;
    try {
      EmptyClipboard();
      final png = 'PNG'.toNativeUtf16();
      final pngFormat = RegisterClipboardFormat(png);
      free(png);
      final bitmap = _put(CF_DIB, dib(image));
      final named = pngFormat != 0 && _put(pngFormat, image.png);
      return bitmap || named;
    } on Object {
      return false;
    } finally {
      CloseClipboard();
    }
  }

  /// [bytes] onto the clipboard as [format] (the clipboard owns the memory once it takes it).
  static bool _put(int format, Uint8List bytes) {
    final memory = GlobalAlloc(GMEM_MOVEABLE, bytes.length);
    if (memory.address == 0) return false;
    final target = GlobalLock(memory).cast<Uint8>();
    if (target.address == 0) {
      GlobalFree(memory);
      return false;
    }
    target.asTypedList(bytes.length).setAll(0, bytes);
    GlobalUnlock(memory);
    if (SetClipboardData(format, memory.address) == 0) {
      GlobalFree(memory);
      return false;
    }
    return true;
  }

  /// A packed device-independent bitmap: a BITMAPINFOHEADER, then 32-bit BGRA rows from the bottom up.
  static Uint8List dib(ExportedImage image) {
    final w = image.width, h = image.height;
    final out = Uint8List(40 + w * h * 4);
    final header = ByteData.sublistView(out, 0, 40)
      ..setUint32(0, 40, Endian.little)
      ..setInt32(4, w, Endian.little)
      ..setInt32(8, h, Endian.little)
      ..setUint16(12, 1, Endian.little)
      ..setUint16(14, 32, Endian.little)
      ..setUint32(16, 0, Endian.little) // BI_RGB
      ..setUint32(20, w * h * 4, Endian.little);
    assert(header.lengthInBytes == 40);
    final rgba = image.rgbaOnWhite;
    for (var y = 0; y < h; y++) {
      final from = y * w * 4;
      final to = 40 + (h - 1 - y) * w * 4;
      for (var x = 0; x < w * 4; x += 4) {
        out[to + x] = rgba[from + x + 2];
        out[to + x + 1] = rgba[from + x + 1];
        out[to + x + 2] = rgba[from + x];
        out[to + x + 3] = 255;
      }
    }
    return out;
  }
}
