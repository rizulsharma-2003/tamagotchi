import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart' show Accessory, AccessorySlot, OfficeTheme, PetColor, SeasonDecor, SeasonalEvent, Wearer;
import 'package:mochi_world/mochi_world.dart' show Chattiness, FocusSettings, GameRecords, RecapSettings, RoomLayout;
import 'package:mochi_world/mochi_world.dart' as w show SeasonalSettings;

import 'hotkeys.dart';
import 'mischief.dart';
import 'notifications.dart';
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

/// Where Mochi lives (the Mac's menu-bar style, `MenuBarStyle`, on the taskbar).
enum DesktopStyle {
  /// Mochi strolls in the taskbar's empty stretches (the Mac's "Roam the menu bar").
  roam('Roams the taskbar'),

  /// Mochi stays in one spot on the taskbar and plays there (the Mac's "Play in the status item").
  spot('Plays in its spot'),

  /// Off the taskbar: the tray icon is Mochi, blinking, pulsing while Claude works and hopping when a turn completes
  /// (the Mac's "Classic icon"); the desktop pet, if it shows, stands where you leave it.
  icon('Classic tray icon');

  const DesktopStyle(this.title);
  final String title;

  bool get onTaskbar => this != icon;
}

/// Small, medium or large (the Mac's `DesktopPetSize`, and its status-item widths for the spot).
enum PetSize {
  small('Small'),
  medium('Medium'),
  large('Large');

  const PetSize(this.title);
  final String title;

  /// The desktop pet's box (logical pixels): Mochi's stage, with the window's room for a bubble above it. Medium is the
  /// size it always had; small and large follow the Mac's 84 : 116 : 156.
  double get stage => switch (this) {
    small => 104,
    medium => 144,
    large => 194,
  };

  /// How far Mochi plays either way of its spot on the taskbar, all told (logical pixels; the Mac's 40, 64 and 96-point
  /// items, less Mochi itself, and a little more for the wider taskbar).
  double get spotRoom => switch (this) {
    small => 24,
    medium => 64,
    large => 120,
  };
}

/// How the classic tray icon moves (the Mac's `MenuBarAnimation`).
enum TrayAnimation {
  off('Static'),
  subtle('Subtle'),
  full('Expressive');

  const TrayAnimation(this.title);
  final String title;
}

/// Where the desktop pet was left on one display: its window's top-left as a share of the room the display's work area
/// leaves it (0 at the left or top, 1 at the right or bottom), as the Mac keeps it.
@immutable
class PetPlace {
  const PetPlace(this.x, this.y);

  final double x;
  final double y;

  static PetPlace? fromJson(Object? json) {
    if (json is! List || json.length != 2 || !json.every((value) => value is num)) return null;
    final x = (json[0] as num).toDouble(), y = (json[1] as num).toDouble();
    if (!x.isFinite || !y.isFinite) return null;
    return PetPlace(x.clamp(0, 1), y.clamp(0, 1));
  }

  List<double> toJson() => [x, y];

  @override
  bool operator ==(Object other) => other is PetPlace && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'PetPlace($x, $y)';
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
class DesktopSettings extends ChangeNotifier implements NotificationPreferences {
  DesktopSettings(this._document, {DateTime Function()? clock}) {
    final json = _document.read() ?? const {};
    _load(json);
    final adopted = json['adoptedAt'] is String ? DateTime.tryParse(json['adoptedAt']! as String) : null;
    _adoptedAt = adopted ?? (clock ?? DateTime.now)();
    // The first launch of this version: the new fields go into the file, and Mochi's birthday is today.
    if (adopted == null || json['v'] != version) _save();
  }

