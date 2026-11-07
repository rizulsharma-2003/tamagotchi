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

/// Where the app can be opened to (MainActivity.kt `PLACES`): the home-screen widget's `mochi://<place>` links, the
/// buttons of Mochi's ongoing notification, and hands-free (the Quick Settings tile, app shortcuts, Hey Google).
abstract final class AppPlace {
  /// The top of the home screen.
  static const String home = 'home';

  /// Claude's sessions on the computer (Open the Session; the widget's sessions).
  static const String sessions = 'sessions';

  /// Updates: everything waiting, and the week before.
  static const String updates = 'updates';

  /// Mochi listening (Talk to Mochi).
  static const String talk = 'talk';

  /// Updates, read out in Mochi's voice (What's waiting).
  static const String waiting = 'waiting';

  /// Check now.
  static const String check = 'check';

  /// The suffix on a place Hey Google asked for (`check:voice`): Mochi answers out loud.
  static const String voice = ':voice';

  /// The place and whether it was asked for by voice.
  static (String place, bool voice) parse(String raw) =>
      raw.endsWith(voice) ? (raw.substring(0, raw.length - voice.length), true) : (raw, false);
}

/// "Talk to Mochi" in Quick Settings ([PlatformBridge.talkTile]).
class TalkTileState {
  const TalkTileState({this.added = false, this.canAsk = false});

  /// It's in Quick Settings (Android tells the tile when it's added or removed).
  final bool added;

  /// Android 13+: the app can ask Android to add it.
  final bool canAsk;
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

  /// Whether "Talk to Mochi" is in Quick Settings, and whether Android can be asked to add it.
  Future<TalkTileState> talkTile();

  /// Asks Android to add "Talk to Mochi" to Quick Settings: `added`, `already`, `declined`, `unsupported` or
  /// `unavailable`.
  Future<String> addTalkTile();
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

  @override
  Future<TalkTileState> talkTile() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('talkTile') ?? const {};
      return TalkTileState(added: map['added'] == true, canAsk: map['canAsk'] == true);
    } on MissingPluginException {
      return const TalkTileState();
    }
  }

  @override
  Future<String> addTalkTile() async {
    try {
      return await _channel.invokeMethod<String>('addTalkTile') ?? 'unavailable';
    } on MissingPluginException {
      return 'unsupported';
    }
  }
}
