// What's behind Settings: the settings file (version 1 files load with safe defaults, nothing invalid gets in), the
// holiday calendar, "Start Mochi with Windows" against an in-memory registry, Mochi's reactions as Settings allows,
// the look the phones get, and the pet's name kept safe for claude's command line.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_desktop/src/core/ask_mochi.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/core/seasons.dart';
import 'package:mochi_desktop/src/link/phone_sync.dart';
import 'package:mochi_desktop/src/platform/startup.dart';

import 'package:win32/win32.dart' hide Size, Point, Rect;

import 'support/fakes.dart';

/// Points both of the startup item's keys at one scratch key, so the Run key is never touched.
class _Scratch implements StartupRegistry {
  _Scratch(this.inner, this.key);

  final StartupRegistry inner;
  final String key;

  String _name(String key, String name) => key == RunKeyStartup.approvedKey ? 'Approved' : name;

  @override
  String? readString(String key, String name) => inner.readString(this.key, _name(key, name));

  @override
  List<int>? readBinary(String key, String name) => inner.readBinary(this.key, _name(key, name));

  @override
  void writeString(String key, String name, String value) => inner.writeString(this.key, _name(key, name), value);

  @override
  void delete(String key, String name) => inner.delete(this.key, _name(key, name));
}

void main() {
  final launch = DateTime(2026, 11, 5, 9);

  group('DesktopSettings', () {
    test('a version 1 file keeps what it had and gets every new field at its default, saved once', () {
      final document = MemorySettingsDocument({
        'theme': 'dark',
        'showPet': false,
        'roamTaskbar': false,
        'shareSummaries': true,
        'acceptCommands': false,
        'model': 'sonnet',
        'petPosition': [12, 34],
        'handledCommands': ['c1', 'c2'],
      });
      final settings = DesktopSettings(document, clock: () => launch);
      expect(
        (settings.themeMode, settings.showPet, settings.roamTaskbar, settings.shareSummaries, settings.acceptCommands, settings.model),
        (ThemeMode.dark, false, false, true, false, 'sonnet'),
      );
      expect(settings.petPosition, const Offset(12, 34));
      expect(settings.wasHandled('c2'), isTrue);
      expect((settings.petName, settings.companionName, settings.petColor), ('Mochi', 'Patch', PetColor.cream));
      expect((settings.petAccessory, settings.companionAccessory, settings.deskAccessory), (null, null, Accessory.plant));
      expect((settings.officeTheme, settings.holidays, settings.birthdayMonth), (OfficeTheme.cozyDesk, true, null));
      expect((settings.pauseReactions, settings.celebrateFinished, settings.showSnags), (false, true, true));
      expect(settings.adoptedAt, launch);
      expect(document.json!['v'], DesktopSettings.version);
      expect(document.json!['adoptedAt'], launch.toIso8601String());
      expect(document.json!['theme'], 'dark', reason: 'the old fields are kept');
      expect(document.json!['handledCommands'], ['c1', 'c2']);
    });

    test('a version 2 file reads back as it was saved', () {
      final first = DesktopSettings(MemorySettingsDocument(), clock: () => launch)
        ..petName = 'Biscuit'
        ..companionName = 'Byte'
        ..petColor = PetColor.midnight
        ..petAccessory = Accessory.witchHat
        ..companionAccessory = Accessory.headphones
        ..deskAccessory = null
        ..officeTheme = OfficeTheme.gardenOffice
        ..holidays = false
        ..pauseReactions = true
        ..celebrateFinished = false
        ..showSnags = false
        ..setBirthday(2, 29);
      final again = DesktopSettings(MemorySettingsDocument(first.toJson()), clock: () => DateTime(2030));
      expect((again.petName, again.companionName, again.petColor), ('Biscuit', 'Byte', PetColor.midnight));
      expect((again.petAccessory, again.companionAccessory, again.deskAccessory), (Accessory.witchHat, Accessory.headphones, null));
      expect((again.officeTheme, again.holidays, again.birthdayMonth, again.birthdayDay), (OfficeTheme.gardenOffice, false, 2, 29));
      expect((again.pauseReactions, again.celebrateFinished, again.showSnags), (true, false, false));
      expect(again.adoptedAt, launch, reason: 'the birthday stays');
    });

    test('nothing invalid gets in: unknown names, the wrong slot, a 31st of April, long names, a blank name', () {
      final settings = DesktopSettings(
        MemorySettingsDocument({
          'v': 2,
          'adoptedAt': launch.toIso8601String(),
          'petColor': 'plaid',
          'petAccessory': 'plant',
          'companionAccessory': 42,
          'deskAccessory': 'partyHat',
          'officeTheme': 'moonBase',
          'seasonal': {'enabled': 'yes', 'birthdayMonth': 4, 'birthdayDay': 31},
          'petName': 'A name much longer than twenty-four characters',
        }),
      );
      expect((settings.petColor, settings.petAccessory, settings.companionAccessory), (PetColor.cream, null, null));
      expect(settings.deskAccessory, isNull, reason: 'a hat isn’t a desk thing');
      expect((settings.officeTheme, settings.holidays, settings.birthdayMonth), (OfficeTheme.cozyDesk, true, null));
      expect(settings.petNameText.length, DesktopSettings.maxNameLength);
      expect(settings.petName, 'A name much longer than', reason: 'shown without the space it was cut at');
      settings
        ..petName = '   '
        ..petAccessory = Accessory.trophy
        ..deskAccessory = Accessory.scarf;
      expect(settings.petName, 'Mochi', reason: 'a blank name shows the default');
      expect((settings.petAccessory, settings.deskAccessory), (null, null));
      settings.setBirthday(4, 31);
      expect((settings.birthdayMonth, settings.birthdayDay), (4, 30));
      settings.setBirthday(null, 3);
      expect((settings.birthdayMonth, settings.birthdayDay), (null, null));
    });

    test('Reset puts every setting back but keeps the handled commands and the birthday', () {
      final document = MemorySettingsDocument();
      final settings = DesktopSettings(document, clock: () => launch)
        ..themeMode = ThemeMode.light
        ..petName = 'Biscuit'
        ..petColor = PetColor.sky
        ..showPet = false
        ..petPosition = const Offset(1, 2)
        ..markHandled('c9');
      var changes = 0;
      settings
        ..addListener(() => changes++)
        ..reset();
      expect(changes, 1);
      expect((settings.themeMode, settings.petName, settings.petColor, settings.showPet), (ThemeMode.system, 'Mochi', PetColor.cream, true));
      expect(settings.petPosition, isNull);
      expect(settings.wasHandled('c9'), isTrue);
      expect(settings.adoptedAt, launch);
      expect(document.json!['petName'], 'Mochi');
    });

    test("what the pet wears: your choice, else the holiday's costume", () {
      final settings = DesktopSettings(MemorySettingsDocument(), clock: () => DateTime(2025, 1, 1));
      expect(settings.wornByPet(DateTime(2026, 10, 31)), Accessory.witchHat);
      expect(settings.wornByPet(DateTime(2026, 11, 7)), Accessory.flowerCrown);
      expect(settings.wornByCompanion(DateTime(2026, 12, 24)), Accessory.santaHat);
      expect(settings.wornByPet(DateTime(2026, 3, 3)), isNull);
      settings.petAccessory = Accessory.beanie;
      expect(settings.wornByPet(DateTime(2026, 10, 31)), Accessory.beanie);
      settings
        ..petAccessory = null
        ..holidays = false;
      expect(settings.wornByPet(DateTime(2026, 10, 31)), isNull);
    });
  });

  group('SeasonCalendar', () {
    const on = SeasonalSettings();

    test('the festivals’ windows', () {
      expect(SeasonCalendar.event(DateTime(2026, 11, 5), on), SeasonalEvent.diwali, reason: 'three days before the 8th');
      expect(SeasonCalendar.event(DateTime(2026, 11, 10), on), SeasonalEvent.diwali);
      expect(SeasonCalendar.event(DateTime(2026, 11, 11), on), isNull);
      expect(SeasonCalendar.event(DateTime(2026, 10, 24), on), SeasonalEvent.halloween);
      expect(SeasonCalendar.event(DateTime(2026, 11, 1), on), SeasonalEvent.halloween);
      expect(SeasonCalendar.event(DateTime(2026, 12, 18), on), SeasonalEvent.christmas);
      expect(SeasonCalendar.event(DateTime(2026, 12, 31), on), SeasonalEvent.newYear);
      expect(SeasonCalendar.event(DateTime(2027, 2, 14), on), SeasonalEvent.valentines);
      expect(SeasonCalendar.event(DateTime(2031, 11, 1), on), SeasonalEvent.halloween, reason: 'no Diwali date for 2031');
      expect(SeasonCalendar.event(DateTime(2026, 10, 31), const SeasonalSettings(enabled: false)), isNull);
    });

    test('birthdays come first; the pet’s only from its first anniversary; 29 February on the 28th', () {
      const birthday = SeasonalSettings(birthdayMonth: 11, birthdayDay: 7);
      expect(SeasonCalendar.event(DateTime(2026, 11, 7), birthday), SeasonalEvent.userBirthday, reason: 'over Diwali');
      final adopted = DateTime(2025, 11, 9);
      expect(SeasonCalendar.event(DateTime(2025, 11, 9), on, mochiBirthday: adopted), isNot(SeasonalEvent.mochiBirthday));
      expect(SeasonCalendar.event(DateTime(2026, 11, 9), on, mochiBirthday: adopted), SeasonalEvent.mochiBirthday);
      const leap = SeasonalSettings(birthdayMonth: 2, birthdayDay: 29);
      expect(SeasonCalendar.event(DateTime(2027, 2, 28), leap), SeasonalEvent.userBirthday);
      expect(SeasonCalendar.event(DateTime(2028, 2, 28), leap), isNull);
      expect(SeasonCalendar.event(DateTime(2028, 2, 29), leap), SeasonalEvent.userBirthday);
    });

    test('what’s next and until when', () {
      final next = SeasonCalendar.nextEvent(DateTime(2026, 11, 5), on)!;
      expect((next.event, next.starts), (SeasonalEvent.christmas, DateTime(2026, 12, 18)));
      expect(SeasonCalendar.lastDay(SeasonalEvent.diwali, DateTime(2026, 11, 5), on), DateTime(2026, 11, 10));
      expect(SeasonCalendar.title(SeasonalEvent.mochiBirthday, petName: 'Biscuit'), "Biscuit's birthday");
    });
  });

  group('Start Mochi with Windows (the Run key)', () {
    late MemoryStartupRegistry registry;
    late RunKeyStartup startup;
    const exe = r'C:\Program Files\Mochi\mochi_desktop.exe';

    setUp(() {
      registry = MemoryStartupRegistry();
      startup = RunKeyStartup(registry: registry, executable: exe);
    });

    test('on: the quoted exe under Run, and Task Manager’s off mark cleared; off: gone', () {
      registry.keys[RunKeyStartup.approvedKey] = {'Mochi': const [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]};
      expect(startup.status(), const StartupStatus(enabled: false));
      expect(startup.setEnabled(true), isNull);
      expect(registry.keys[RunKeyStartup.runKey]!['Mochi'], '"$exe"');
      expect(registry.keys[RunKeyStartup.approvedKey], isEmpty);
      expect(startup.status(), const StartupStatus(enabled: true));
      expect(startup.setEnabled(false), isNull);
      expect(registry.keys[RunKeyStartup.runKey], isEmpty);
      expect(startup.status().enabled, isFalse);
    });

    test('says when Task Manager turned it off, or when it starts another copy', () {
      registry.keys[RunKeyStartup.runKey] = {'Mochi': '"$exe"'};
      registry.keys[RunKeyStartup.approvedKey] = {'Mochi': const [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]};
      expect(startup.status().enabled, isFalse);
      expect(startup.status().note, contains('Task Manager'));
      registry.keys[RunKeyStartup.approvedKey] = {'Mochi': const [2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]};
      expect(startup.status(), const StartupStatus(enabled: true));
      registry.keys[RunKeyStartup.runKey] = {'Mochi': r'"D:\Old\mochi_desktop.exe" --quiet'};
      expect(startup.status().enabled, isTrue);
      expect(startup.status().note, contains(r'D:\Old\mochi_desktop.exe'));
      registry.keys[RunKeyStartup.runKey] = {'Mochi': r'c:\program files\mochi\MOCHI_DESKTOP.EXE'};
      expect(startup.status().note, isNull, reason: 'paths compare without case, quotes or not');
    });

    test('a refusal comes back in words, and nothing else changes', () {
      registry.refuse = true;
      expect(startup.setEnabled(true), 'Access is denied.');
      expect(registry.keys, isEmpty);
    });

    test('the real registry (Windows only): a scratch key, never the Run key', () {
      const key = r'Software\Mochi Desktop Tests\Startup';
      final win32 = Win32StartupRegistry();
      expect(win32.readString(key, 'Mochi'), isNull);
      expect(win32.readBinary(key, 'Mochi'), isNull);
      win32.writeString(key, 'Mochi', '"C:\\Program Files\\Mochi\\mochi_desktop.exe"');
      expect(win32.readString(key, 'Mochi'), '"C:\\Program Files\\Mochi\\mochi_desktop.exe"');
      using((arena) {
        final bytes = arena<Uint8>(12)..asTypedList(12).setAll(0, [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        RegSetKeyValue(HKEY_CURRENT_USER, key.toNativeUtf16(allocator: arena), 'Approved'.toNativeUtf16(allocator: arena), REG_BINARY, bytes, 12);
      });
      expect(win32.readBinary(key, 'Approved'), [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      final item = RunKeyStartup(registry: _Scratch(win32, key), executable: r'C:\Program Files\Mochi\mochi_desktop.exe');
      expect(item.status().enabled, isFalse, reason: 'the scratch "Task Manager" mark is odd');
      win32
        ..delete(key, 'Mochi')
        ..delete(key, 'Approved')
        ..delete(key, 'Mochi');
      expect(win32.readString(key, 'Mochi'), isNull);
      using((arena) => RegDeleteKey(HKEY_CURRENT_USER, r'Software\Mochi Desktop Tests\Startup'.toNativeUtf16(allocator: arena)));
      using((arena) => RegDeleteKey(HKEY_CURRENT_USER, r'Software\Mochi Desktop Tests'.toNativeUtf16(allocator: arena)));
    }, skip: Platform.isWindows ? false : 'the registry is on Windows only');

    test('elsewhere there is no startup item', () {
      const none = UnsupportedStartup();
      expect(none.supported, isFalse);
      expect(none.setEnabled(true), isNotNull);
      expect(none.status().enabled, isFalse);
    });
  });

  group('Reactions and the look', () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make(clock: () => launch));
    tearDown(() => t.dispose());

    Future<List<PetCue>> cuesFor(void Function() events) async {
      final cues = <PetCue>[];
      final subscription = t.desktop.cues.listen(cues.add);
      await t.desktop.start();
      events();
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      return cues;
    }

    void turn(String session, String end) {
      t.desktop.sessions
        ..apply(hook('UserPromptSubmit', session: session, at: launch))
        ..apply(hook(end, session: session, at: launch));
    }

    test('Claude’s moments reach Mochi as Settings allows', () async {
      t.desktop.settings.celebrateFinished = false;
      final cues = await cuesFor(() {
        turn('a', 'Stop');
        turn('b', 'StopFailure');
        t.desktop.sessions.apply(hook('Notification', session: 'c', notificationType: 'permission_prompt', at: launch));
      });
      expect(cues, [PetCue.snag, PetCue.needsYou]);
    });

    test('Pause all reactions stops them all', () async {
      t.desktop.settings.pauseReactions = true;
      final cues = await cuesFor(() {
        turn('a', 'Stop');
        t.desktop.sessions.apply(hook('Notification', session: 'c', notificationType: 'permission_prompt', at: launch));
      });
      expect(cues, isEmpty);
    });

    test('the phones get the names, the coat, what they wear, the room and the holidays', () {
      t.desktop.settings
        ..petName = 'Biscuit'
        ..companionName = 'Byte'
        ..petColor = PetColor.peach
        ..petAccessory = Accessory.flowerCrown
        ..deskAccessory = null
        ..officeTheme = OfficeTheme.cyberpunk
        ..setBirthday(7, 4);
      final look = petLook(t.desktop.settings);
      expect((look.petName, look.companionName, look.petColor, look.petAccessory), ('Biscuit', 'Byte', 'peach', 'flowerCrown'));
      expect((look.deskAccessory, look.theme), (null, 'cyberpunk'));
      expect(look.toJson().containsKey('deskAccessory'), isFalse, reason: 'missing means none on the phones');
      expect(look.seasonal, {'enabled': true, 'birthdayMonth': 7, 'birthdayDay': 4, 'decorateMenuBar': true});
      expect(t.desktop.ask.petName, 'Biscuit');
    });
  });

  test('a typed pet name never reaches claude’s command line with anything cmd.exe treats specially', () {
    expect(AskLaunch.safeName('Biscuit'), 'Biscuit');
    expect(AskLaunch.safeName('Mr. Whiskers-O\'Toole'), "Mr. Whiskers-O'Toole");
    expect(AskLaunch.safeName('a & calc.exe | "x" %PATH% ^'), 'a calc.exe x PATH');
    expect(AskLaunch.safeName('🐱&|'), 'Mochi');
    expect(AskLaunch.systemPrompt('x" & del *'), startsWith('You are x del, a small cat'));
    expect(AskLaunch.systemPrompt('Mochi'), contains('Motchi'));
    expect(AskLaunch.systemPrompt('Biscuit'), isNot(contains('Motchi')));
  });
}
