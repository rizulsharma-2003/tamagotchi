import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart' show Accessory, AccessorySlot, OfficeTheme, PetColor, SeasonDecor, SeasonalEvent, Wearer;

import 'seasons.dart';

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

/// When the coding companion is around (the Mac's `CompanionVisibility`).
enum CompanionVisibility {
  /// While a Claude Code session is open, and a while after the last one ends.
  duringSessions('When Claude Code is active'),
  always('Always'),
  never('Never');

  const CompanionVisibility(this.title);
  final String title;
}

/// The app's settings (the Settings window), saved as they change. Every field has a safe default, so a file from an
/// older version (or a damaged one) loads with the new fields at their defaults; names follow the Mac's AppSettings.
class DesktopSettings extends ChangeNotifier {
  DesktopSettings(this._document, {DateTime Function()? clock}) {
    final json = _document.read() ?? const {};
    _load(json);
    final adopted = json['adoptedAt'] is String ? DateTime.tryParse(json['adoptedAt']! as String) : null;
    _adoptedAt = adopted ?? (clock ?? DateTime.now)();
    // The first launch of this version: the new fields go into the file, and Mochi's birthday is today.
    if (adopted == null || json['v'] != version) _save();
  }

  /// The file's format. Version 1 had no number (theme, the pet, phones, Ask Mochi); 2 adds the names, the look,
  /// holidays, reactions and the day Mochi arrived; 3 the companion (when he's around, and on the taskbar).
  static const int version = 3;

  static const String defaultPetName = 'Mochi';
  static const String defaultCompanionName = 'Patch';

  /// The longest name the phones show in full.
  static const int maxNameLength = 24;

  /// The Mac's companion steppers: how long he stays after the last session (0–120 minutes, by 5), and how long he
  /// waits before a nap (1–60 minutes).
  static const int maxLingerMinutes = 120;
  static const int maxSleepAfterMinutes = 60;

  final SettingsDocument _document;

  ThemeMode _themeMode = ThemeMode.system;
  bool _showPet = true;
  bool _roamTaskbar = true;
  bool _shareSummaries = false;
  bool _acceptCommands = true;
  String _model = 'haiku';
  Offset? _petPosition;
  Size? _mainWindowSize;
  Size? _settingsWindowSize;
  final List<String> _handledCommands = [];
  String _petName = defaultPetName;
  String _companionName = defaultCompanionName;
  PetColor _petColor = PetColor.cream;
  Accessory? _petAccessory;
  Accessory? _companionAccessory;
  Accessory? _deskAccessory = Accessory.plant;
  OfficeTheme _officeTheme = OfficeTheme.cozyDesk;
  bool _holidays = true;
  int? _birthdayMonth;
  int? _birthdayDay;
  bool _pauseReactions = false;
  bool _celebrateFinished = true;
  bool _showSnags = true;
  CompanionVisibility _companionVisibility = CompanionVisibility.duringSessions;
  int _companionLingerMinutes = 10;
  int _companionSleepAfterMinutes = 6;
  bool _companionOnTaskbar = true;
  bool _autoUpdate = true;
  bool _installDeclined = false;
  late DateTime _adoptedAt;

