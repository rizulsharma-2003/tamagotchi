// Fakes for dropped files, text and links and for "What's on my screen?": the file system, the window capture, the folder
// the picture goes to, the runner's drops.

import 'dart:async';
import 'dart:typed_data';

import 'package:mochi_desktop/src/core/ask_attach.dart';
import 'package:mochi_desktop/src/core/screen_peek.dart';
import 'package:mochi_desktop/src/platform/file_drop.dart';

/// A file system of a few paths (by their exact spelling).
class FakeFileProbe implements FileProbe {
  FakeFileProbe([Map<String, FileFacts>? facts]) : facts = facts ?? {};

  final Map<String, FileFacts> facts;

  /// Every path that was looked at.
  final List<String> looked = [];

  void file(String path, [int size = 1000]) => facts[path] = FileFacts(FileKind.file, size);
  void folder(String path) => facts[path] = const FileFacts(FileKind.directory);

  @override
  FileFacts stat(String path) {
    looked.add(path);
    return facts[path] ?? const FileFacts(FileKind.missing);
  }
}

/// One window's capture, by handle; records every capture.
class FakeCapturer implements WindowCapturer {
  final Map<int, ScreenGrab> grabs = {};
  final List<int> captured = [];
  bool throws = false;

  /// Stands in for a PNG (the card shows it through Image.memory, with an error fallback).
  static final Uint8List png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3]);

  @override
  Future<ScreenGrab> capture(int hwnd) async {
    captured.add(hwnd);
    if (throws) throw StateError('no capture');
    return grabs[hwnd] ?? const ScreenGrab.failed(ScreenFailure.noWindow);
  }
}

/// The Assistant folder, in memory.
class FakeScreenshots implements ScreenshotStore {
  final Set<String> files = {};
  final List<String> written = [];
  final List<String> deleted = [];
  int sweeps = 0;
  bool failWrites = false;
  int _next = 0;

  @override
  String? write(Uint8List png) {
    if (failWrites) return null;
    final path = 'C:\\Users\\Jane\\AppData\\Local\\Mochi\\Assistant\\mochi-screen-${(_next++).toString().padLeft(32, '0')}.png';
    files.add(path);
    written.add(path);
    return path;
  }

  @override
  void delete(String path) {
    files.remove(path);
    deleted.add(path);
  }

  @override
  void sweep() {
    sweeps++;
    files.clear();
  }
}

class FakeDrops implements DropSource {
  final StreamController<DropPayload> _drops = StreamController.broadcast(sync: true);
  final StreamController<bool> _hover = StreamController.broadcast(sync: true);

  @override
  Stream<DropPayload> get drops => _drops.stream;

  @override
  Stream<bool> get hovering => _hover.stream;

  void drop(DropPayload payload) => _drops.add(payload);
  void hover(bool over) => _hover.add(over);
}
