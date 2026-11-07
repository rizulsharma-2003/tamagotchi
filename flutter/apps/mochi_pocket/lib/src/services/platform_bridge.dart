import 'dart:async';

import 'package:flutter/services.dart';

/// Spoken audio's turn on the phone's speaker: while Mochi reads, other sound dips (or pauses), and Mochi stops when
/// something else needs the audio (a call, another app playing).
abstract interface class AudioFocus {
  /// Asks for a transient, "others may duck" focus. False when the phone won't give it (a call is on).
  Future<bool> request();

  Future<void> abandon();

  /// Something else took the audio for good or for a while: stop talking.
  Stream<void> get lost;
}

/// Where the app can be opened to: the home-screen widget's `mochi://<place>` links and the buttons of Mochi's ongoing
/// notification (MainActivity.kt `PLACES`).
abstract final class AppPlace {
  /// The top of the home screen.
  static const String home = 'home';

  /// Claude's sessions on the computer (Open the Session; the widget's sessions).
  static const String sessions = 'sessions';

  /// Updates: everything waiting, and the week before.
  static const String updates = 'updates';
}

/// What the Android side tells the app (MainActivity.kt): the `mochi://pair` link it was opened with or that
/// arrives while it runs, where it was opened to ([AppPlace]), this phone's model, and the app's private files folder.
abstract interface class PlatformBridge {
  /// The pairing link that opened the app, once (null after the first call).
  Future<String?> initialLink();

  /// Pairing links that arrive while the app runs.
  Stream<String> get links;

  /// The [AppPlace] the app was started to, once.
  Future<String?> initialPlace();

  /// The same, when the app was already running.
  Stream<String> get places;

  /// "realme RMX3242": how the Mac lists this phone.
  Future<String> deviceName();

  /// The app's private files folder.
  Future<String?> filesDir();
}

class MethodChannelBridge implements PlatformBridge, AudioFocus {
  MethodChannelBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) _links.add(call.arguments as String);
      if (call.method == 'place' && call.arguments is String) _places.add(call.arguments as String);
      if (call.method == 'audioFocusLost') _focusLost.add(null);
    });
  }

  static const MethodChannel _channel = MethodChannel('com.insideedge.mochi/platform');
  final StreamController<String> _links = StreamController.broadcast();
  final StreamController<String> _places = StreamController.broadcast();
  final StreamController<void> _focusLost = StreamController.broadcast();

  @override
  Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('requestAudioFocus') ?? false;
    } on MissingPluginException {
      return true;
    }
  }

  @override
  Future<void> abandon() async {
    try {
      await _channel.invokeMethod<void>('abandonAudioFocus');
    } on MissingPluginException {
      // Nothing held.
    }
  }

  @override
  Stream<void> get lost => _focusLost.stream;

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
  Future<String?> initialPlace() async {
    try {
      return await _channel.invokeMethod<String>('initialPlace');
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<String> get places => _places.stream;

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
