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

/// This phone's own choices (not shared with the Mac): appearance, and Mochi's voice. Kept in a small file in the
/// app's private folder; a change applies at once.
class AppSettings extends ChangeNotifier {
  AppSettings(this._document);

  final LocalDocument _document;

  Appearance _appearance = Appearance.system;
  VoiceCharacter _character = VoiceCharacter.mochi;
  String? _voiceName;

  Appearance get appearance => _appearance;
  VoiceCharacter get character => _character;

  /// The chosen voice's name; null picks the best English voice on the phone.
  String? get voiceName => _voiceName;

  Future<void> load() async {
    final json = await _document.read();
    _appearance = Appearance.parse(json?['appearance']);
    _character = VoiceCharacter.parse(json?['voiceCharacter']);
    final voice = json?['voiceName'];
    _voiceName = voice is String && voice.isNotEmpty ? voice : null;
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

  void _changed() {
    notifyListeners();
    unawaited(_save());
  }

  Future<void> _save() async {
    try {
      await _document.write({'appearance': _appearance.name, 'voiceCharacter': _character.name, 'voiceName': ?_voiceName});
    } on Object catch (error) {
      debugPrint('Mochi: settings were not saved (${error.runtimeType})');
    }
  }
}