  void _load(Map<String, Object?> json) {
    bool flag(String key, bool fallback) => json[key] is bool ? json[key]! as bool : fallback;
    T? named<T extends Enum>(List<T> values, Object? name) => values.where((value) => value.name == name).firstOrNull;
    _themeMode = named(ThemeMode.values, json['theme']) ?? ThemeMode.system;
    _showPet = flag('showPet', true);
    _roamTaskbar = flag('roamTaskbar', true);
    _shareSummaries = flag('shareSummaries', false);
    _acceptCommands = flag('acceptCommands', true);
    _model = json['model'] == 'sonnet' ? 'sonnet' : 'haiku';
    final position = json['petPosition'];
    _petPosition = position is List && position.length == 2 && position.every((value) => value is num)
        ? Offset((position[0] as num).toDouble(), (position[1] as num).toDouble())
        : null;
    _mainWindowSize = _windowSize(json['mainWindowSize']);
    _settingsWindowSize = _windowSize(json['settingsWindowSize']);
    final handled = json['handledCommands'];
    _handledCommands
      ..clear()
      ..addAll(handled is List ? handled.whereType<String>() : const <String>[]);
    _petName = _name(json['petName'], defaultPetName);
    _companionName = _name(json['companionName'], defaultCompanionName);
    _petColor = named(PetColor.values, json['petColor']) ?? PetColor.cream;
    _petAccessory = _fits(named(Accessory.values, json['petAccessory']), AccessorySlot.wearable);
    _companionAccessory = _fits(named(Accessory.values, json['companionAccessory']), AccessorySlot.wearable);
    // A missing key is the Mac's default (the desk plant); null is "None".
    _deskAccessory = json.containsKey('deskAccessory')
        ? _fits(named(Accessory.values, json['deskAccessory']), AccessorySlot.desk)
        : Accessory.plant;
    _officeTheme = named(OfficeTheme.values, json['officeTheme']) ?? OfficeTheme.cozyDesk;
    final seasonal = json['seasonal'] is Map ? (json['seasonal']! as Map).cast<String, Object?>() : const <String, Object?>{};
    _holidays = seasonal['enabled'] is bool ? seasonal['enabled']! as bool : true;
    final month = seasonal['birthdayMonth'], day = seasonal['birthdayDay'];
    final valid = month is int && day is int && month >= 1 && month <= 12 && day >= 1 && day <= daysIn(month);
    _birthdayMonth = valid ? month : null;
    _birthdayDay = valid ? day : null;
    _pauseReactions = flag('pauseReactions', false);
    _celebrateFinished = flag('celebrateFinished', true);
    _showSnags = flag('showSnags', true);
    _companionVisibility = named(CompanionVisibility.values, json['companionVisibility']) ?? CompanionVisibility.duringSessions;
    _companionLingerMinutes = _minutes(json['companionLingerMinutes'], 10, 0, maxLingerMinutes);
    _companionSleepAfterMinutes = _minutes(json['companionSleepAfterMinutes'], 6, 1, maxSleepAfterMinutes);
    _companionOnTaskbar = flag('companionOnTaskbar', true);
    _autoUpdate = flag('autoUpdate', true);
    _installDeclined = flag('installDeclined', false);
  }

  static int _minutes(Object? value, int fallback, int min, int max) => value is int ? value.clamp(min, max) : fallback;

  static String _name(Object? value, String fallback) =>
      value is String ? value.substring(0, value.length.clamp(0, maxNameLength)) : fallback;

  static Accessory? _fits(Accessory? accessory, AccessorySlot slot) => accessory?.slot == slot ? accessory : null;

  /// Days in [month] (29 in February: a birthday on the 29th shows on the 28th in other years).
  static int daysIn(int month) => switch (month) {
    2 => 29,
    4 || 6 || 9 || 11 => 30,
    _ => 31,
  };

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

  /// Where you last left the desktop pet (screen coordinates). Null: bottom left, just above the taskbar.
  Offset? get petPosition => _petPosition;
  set petPosition(Offset? value) => _set(() => _petPosition = value);

  /// The size you last gave Mochi's window (home and pairing) and the Settings window by dragging an edge; null: the
  /// default size.
  Size? get mainWindowSize => _mainWindowSize;
  set mainWindowSize(Size? value) => _set(() => _mainWindowSize = value);
  Size? get settingsWindowSize => _settingsWindowSize;
  set settingsWindowSize(Size? value) => _set(() => _settingsWindowSize = value);

  /// A saved window size, if it's a sane one (logical pixels).
  static Size? _windowSize(Object? value) {
    if (value is! List || value.length != 2 || !value.every((v) => v is num)) return null;
    final width = (value[0] as num).toDouble(), height = (value[1] as num).toDouble();
    if (width < 200 || height < 200 || width > 10000 || height > 10000) return null;
    return Size(width, height);
  }

  /// The pet's name as typed in Settings (at most [maxNameLength] characters); [petName] is what shows.
  String get petNameText => _petName;