  /// The file's format. Version 1 had no number (theme, the pet, phones, Ask Mochi); 2 adds the names, the look,
  /// holidays, reactions and the day Mochi arrived; 3 the companion (when he's around, and on the taskbar); 4 the Mac's
  /// notifications (quiet mode and hours, each category's animate/badge/banner/sound, sounds), naps that follow the
  /// PC, "only when I'm away" for the phones, and the global shortcuts; 5 the desktop pet's options (where Mochi lives,
  /// its spot and room, the size, always on top, clicks passing through, a place on each display, the tray icon's
  /// animation, and Patch only for interesting moments); 6 Mochi's world (Sprint 2: talking in speech bubbles, how
  /// chatty, fresh lines from Claude Haiku, growing up and the last stage announced, under the Mac's keys `speech`,
  /// `lifeStages` and `lifeStageSeen`); 7 Mochi's life, part 2 (the mini-games' records, the focus buddy's settings and the evening recap's under the Mac's
  /// keys `games`, `focus` and `recap`, the purr's sound under `hapticPurr`, the decoration on the taskbar under
  /// `seasonal.decorateMenuBar`, and the room's furniture under `room`); 8 Mischief, the Windows extras (the master
  /// switch and each extra's, under `mischief`).
  /// `roamTaskbar` is still written (whether Mochi is on the taskbar) for an older Mochi reading the file.
  static const int version = 8;

  /// The Mac's stepper for "Rests after … min without typing or clicking".
  static const int maxRestAfterMinutes = 60;

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
  bool _decorateTaskbar = true;
  int? _birthdayMonth;
  int? _birthdayDay;
  bool _pauseReactions = false;
  bool _quietMode = false;
  QuietHours _quietHours = const QuietHours();
  final Map<NotificationCategory, CategoryDelivery> _categoryDelivery = {};
  bool _soundEnabled = false;
  double _soundVolume = 0.45;
  bool _workSounds = false;
  bool _followSystem = true;
  int _restAfterMinutes = 5;
  bool _notifyOnlyWhenAway = false;
  Hotkey? _petShortcut = Hotkey.petDefault;
  Hotkey? _askShortcut = Hotkey.askDefault;
  CompanionVisibility _companionVisibility = CompanionVisibility.duringSessions;
  int _companionLingerMinutes = 10;
  int _companionSleepAfterMinutes = 6;
  bool _companionOnTaskbar = true;
  bool _autoUpdate = true;
  bool _installDeclined = false;
  DesktopStyle _petStyle = DesktopStyle.roam;
  DesktopStyle _taskbarStyle = DesktopStyle.roam;
  PetSize _petSize = PetSize.medium;
  PetSize _spotRoom = PetSize.medium;
  double? _spotX;
  bool _petOnTop = true;
  bool _petClickThrough = false;
  final Map<String, PetPlace> _petPlaces = {};
  String? _petDisplay;
  TrayAnimation _trayAnimation = TrayAnimation.subtle;
  bool _companionOnlyMoments = false;
  bool _speechEnabled = true;
  Chattiness _chattiness = Chattiness.normal;
  bool _speechFreshLines = false;
  bool _lifeStages = true;
  int _lifeStageSeen = -1;
  GameRecords _games = GameRecords();
  FocusSettings _focus = const FocusSettings();
  RecapSettings _recap = RecapSettings();
  bool _purrSound = true;
  RoomLayout _room = RoomLayout();
  MischiefSettings _mischief = const MischiefSettings();
  late DateTime _adoptedAt;

