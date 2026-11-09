// Files, text and links dropped on Mochi (docs/SPRINT_2.md X13, X14). The Windows runner (windows/runner/drop.cpp) is an OLE
// drop target on the Flutter view and tells Dart over the `mochi/drop` channel:
//
// - `hover` (bool): something Mochi can take is being dragged over it (true), or left (false). Nothing is read for this.
// - `dropped` (map): `files` (paths), `uris` (links) and `text`, read only when the drop happens.
//
// Dart only attaches what arrives to the Ask box ([AskDraft]) for the user to see, edit or remove; nothing is sent
// until Send. Nothing here is logged.

import 'dart:async';

import 'package:flutter/services.dart';

import '../core/ask_attach.dart';

abstract interface class DropSource {
  /// What was dropped.
  Stream<DropPayload> get drops;

  /// Something droppable is over Mochi's window (true) or left it (false).
  Stream<bool> get hovering;
}

class RunnerDrops implements DropSource {
  RunnerDrops({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('mochi/drop') {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final StreamController<DropPayload> _drops = StreamController.broadcast();
  final StreamController<bool> _hover = StreamController.broadcast();

  @override
  Stream<DropPayload> get drops => _drops.stream;

  @override
  Stream<bool> get hovering => _hover.stream;

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'dropped':
        if (!_drops.isClosed) _drops.add(DropPayload.fromMap(call.arguments));
      case 'hover':
        if (!_hover.isClosed) _hover.add(call.arguments == true);
    }
    return null;
  }
}