  /// The pet's name everywhere: the main window, the phones, Ask Mochi. Blank means the default.
  String get petName => _petName.trim().isEmpty ? defaultPetName : _petName.trim();
  set petName(String value) => _set(() => _petName = _name(value, defaultPetName));

  /// The coding companion's name as typed; [companionName] is what shows.
  String get companionNameText => _companionName;
  String get companionName => _companionName.trim().isEmpty ? defaultCompanionName : _companionName.trim();
  set companionName(String value) => _set(() => _companionName = _name(value, defaultCompanionName));

  /// The pet's coat.
  PetColor get petColor => _petColor;
  set petColor(PetColor value) => _set(() => _petColor = value);

  /// What the pet wears (none by default). Only wearables: a desk thing is refused.
  Accessory? get petAccessory => _petAccessory;
  set petAccessory(Accessory? value) => _set(() => _petAccessory = _fits(value, AccessorySlot.wearable));

  /// What the companion wears.
  Accessory? get companionAccessory => _companionAccessory;
  set companionAccessory(Accessory? value) => _set(() => _companionAccessory = _fits(value, AccessorySlot.wearable));

  /// What stands on the companion's desk (the plant by default, as on the Mac). Only desk things.
  Accessory? get deskAccessory => _deskAccessory;
  set deskAccessory(Accessory? value) => _set(() => _deskAccessory = _fits(value, AccessorySlot.desk));

  /// The room's style.
  OfficeTheme get officeTheme => _officeTheme;
  set officeTheme(OfficeTheme value) => _set(() => _officeTheme = value);

  /// Holidays (Halloween, Diwali, Christmas, New Year, Valentine's Day and birthdays) bring decorations and costumes.
  bool get holidays => _holidays;
  set holidays(bool value) => _set(() => _holidays = value);

  /// Your birthday, month (1–12) and day, or null.
  int? get birthdayMonth => _birthdayMonth;
  int? get birthdayDay => _birthdayDay;

  /// Sets your birthday ([month] null clears it); the day is kept inside the month.
  void setBirthday(int? month, int? day) => _set(() {
    if (month == null || month < 1 || month > 12) {
      _birthdayMonth = null;
      _birthdayDay = null;
    } else {
      _birthdayMonth = month;
      _birthdayDay = (day ?? 1).clamp(1, daysIn(month));
    }
  });

  /// The day Mochi came to this PC (its first launch): its birthday comes round every year.
  DateTime get adoptedAt => _adoptedAt;

  /// The holiday settings, for the calendar.
  SeasonalSettings get seasonal => SeasonalSettings(enabled: _holidays, birthdayMonth: _birthdayMonth, birthdayDay: _birthdayDay);

  /// The holiday on [date] (null: none, or holidays are off).
  SeasonalEvent? holidayOn(DateTime date) => SeasonCalendar.event(date, seasonal, mochiBirthday: _adoptedAt);

  /// What the pet wears on [date]: your choice, else the holiday's costume (a witch hat at Halloween, a flower crown
  /// for Diwali…), as on the Mac.
  Accessory? wornByPet(DateTime date) => _petAccessory ?? SeasonDecor.costume(holidayOn(date), Wearer.pet);

  /// What the companion wears on [date].
  Accessory? wornByCompanion(DateTime date) => _companionAccessory ?? SeasonDecor.costume(holidayOn(date), Wearer.companion);

  /// Mochi stops reacting to Claude's moments (no celebration, worry or wave); the sessions keep updating.
  bool get pauseReactions => _pauseReactions;
  set pauseReactions(bool value) => _set(() => _pauseReactions = value);

  /// Mochi bounces and says "Claude finished!" when a turn ends.
  bool get celebrateFinished => _celebrateFinished;
  set celebrateFinished(bool value) => _set(() => _celebrateFinished = value);

  /// Mochi looks worried and says "Claude hit a snag" when a turn ends with an error.
  bool get showSnags => _showSnags;
  set showSnags(bool value) => _set(() => _showSnags = value);

  /// When the coding companion is around: while Claude Code is active (the Mac's default), always or never.
  CompanionVisibility get companionVisibility => _companionVisibility;
  set companionVisibility(CompanionVisibility value) => _set(() => _companionVisibility = value);