  void _load(Map<String, Object?> json) {
    bool flag(String key, bool fallback) => json[key] is bool ? json[key]! as bool : fallback;
    T? named<T extends Enum>(List<T> values, Object? name) => values.where((value) => value.name == name).firstOrNull;
    _themeMode = named(ThemeMode.values, json['theme']) ?? ThemeMode.system;
    _showPet = flag('showPet', true);
    // Before version 5 there was only "Roam along the taskbar": off is Mochi off the taskbar (the classic tray icon).
    final roam = flag('roamTaskbar', true);
    _taskbarStyle = named(DesktopStyle.values, json['taskbarStyle']) ?? DesktopStyle.roam;
    if (_taskbarStyle == DesktopStyle.icon) _taskbarStyle = DesktopStyle.roam;
    _petStyle = named(DesktopStyle.values, json['petStyle']) ?? (roam ? DesktopStyle.roam : DesktopStyle.icon);
    if (_petStyle.onTaskbar) _taskbarStyle = _petStyle;
    _petSize = named(PetSize.values, json['petSize']) ?? PetSize.medium;
    _spotRoom = named(PetSize.values, json['spotRoom']) ?? PetSize.medium;
    final spot = json['spotX'];
    _spotX = spot is num && spot.isFinite ? spot.toDouble() : null;
    _petOnTop = flag('petOnTop', true);
    _petClickThrough = flag('petClickThrough', false);
    _petPlaces.clear();
    final places = json['petPlaces'];
    if (places is Map) {
      for (final MapEntry(:key, :value) in places.entries) {
        final place = PetPlace.fromJson(value);
        if (key is String && place != null && key.isNotEmpty) _petPlaces[key] = place;
      }
    }
    _petDisplay = json['petDisplay'] is String ? json['petDisplay']! as String : null;
    _trayAnimation = named(TrayAnimation.values, json['trayAnimation']) ?? TrayAnimation.subtle;
    _companionOnlyMoments = flag('companionOnlyMoments', false);
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
    _decorateTaskbar = seasonal['decorateMenuBar'] is bool ? seasonal['decorateMenuBar']! as bool : true;
    final month = seasonal['birthdayMonth'], day = seasonal['birthdayDay'];
    final valid = month is int && day is int && month >= 1 && month <= 12 && day >= 1 && day <= daysIn(month);
    _birthdayMonth = valid ? month : null;
    _birthdayDay = valid ? day : null;
    _pauseReactions = flag('pauseReactions', false);
    _quietMode = flag('quietMode', false);
    _quietHours = QuietHours.fromJson(json['quietHours']);
    _categoryDelivery.clear();
    final saved = json['categoryDelivery'];
    if (saved is Map) {
      for (final category in NotificationCategory.values) {
        if (saved[category.name] != null) _categoryDelivery[category] = CategoryDelivery.fromJson(saved[category.name], category.defaultDelivery);
      }
    }
    // Before version 4, Notifications › On this PC had two switches: they're the animations of these categories now.
    void stillOff(NotificationCategory category) =>
        _categoryDelivery.putIfAbsent(category, () => category.defaultDelivery.copyWith(animate: false));
    if (json['celebrateFinished'] == false) stillOff(NotificationCategory.turnCompleted);
    if (json['showSnags'] == false) {
      stillOff(NotificationCategory.turnError);
      stillOff(NotificationCategory.toolFailure);
    }
    _soundEnabled = flag('soundEnabled', false);
    final volume = json['soundVolume'];
    _soundVolume = volume is num && volume.isFinite ? volume.toDouble().clamp(0, 1) : 0.45;
    _workSounds = flag('workSounds', false);
    _followSystem = flag('followSystem', true);
    _restAfterMinutes = _minutes(json['restAfterMinutes'], 5, 1, maxRestAfterMinutes);
    _notifyOnlyWhenAway = flag('notifyOnlyWhenAway', false);
    _petShortcut = _shortcut(json['petShortcut'], Hotkey.petDefault);
    _askShortcut = _shortcut(json['askShortcut'], Hotkey.askDefault);
    _companionVisibility = named(CompanionVisibility.values, json['companionVisibility']) ?? CompanionVisibility.duringSessions;
    _companionLingerMinutes = _minutes(json['companionLingerMinutes'], 10, 0, maxLingerMinutes);
    _companionSleepAfterMinutes = _minutes(json['companionSleepAfterMinutes'], 6, 1, maxSleepAfterMinutes);
    _companionOnTaskbar = flag('companionOnTaskbar', true);
    _autoUpdate = flag('autoUpdate', true);
    _installDeclined = flag('installDeclined', false);
    final speech = json['speech'] is Map ? (json['speech']! as Map).cast<String, Object?>() : const <String, Object?>{};
    _speechEnabled = speech['enabled'] is bool ? speech['enabled']! as bool : true;
    _chattiness = named(Chattiness.values, speech['chattiness']) ?? Chattiness.normal;
    // The Mac's key: there it's Apple Intelligence, here Claude Haiku. Off unless you turn it on (it runs `claude`).
    _speechFreshLines = speech['useAppleIntelligence'] is bool ? speech['useAppleIntelligence']! as bool : false;
    _lifeStages = flag('lifeStages', true);
    final seen = json['lifeStageSeen'];
    _lifeStageSeen = seen is int && seen >= -1 && seen <= 2 ? seen : -1;
    _games = GameRecords.fromJson(json['games']);
    _focus = FocusSettings.fromJson(json['focus']);
    _recap = RecapSettings.fromJson(json['recap']);
    _purrSound = flag('hapticPurr', true);
    _room = RoomLayout.fromJson(json['room']).sanitized();
    _mischief = MischiefSettings.fromJson(json['mischief']);
  }

