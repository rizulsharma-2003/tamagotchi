import 'dart:async';

import 'package:flutter/services.dart';

/// What the Android side tells the app (MainActivity.kt): the `mochi://pair` link it was opened with or that
/// arrives while it runs, this phone's model, and the app's private files folder.
abstract interface class PlatformBridge {
  /// The pairing link that opened the app, once (null after the first call).
  Future<String?> initialLink();

  /// Pairing links that arrive while the app runs.
  Stream<String> get links;

  /// "realme RMX3242": how the Mac lists this phone.
  Future<String> deviceName();

  /// The app's private files folder.
  Future<String?> filesDir();
}

class MethodChannelBridge implements PlatformBridge {
  MethodChannelBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) _links.add(call.arguments as String);
    });
  }

  static const MethodChannel _channel = MethodChannel('com.insideedge.mochi/platform');
  final StreamController<String> _links = StreamController.broadcast();

  @override
  Future<String?> initialLink() async {
    try {
      return await _channel.invokeMethod<String>('initialLink');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<String> get links => _links.stream;

  @override
  Future<String> deviceName() async {
    try {
      return await _channel.invokeMethod<String>('deviceName') ?? 'Android phone';
    } on MissingPluginException {
      return 'Android phone';
    }
  }

  @override
  Future<String?> filesDir() async {
    try {
      return await _channel.invokeMethod<String>('filesDir');
    } on MissingPluginException {
      return null;
    }
  }
}