  /// How long the companion stays after the last Claude Code session ends (minutes, 0–120).
  int get companionLingerMinutes => _companionLingerMinutes;
  set companionLingerMinutes(int value) => _set(() => _companionLingerMinutes = value.clamp(0, maxLingerMinutes));

  /// How long the companion goes without news from Claude before he naps at his desk (minutes, 1–60).
  int get companionSleepAfterMinutes => _companionSleepAfterMinutes;
  set companionSleepAfterMinutes(int value) => _set(() => _companionSleepAfterMinutes = value.clamp(1, maxSleepAfterMinutes));

  /// The companion keeps a little desk in the taskbar beside the pet while he's around (with "Roam along the
  /// taskbar" on).
  bool get companionOnTaskbar => _companionOnTaskbar;
  set companionOnTaskbar(bool value) => _set(() => _companionOnTaskbar = value);
  /// Settings › About › Download updates automatically: Mochi downloads and verifies a new version in the background
  /// (it's installed only when you restart Mochi, or at its next launch).
  bool get autoUpdate => _autoUpdate;
  set autoUpdate(bool value) => _set(() => _autoUpdate = value);

  /// "Not now" on the offer to install Mochi: it runs from where it is and doesn't ask again at launch (Settings ›
  /// About still offers it).
  bool get installDeclined => _installDeclined;
  set installDeclined(bool value) => _set(() => _installDeclined = value);

  /// Phone commands already handled (the newest 30), so a redelivered one never runs twice.
  bool wasHandled(String id) => _handledCommands.contains(id);

  void markHandled(String id) {
    _handledCommands.add(id);
    if (_handledCommands.length > 30) _handledCommands.removeRange(0, _handledCommands.length - 30);
    _save();
  }

  /// Settings › General › Reset: every setting back to its default. The pairing (kept in the vault, not here), the
  /// phone commands already handled and Mochi's birthday stay.
  void reset() {
    final handled = List<String>.of(_handledCommands);
    _load(const {});
    _handledCommands.addAll(handled);
    _save();
    notifyListeners();
  }

  void _set(void Function() change) {
    change();
    _save();
    notifyListeners();
  }

  /// What's saved.
  Map<String, Object?> toJson() => {
    'v': version,
    'theme': _themeMode.name,
    'showPet': _showPet,
    'roamTaskbar': _roamTaskbar,
    'shareSummaries': _shareSummaries,
    'acceptCommands': _acceptCommands,
    'model': _model,
    if (_petPosition != null) 'petPosition': [_petPosition!.dx, _petPosition!.dy],
    if (_mainWindowSize != null) 'mainWindowSize': [_mainWindowSize!.width, _mainWindowSize!.height],
    if (_settingsWindowSize != null) 'settingsWindowSize': [_settingsWindowSize!.width, _settingsWindowSize!.height],
    'handledCommands': List<String>.of(_handledCommands),
    'petName': _petName,
    'companionName': _companionName,
    'petColor': _petColor.name,
    'petAccessory': _petAccessory?.name,
    'companionAccessory': _companionAccessory?.name,
    'deskAccessory': _deskAccessory?.name,
    'officeTheme': _officeTheme.name,
    'seasonal': {'enabled': _holidays, 'birthdayMonth': ?_birthdayMonth, 'birthdayDay': ?_birthdayDay},
    'pauseReactions': _pauseReactions,
    'celebrateFinished': _celebrateFinished,
    'showSnags': _showSnags,
    'companionVisibility': _companionVisibility.name,
    'companionLingerMinutes': _companionLingerMinutes,
    'companionSleepAfterMinutes': _companionSleepAfterMinutes,
    'companionOnTaskbar': _companionOnTaskbar,
    'autoUpdate': _autoUpdate,
    'installDeclined': _installDeclined,
    'adoptedAt': _adoptedAt.toIso8601String(),
  };

  void _save() {
    try {
      _document.write(toJson());
    } on Object catch (error) {
      debugPrint('Mochi: settings could not be saved (${error.runtimeType})');
    }
  }
}