  static int _minutes(Object? value, int fallback, int min, int max) => value is int ? value.clamp(min, max) : fallback;

  /// A saved shortcut: "Ctrl+Alt+Space", "none" (turned off), or missing (the default).
  static Hotkey? _shortcut(Object? value, Hotkey fallback) {
    if (value == 'none') return null;
    return value is String ? Hotkey.parse(value) ?? fallback : fallback;
  }

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

  /// Mochi is on the taskbar (Windows, with the taskbar at the bottom): it roams it or plays in its spot ([petStyle]).
  /// Dragging Mochi off the taskbar turns it off: Mochi stays where it's dropped and the tray icon is Mochi (the classic
  /// tray icon); turning it on again puts Mochi back the way it was on the taskbar.
  bool get roamTaskbar => _petStyle.onTaskbar;
  set roamTaskbar(bool value) => petStyle = value ? _taskbarStyle : DesktopStyle.icon;

  /// Where Mochi lives: roaming the taskbar, playing in its spot there, or off it as the classic tray icon.
  DesktopStyle get petStyle => _petStyle;
  set petStyle(DesktopStyle value) => _set(() {
    _petStyle = value;
    if (value.onTaskbar) _taskbarStyle = value;
  });

  /// How much room Mochi plays in, in its spot on the taskbar (the Mac's status-item width).
  PetSize get spotRoom => _spotRoom;
  set spotRoom(PetSize value) => _set(() => _spotRoom = value);

  /// Mochi's spot on the taskbar (its centre, logical pixels from the screen's left), where you last dragged it; null:
  /// beside the notification area, as the Mac's item sits by the clock.
  double? get spotX => _spotX;
  set spotX(double? value) => _set(() => _spotX = value == null || !value.isFinite ? null : value);

  /// The desktop pet's size (off the taskbar; on it, Mochi takes the taskbar's size).
  PetSize get petSize => _petSize;
  set petSize(PetSize value) => _set(() => _petSize = value);

  /// The desktop pet stays above other windows (off the taskbar; on it, it's always over the taskbar).
  bool get petOnTop => _petOnTop;
  set petOnTop(bool value) => _set(() => _petOnTop = value);

  /// Clicks pass through the desktop pet to whatever is under it (so it can't be dragged or petted; hide it with the
  /// shortcut or the tray menu).
  bool get petClickThrough => _petClickThrough;
  set petClickThrough(bool value) => _set(() => _petClickThrough = value);

  /// Where the desktop pet was left on each display (by its name and size), and the display it was last on.
  Map<String, PetPlace> get petPlaces => Map.unmodifiable(_petPlaces);
  String? get petDisplay => _petDisplay;

  /// The desktop pet was left at [place] on [display] (its key, [DisplayArea.key]).
  void placePet(String display, PetPlace place) => _set(() {
    _petPlaces[display] = place;
    _petDisplay = display;
  });

  /// Settings › Desktop Pet › Reset Position: bottom left on the main display again, everywhere forgotten.
  void resetPetPosition() => _set(() {
    _petPlaces.clear();
    _petDisplay = null;
    _petPosition = null;
  });

  /// How the classic tray icon moves.
  TrayAnimation get trayAnimation => _trayAnimation;
  set trayAnimation(TrayAnimation value) => _set(() => _trayAnimation = value);

