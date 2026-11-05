import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// Where the settings live: a JSON file in the app's private folder, or memory in tests.
abstract interface class SettingsDocument {
  Map<String, Object?>? read();
  void write(Map<String, Object?> json);
}

class FileSettingsDocument implements SettingsDocument {
  FileSettingsDocument(this.path);

  final String path;

  @override
  Map<String, Object?>? read() {
    try {
      final json = jsonDecode(File(path).readAsStringSync());
      return json is Map<String, Object?> ? json : null;
    } on Object {
      return null;
    }
  }

  @override
  void write(Map<String, Object?> json) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temporary = File('$path.tmp');
    temporary.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json), flush: true);
    temporary.renameSync(path);
  }
}

class MemorySettingsDocument implements SettingsDocument {
  MemorySettingsDocument([this.json]);

  Map<String, Object?>? json;

  @override
  Map<String, Object?>? read() => json;

  @override
  void write(Map<String, Object?> json) => this.json = json;
}

/// The app's settings (Settings window), saved as they change.
class DesktopSettings extends ChangeNotifier {
  DesktopSettings(this._document) {
    final json = _document.read() ?? const {};
    _themeMode = ThemeMode.values.where((mode) => mode.name == json['theme']).firstOrNull ?? ThemeMode.system;
    _showPet = json['showPet'] is bool ? json['showPet']! as bool : true;
    _roamTaskbar = json['roamTaskbar'] is bool ? json['roamTaskbar']! as bool : true;
    _shareSummaries = json['shareSummaries'] is bool ? json['shareSummaries']! as bool : false;
    _acceptCommands = json['acceptCommands'] is bool ? json['acceptCommands']! as bool : true;
    _model = json['model'] == 'sonnet' ? 'sonnet' : 'haiku';
    final position = json['petPosition'];
    if (position is List && position.length == 2 && position.every((value) => value is num)) {
      _petPosition = Offset((position[0] as num).toDouble(), (position[1] as num).toDouble());
    }
    final handled = json['handledCommands'];
    if (handled is List) _handledCommands.addAll(handled.whereType<String>());
  }

  final SettingsDocument _document;

  ThemeMode _themeMode = ThemeMode.system;
  bool _showPet = true;
  bool _roamTaskbar = true;
  bool _shareSummaries = false;
  bool _acceptCommands = true;
  String _model = 'haiku';
  Offset? _petPosition;
  final List<String> _handledCommands = [];

  /// System, light or dark.
  ThemeMode get themeMode => _themeMode;
  set themeMode(ThemeMode value) => _set(() => _themeMode = value);

  /// The desktop pet shows while the main window is closed.
  bool get showPet => _showPet;
  set showPet(bool value) => _set(() => _showPet = value);

  /// The desktop pet strolls along the top of the taskbar (Windows, with the taskbar at the bottom). Dragging Mochi off
  /// the taskbar turns it off, so Mochi stays where it's dropped; the tray's "Back to the taskbar" turns it on again.
  bool get roamTaskbar => _roamTaskbar;
  set roamTaskbar(bool value) => _set(() => _roamTaskbar = value);

  /// Send Claude's summaries of finished turns to the paired phones (and let the hook helper read Claude's closing
  /// message). Off by default, as on the Mac.
  bool get shareSummaries => _shareSummaries;
  set shareSummaries(bool value) => _set(() => _shareSummaries = value);

  /// Answer what you send from a phone (Ask Mochi and quick commands).
  bool get acceptCommands => _acceptCommands;
  set acceptCommands(bool value) => _set(() => _acceptCommands = value);

  /// The model Ask Mochi uses: haiku (fast) or sonnet.
  String get model => _model;
  set model(String value) => _set(() => _model = value == 'sonnet' ? 'sonnet' : 'haiku');

  /// Where you last left the desktop pet (screen coordinates).
  Offset? get petPosition => _petPosition;
  set petPosition(Offset? value) => _set(() => _petPosition = value);

  /// Phone commands already handled (the newest 30), so a redelivered one never runs twice.
  bool wasHandled(String id) => _handledCommands.contains(id);

  void markHandled(String id) {
    _handledCommands.add(id);
    if (_handledCommands.length > 30) _handledCommands.removeRange(0, _handledCommands.length - 30);
    _save();
  }

  void _set(void Function() change) {
    change();
    _save();
    notifyListeners();
  }

  void _save() {
    try {
      _document.write({
        'theme': _themeMode.name,
        'showPet': _showPet,
        'roamTaskbar': _roamTaskbar,
        'shareSummaries': _shareSummaries,
        'acceptCommands': _acceptCommands,
        'model': _model,
        if (_petPosition != null) 'petPosition': [_petPosition!.dx, _petPosition!.dy],
        'handledCommands': _handledCommands,
      });
    } on Object catch (error) {
      debugPrint('Mochi: settings could not be saved (${error.runtimeType})');
    }
  }
}
