import 'dart:async';

import 'package:flutter/material.dart';

import '../services/local_file.dart';
import '../voice/mochi_voice.dart';

/// How the app looks: following the phone (the default), or always light or dark.
enum Appearance {
  system('System'),
  light('Light'),
  dark('Dark');

  const Appearance(this.title);
  final String title;

  ThemeMode get themeMode => switch (this) {
    Appearance.system => ThemeMode.system,
    Appearance.light => ThemeMode.light,
    Appearance.dark => ThemeMode.dark,
  };

  static Appearance parse(Object? name) => values.where((value) => value.name == name).firstOrNull ?? system;
}

/// This phone's own choices (not shared with the Mac): appearance, Mochi's voice, Mochi on the lock screen while
/// Claude works, and where "Check now" goes. Kept in a small file in the app's private folder (the push handler reads it too); a change applies at
/// once.
class AppSettings extends ChangeNotifier {
  AppSettings(this._document);

  final LocalDocument _document;

  Appearance _appearance = Appearance.system;
  VoiceCharacter _character = VoiceCharacter.mochi;
  String? _voiceName;
  bool _showOnLockScreen = true;
  bool _checkNowUsesCloud = true;

  Appearance get appearance => _appearance;
  VoiceCharacter get character => _character;

  /// The chosen voice's name; null picks the best English voice on the phone.
  String? get voiceName => _voiceName;

  /// "Show Mochi on my lock screen while Claude works" (the iPhone's Live Activity, as an ongoing notification). On
  /// unless you turn it off.
  bool get showOnLockScreen => _showOnLockScreen;

  /// "Check now always asks Mochi Cloud" (the iPhone's Settings › Mochi Cloud): straight to the cloud when it's set
  /// up, whether the computer is on or off; off, the computer first and the cloud only when it doesn't answer. On
  /// unless you turn it off, as on the iPhone.
  bool get checkNowUsesCloud => _checkNowUsesCloud;

  Future<void> load() async {
    final json = await _document.read();
    _appearance = Appearance.parse(json?['appearance']);
    _character = VoiceCharacter.parse(json?['voiceCharacter']);
    final voice = json?['voiceName'];
    _voiceName = voice is String && voice.isNotEmpty ? voice : null;
    _showOnLockScreen = json?['showOnLockScreen'] != false;
    _checkNowUsesCloud = json?['checkNowUsesCloud'] != false;
    notifyListeners();
  }

  set appearance(Appearance value) {
    if (value == _appearance) return;
    _appearance = value;
    _changed();
  }

  set character(VoiceCharacter value) {
    if (value == _character) return;
    _character = value;
    _changed();
  }

  set voiceName(String? value) {
    if (value == _voiceName) return;
    _voiceName = value;
    _changed();
  }

  set showOnLockScreen(bool value) {
    if (value == _showOnLockScreen) return;
    _showOnLockScreen = value;
    _changed();
  }

  set checkNowUsesCloud(bool value) {
    if (value == _checkNowUsesCloud) return;
    _checkNowUsesCloud = value;
    _changed();
  }

  void _changed() {
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      await _document.write({
        'appearance': _appearance.name,
        'voiceCharacter': _character.name,
        'voiceName': ?_voiceName,
        'showOnLockScreen': _showOnLockScreen,
        'checkNowUsesCloud': _checkNowUsesCloud,
      });
    } on Object catch (error) {
      debugPrint('Mochi: settings were not saved (${error.runtimeType})');
    }
  }
}