  /// Patch comes to the taskbar only for interesting moments (arriving, Claude waiting for you, an error, a celebration,
  /// a moment with Mochi), then leaves again so Mochi stays compact while you work (the Mac's desktop pet).
  bool get companionOnlyMoments => _companionOnlyMoments;
  set companionOnlyMoments(bool value) => _set(() => _companionOnlyMoments = value);

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

  /// A little holiday decoration beside Patch's desk on the taskbar (the Mac's "beside the bed in the menu bar",
  /// `seasonal.decorateMenuBar`).
  bool get decorateTaskbar => _decorateTaskbar;
  set decorateTaskbar(bool value) => _set(() => _decorateTaskbar = value);

  /// The holiday settings as Mochi's world has them (the Mac's `seasonal`).
  w.SeasonalSettings get worldSeasonal =>
      w.SeasonalSettings(enabled: _holidays, birthdayMonth: _birthdayMonth, birthdayDay: _birthdayDay, decorateMenuBar: _decorateTaskbar);

  /// The holiday settings, for the calendar.
  SeasonalSettings get seasonal => SeasonalSettings(enabled: _holidays, birthdayMonth: _birthdayMonth, birthdayDay: _birthdayDay);

  /// The holiday on [date] (null: none, or holidays are off).
  SeasonalEvent? holidayOn(DateTime date) => SeasonCalendar.event(date, seasonal, mochiBirthday: _adoptedAt);

  /// What the pet wears on [date]: your choice, else the holiday's costume (a witch hat at Halloween, a flower crown
  /// for Diwali…), as on the Mac.
  Accessory? wornByPet(DateTime date) => _petAccessory ?? SeasonDecor.costume(holidayOn(date), Wearer.pet);

  /// What the companion wears on [date].
  Accessory? wornByCompanion(DateTime date) => _companionAccessory ?? SeasonDecor.costume(holidayOn(date), Wearer.companion);

  /// Mochi stops reacting to Claude's moments (no celebration, worry or wave), and nothing plays a sound or shows a
  /// Windows notification; the sessions keep updating.
  @override
  bool get pauseReactions => _pauseReactions;
  set pauseReactions(bool value) => _set(() => _pauseReactions = value);

  /// Quiet mode: no sounds and no Windows notifications until you turn it off. Animations and badges still show.
  @override
  bool get quietMode => _quietMode;
  set quietMode(bool value) => _set(() => _quietMode = value);

  /// The daily quiet window (off by default, 22:00–08:00).
  @override
  QuietHours get quietHours => _quietHours;
  set quietHours(QuietHours value) => _set(() => _quietHours = value);

  /// How [category] may reach you: your choice, else its default (banners and badges only where the category allows
  /// them).
  @override
  CategoryDelivery delivery(NotificationCategory category) {
    final chosen = _categoryDelivery[category] ?? category.defaultDelivery;
    return chosen.copyWith(banner: chosen.banner && category.allowsBanner, badge: chosen.badge && category.allowsBadge);
  }

  void setDelivery(NotificationCategory category, CategoryDelivery delivery) => _set(() => _categoryDelivery[category] = delivery);

  /// Settings › Notifications › Restore Defaults.
  void restoreDeliveryDefaults() => _set(_categoryDelivery.clear);

  /// Every category is at its default.
  bool get deliveryAtDefaults =>
      _categoryDelivery.entries.every((entry) => entry.value == entry.key.defaultDelivery);

  /// Mochi bounces and says "Claude finished!" when a turn ends (Turn completed › Animate).
  bool get celebrateFinished => delivery(NotificationCategory.turnCompleted).animate;
  set celebrateFinished(bool value) =>
      setDelivery(NotificationCategory.turnCompleted, delivery(NotificationCategory.turnCompleted).copyWith(animate: value));

  /// Mochi looks worried when a turn ends with an error or a tool reports one (API errors and Tool errors › Animate).
  bool get showSnags => delivery(NotificationCategory.turnError).animate;
  set showSnags(bool value) => _set(() {
    for (final category in const [NotificationCategory.turnError, NotificationCategory.toolFailure]) {
      _categoryDelivery[category] = delivery(category).copyWith(animate: value);
    }
  });

  /// Mochi's sounds (off by default, as on the Mac).
  @override
  bool get soundEnabled => _soundEnabled;
  set soundEnabled(bool value) => _set(() => _soundEnabled = value);

  /// 0–1.
  double get soundVolume => _soundVolume;
  set soundVolume(double value) => _set(() => _soundVolume = value.isFinite ? value.clamp(0, 1) : 0.45);

  /// Tiny keyboard taps while Claude edits or runs commands.
  @override
  bool get workSounds => _workSounds;
  set workSounds(bool value) => _set(() => _workSounds = value);

  /// Mochi sleeps while this PC rests and is awake while you work (Settings › Characters › Naps).
  bool get followSystem => _followSystem;
  set followSystem(bool value) => _set(() => _followSystem = value);

  /// Minutes without typing or clicking before the PC counts as resting (1–60).
  int get restAfterMinutes => _restAfterMinutes;
  set restAfterMinutes(int value) => _set(() => _restAfterMinutes = value.clamp(1, maxRestAfterMinutes));

  /// Claude's summaries go to the phones only while you're away from this PC.
  bool get notifyOnlyWhenAway => _notifyOnlyWhenAway;
  set notifyOnlyWhenAway(bool value) => _set(() => _notifyOnlyWhenAway = value);

  /// The global shortcut for [shortcut] (null: none).
  Hotkey? shortcut(MochiShortcut shortcut) => switch (shortcut) {
    MochiShortcut.pet => _petShortcut,
    MochiShortcut.ask => _askShortcut,
  };

  void setShortcut(MochiShortcut shortcut, Hotkey? hotkey) => _set(() {
    switch (shortcut) {
      case MochiShortcut.pet:
        _petShortcut = hotkey;
      case MochiShortcut.ask:
        _askShortcut = hotkey;
    }
  });

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

  /// Mochi and Patch say a word now and then in speech bubbles (Settings › Fun › Talking; the Mac's `speech.enabled`).
  bool get speechEnabled => _speechEnabled;
  set speechEnabled(bool value) => _set(() => _speechEnabled = value);

  /// How often they speak up: quiet (only what matters), normal or chatty.
  Chattiness get chattiness => _chattiness;
  set chattiness(Chattiness value) => _set(() => _chattiness = value);

  /// Now and then a fresh line written for the moment by Claude Haiku through Claude Code on this PC (the Mac's
  /// `speech.useAppleIntelligence`). Only the kind of moment is sent, never anything about your work.
  bool get speechFreshLines => _speechFreshLines;
  set speechFreshLines(bool value) => _set(() => _speechFreshLines = value);

  /// Mochi grows up over time: kitten, young, grown-up, as your friendship grows (Settings › Fun › Growing up).
  bool get lifeStages => _lifeStages;
  set lifeStages(bool value) => _set(() => _lifeStages = value);

  /// The last life stage Mochi announced (the Mac's `lifeStageSeen`: -1 before the first look, then 0–2).
  int get lifeStageSeen => _lifeStageSeen;
  set lifeStageSeen(int value) => _set(() => _lifeStageSeen = value.clamp(-1, 2));

  /// The mini-games' records (the Mac's `games`): high scores, best combo and win counts. A copy: change it, then set
  /// it back to save it.
  GameRecords get games => _games.copy();
  set games(GameRecords value) {
    if (value == _games) return;
    _set(() => _games = value.copy());
  }

  /// The focus buddy (the Mac's `focus`): the block and break lengths, naps, the chime and the notification at a break.
  FocusSettings get focus => _focus;
  set focus(FocusSettings value) {
    if (value == _focus) return;
    _set(() => _focus = value);
  }

  /// The evening recap (the Mac's `recap`): announced from the hour, a notification too, and the last day announced. A
  /// copy: change it, then set it back to save it.
  RecapSettings get recap => _recap.copy();
  set recap(RecapSettings value) {
    final same = value.announce == _recap.announce &&
        value.hour == _recap.hour &&
        value.banner == _recap.banner &&
        value.lastAnnouncedDay == _recap.lastAnnouncedDay;
    if (same) return;
    _set(() => _recap = value.copy());
  }

  /// A soft purr plays while you press and hold Mochi (with Mochi's sounds on; the Mac's `hapticPurr`, which purrs on
  /// its Force Touch trackpad).
  bool get purrSound => _purrSound;
  set purrSound(bool value) => _set(() => _purrSound = value);

  /// The furniture in Mochi's room (the Mac's `room`). A copy: change it, then set it back to save it.
  RoomLayout get room => _room.copy();
  set room(RoomLayout value) {
    if (jsonEncode(value.toJson()) == jsonEncode(_room.toJson())) return;
    _set(() => _room = value.copy());
  }

  /// Mischief (Settings › Mischief): the Windows extras' master switch, off at first, and each extra's own switch.
  MischiefSettings get mischief => _mischief;
  set mischief(MischiefSettings value) {
    if (value == _mischief) return;
    _set(() => _mischief = value);
  }

  /// Phone commands already handled (the newest 30), so a redelivered one never runs twice.
  bool wasHandled(String id) => _handledCommands.contains(id);

  void markHandled(String id) {
    _handledCommands.add(id);
    if (_handledCommands.length > 30) _handledCommands.removeRange(0, _handledCommands.length - 30);
    _save();
  }

  /// Settings › General › Reset: every setting back to its default. The pairing (kept in the vault, not here), the
  /// phone commands already handled, Mochi's birthday and the life stage it last announced stay.
  void reset() {
    final handled = List<String>.of(_handledCommands);
    final seen = _lifeStageSeen;
    _load(const {});
    _handledCommands.addAll(handled);
    _lifeStageSeen = seen;
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
    'roamTaskbar': roamTaskbar,
    'petStyle': _petStyle.name,
    'taskbarStyle': _taskbarStyle.name,
    'spotRoom': _spotRoom.name,
    'spotX': ?_spotX,
    'petSize': _petSize.name,
    'petOnTop': _petOnTop,
    'petClickThrough': _petClickThrough,
    if (_petPlaces.isNotEmpty) 'petPlaces': {for (final entry in _petPlaces.entries) entry.key: entry.value.toJson()},
    'petDisplay': ?_petDisplay,
    'trayAnimation': _trayAnimation.name,
    'companionOnlyMoments': _companionOnlyMoments,
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
    'seasonal': {'enabled': _holidays, 'birthdayMonth': ?_birthdayMonth, 'birthdayDay': ?_birthdayDay, 'decorateMenuBar': _decorateTaskbar},
    'pauseReactions': _pauseReactions,
    // Kept for an older Mochi reading this file: the animations of their categories.
    'celebrateFinished': celebrateFinished,
    'showSnags': showSnags,
    'quietMode': _quietMode,
    'quietHours': _quietHours.toJson(),
    'categoryDelivery': {for (final entry in _categoryDelivery.entries) entry.key.name: entry.value.toJson()},
    'soundEnabled': _soundEnabled,
    'soundVolume': _soundVolume,
    'workSounds': _workSounds,
    'followSystem': _followSystem,
    'restAfterMinutes': _restAfterMinutes,
    'notifyOnlyWhenAway': _notifyOnlyWhenAway,
    'petShortcut': _petShortcut?.label ?? 'none',
    'askShortcut': _askShortcut?.label ?? 'none',
    'companionVisibility': _companionVisibility.name,
    'companionLingerMinutes': _companionLingerMinutes,
    'companionSleepAfterMinutes': _companionSleepAfterMinutes,
    'companionOnTaskbar': _companionOnTaskbar,
    'autoUpdate': _autoUpdate,
    'installDeclined': _installDeclined,
    'speech': {'enabled': _speechEnabled, 'useAppleIntelligence': _speechFreshLines, 'chattiness': _chattiness.name},
    'lifeStages': _lifeStages,
    'lifeStageSeen': _lifeStageSeen,
    'games': _games.toJson(),
    'focus': _focus.toJson(),
    'recap': _recap.toJson(),
    'hapticPurr': _purrSound,
    'room': _room.toJson(),
    'mischief': _mischief.toJson(),
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
