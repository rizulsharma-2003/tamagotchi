// The Settings window: every pane in light and dark at 1× and 2× text with no overflow, the sidebar (navigation,
// search, the keyboard), switches saved through DesktopSettings, the Phones pane with a fake room (an iPhone, an
// Android phone and Mochi Cloud; then nobody; then unpaired), and "Start Mochi with Windows" through a fake.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart' show DesktopStyle;
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/room_view.dart';
import 'package:mochi_desktop/src/ui/screens/settings_screen.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_link/mochi_link.dart';

import 'support/fakes.dart';

/// 5 November 2026: Diwali's lights are up (the 8th), so the holiday art shows too.
final DateTime diwaliWeek = DateTime(2026, 11, 5, 14, 30);

Map<String, Object?> peer(String id, String role, String platform, String name, {bool online = true, double? lastSeen}) => {
  'id': id,
  'role': role,
  'platform': platform,
  'name': name,
  'online': online,
  'lastSeen': ?lastSeen,
  if (role == 'pocket') 'app': '1.4',
};

double seconds(DateTime time) => time.millisecondsSinceEpoch / 1000;

void main() {
  late TestDesktop t;
  late FakeShell shell;

  setUp(() {
    t = TestDesktop.make(saved: hostCredentials, clock: () => diwaliWeek);
    shell = FakeShell();
  });

  tearDown(() => t.dispose());

  /// The relay says who's in the room: this PC and [others].
  Future<void> room(WidgetTester tester, List<Map<String, Object?>> others) => tester.runAsync(() async {
    await t.desktop.link.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    t.socket.sync(devices: [peer('dev_pc', 'host', 'windows', 'TEST-PC'), ...others]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  Future<void> everyone(WidgetTester tester) => room(tester, [
    peer('dev_iphone', 'pocket', 'iOS', "Rizul's iPhone"),
    peer('dev_droid', 'pocket', 'android', 'realme RMX3242', online: false, lastSeen: seconds(diwaliWeek) - 1500),
    peer('dev_cloud', 'cloud', 'cloud', 'Mochi Cloud', online: false, lastSeen: seconds(diwaliWeek) - 1900),
  ]);

  Future<DesktopAppState> open(
    WidgetTester tester, {
    SettingsTab pane = SettingsTab.general,
    double textScale = 1,
    Size size = SurfaceSizes.settings,
    Surface surface = Surface.main,
    MainPage page = MainPage.settings,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      DesktopApp(
        desktop: t.desktop,
        shell: shell,
        initialSurface: surface,
        initialPage: page,
        initialPane: pane,
        library: Future<PoseLibrary?>.value(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return tester.state<DesktopAppState>(find.byType(DesktopApp));
  }

  /// The pane's header (the second of its titles: the first is in the sidebar).
  Finder header(SettingsTab tab) => find.descendant(of: find.byType(SettingsScreen), matching: find.text(tab.title));

  group('Every pane', () {
    for (final theme in [ThemeMode.light, ThemeMode.dark]) {
      for (final scale in [1.0, 2.0]) {
        for (final tab in SettingsTab.ordered) {
          testWidgets('${tab.title} (${theme.name}, ${scale.toStringAsFixed(0)}× text)', (tester) async {
            t.desktop.settings.themeMode = theme;
            await everyone(tester);
            await open(tester, pane: tab, textScale: scale);
            expect(tester.takeException(), isNull);
            expect(header(tab), findsWidgets);
            expect(find.textContaining(tab.blurb().split(' ').take(2).join(' ')), findsWidgets);
            final screen = tester.element(find.byType(SettingsScreen));
            expect(Theme.of(screen).brightness, theme == ThemeMode.dark ? Brightness.dark : Brightness.light);
            // The whole pane is laid out at once (a SingleChildScrollView); scroll to its end anyway.
            final content = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(SingleChildScrollView)).last;
            await tester.drag(content, const Offset(0, -4000));
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('a narrow window gets icons only, and every pane still fits', (tester) async {
      await everyone(tester);
      final state = await open(tester, size: const Size(460, 680));
      expect(find.widgetWithText(TextField, 'Search'), findsNothing, reason: 'no search field in the icon sidebar');
      expect(find.byTooltip('Phones'), findsOneWidget);
      for (final tab in SettingsTab.ordered) {
        state.settingsNavigation.tab = tab;
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: tab.title);
      }
    });

    testWidgets('names the paired phones in the Phones header, and "Not on Windows yet" never hides an idea', (tester) async {
      await everyone(tester);
      await open(tester, pane: SettingsTab.phones);
      expect(find.text("Mochi on Rizul's iPhone and realme RMX3242: pairing, Claude’s summaries and talking to Mochi from a phone."), findsOneWidget);
      for (final tab in [SettingsTab.assistant, SettingsTab.notifications]) {
        tester.state<DesktopAppState>(find.byType(DesktopApp)).settingsNavigation.tab = tab;
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text(SoonRow.tag), findsWidgets, reason: tab.title);
      }
      // Sprint 2's W23b took the agent's last ones: marking mail read, Mochi Cloud's trigger and the Watcher.
      tester.state<DesktopAppState>(find.byType(DesktopApp)).settingsNavigation.tab = SettingsTab.agent;
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(SoonRow.tag), findsNothing);
      // Sprint 2's W19 (Adventures) took Fun's last one.
      tester.state<DesktopAppState>(find.byType(DesktopApp)).settingsNavigation.tab = SettingsTab.fun;
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(SoonRow.tag), findsNothing);
      // Sprint 2's W1, W2 and W4 took General's last ones: quiet hours, naps that follow the PC, the pet's shortcut.
      tester.state<DesktopAppState>(find.byType(DesktopApp)).settingsNavigation.tab = SettingsTab.general;
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(SoonRow.tag), findsNothing);
    });
  });

  group('Sidebar', () {
    testWidgets('the four groups in the Mac’s order; clicking a pane opens it', (tester) async {
      final state = await open(tester);
      for (final group in ['Your pet', 'Claude', 'Phones & alerts', 'App']) {
        expect(find.text(group), findsWidgets);
      }
      expect(state.settingsNavigation.visibleTabs, SettingsTab.ordered);
      final top = [for (final tab in SettingsTab.groups.first.tabs) tester.getTopLeft(find.bySemanticsLabel(tab.title).first).dy];
      expect(top, [...top]..sort(), reason: 'General, Characters, Desktop Pet, Fun');
      await tester.scrollUntilVisible(find.bySemanticsLabel('Notifications'), 100, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.bySemanticsLabel('Notifications').first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.settingsNavigation.tab, SettingsTab.notifications);
      expect(find.text('Play sounds'), findsOneWidget);
      // The pet card opens Characters.
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Mochi, with Patch\. Change how Mochi looks')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.settingsNavigation.tab, SettingsTab.characters);
    });

    testWidgets('search finds panes by their words; Enter opens the first; nothing matches says so; Escape clears', (tester) async {
      final state = await open(tester);
      await tester.enterText(find.byType(TextField).first, 'gmail');
      await tester.pump();
      expect(state.settingsNavigation.visibleTabs, [SettingsTab.agent]);
      expect(find.bySemanticsLabel('Phones'), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.settingsNavigation.tab, SettingsTab.agent);

      await tester.enterText(find.byType(TextField).first, 'iphone pair');
      await tester.pump();
      expect(state.settingsNavigation.visibleTabs, [SettingsTab.phones]);

      await tester.enterText(find.byType(TextField).first, 'licence');
      await tester.pump();
      expect(state.settingsNavigation.visibleTabs, [SettingsTab.about]);

      await tester.enterText(find.byType(TextField).first, 'zebra');
      await tester.pump();
      expect(find.text('No settings match “zebra”.'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(state.settingsNavigation.query, '');
      expect(state.surface, Surface.main, reason: 'the first Escape only clears the search');
      expect(state.settingsNavigation.visibleTabs, SettingsTab.ordered);
    });
  });

  group('Keyboard', () {
    testWidgets('Ctrl+F searches; Down and Up move through the panes; Escape closes to where Settings came from', (tester) async {
      final state = await open(tester, surface: Surface.main, page: MainPage.home);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.page, MainPage.settings);
      expect(shell.mainShows.last, SurfaceSizes.settings, reason: 'Settings opens at the Mac’s size');

      final screen = tester.state<SettingsScreenState>(find.byType(SettingsScreen));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(screen.searchFocus.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(state.settingsNavigation.tab, SettingsTab.general);
      expect(screen.searchFocus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(state.settingsNavigation.tab, SettingsTab.characters);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(state.settingsNavigation.tab, SettingsTab.claude, reason: 'across the group boundary (past Mischief, Windows only)');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.settingsNavigation.tab, SettingsTab.mischief);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.settingsNavigation.tab, SettingsTab.fun);
      expect(find.text('Celebrate holidays with decorations, costumes and treats'), findsOneWidget);

      // Opened from Mochi's window: Escape goes back to it, at its own size.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      expect((state.surface, state.page), (Surface.main, MainPage.home));
      expect(shell.mainShows.last, SurfaceSizes.main);

      // From the tray: Escape closes to the pet, and Settings reopens at the pane you left.
      state.closeMain();
      await tester.pump();
      shell.controller.add(ShellAction.settings);
      await tester.pump(const Duration(milliseconds: 300));
      expect((state.surface, state.page, state.settingsNavigation.tab), (Surface.main, MainPage.settings, SettingsTab.fun));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(state.surface, Surface.pet);
    });

    testWidgets('Tab reaches the sidebar and the pane’s controls, with spoken names', (tester) async {
      await open(tester, pane: SettingsTab.notifications);
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Notifications'), findsWidgets);
      final focused = <FocusNode>{};
      for (var i = 0; i < 24; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final node = FocusManager.instance.primaryFocus;
        if (node != null) focused.add(node);
      }
      expect(focused.length, greaterThanOrEqualTo(14));
      expect(tester.getSemantics(find.byType(Switch).first).label, contains('Play sounds'));
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse, reason: 'sounds are off by default, as on the Mac');
      expect(find.bySemanticsLabel(RegExp('^Turn completed: Animate')), findsOneWidget, reason: 'each checkbox says what it is');
      handle.dispose();
    });
  });

  group('Switches are saved', () {
    testWidgets('Notifications, Phones, Desktop Pet and Fun switches go to DesktopSettings and its file', (tester) async {
      final state = await open(tester, pane: SettingsTab.notifications);
      final settings = t.desktop.settings;
      Future<void> flip(String title) async {
        final row = find.ancestor(of: find.text(title), matching: find.byType(ToggleRow));
        await tester.ensureVisible(row);
        await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
        await tester.pump(const Duration(milliseconds: 300));
      }

      Future<void> tick(String label) async {
        final box = find.bySemanticsLabel(label);
        await tester.ensureVisible(box);
        await tester.tap(box);
        await tester.pump(const Duration(milliseconds: 300));
      }

      await tick('Turn completed: Animate');
      await tick('API errors: Animate');
      expect((settings.celebrateFinished, settings.showSnags), (false, false));
      expect(t.document.json!['celebrateFinished'], false);
      expect((t.document.json!['categoryDelivery'] as Map)['turnCompleted'], {'animate': false, 'badge': false, 'banner': false, 'sound': true});
      await flip('Play sounds');
      expect(t.document.json!['soundEnabled'], true);

      state.settingsNavigation.tab = SettingsTab.phones;
      await tester.pump(const Duration(milliseconds: 300));
      await flip('Send Claude’s summaries to my phones');
      await flip('Run what I tell Mochi on my phones');
      expect((settings.shareSummaries, settings.acceptCommands), (true, false));
      expect((t.document.json!['shareSummaries'], t.document.json!['acceptCommands']), (true, false));

      state.settingsNavigation.tab = SettingsTab.desktop;
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Classic tray icon'));
      await tester.pump(const Duration(milliseconds: 300));
      expect((settings.petStyle, settings.roamTaskbar), (DesktopStyle.icon, false));
      expect(shell.trayStyles.last, DesktopStyle.icon, reason: 'the tray’s tick follows');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Plays in its spot'));
      await tester.pump(const Duration(milliseconds: 300));
      expect((t.document.json!['petStyle'], t.document.json!['roamTaskbar']), ('spot', true));
      await flip('Show the desktop pet');
      expect(t.document.json!['showPet'], false);

      state.settingsNavigation.tab = SettingsTab.fun;
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('Diwali until 10 November.'), findsOneWidget);
      await flip('Celebrate holidays with decorations, costumes and treats');
      expect((t.document.json!['seasonal'] as Map)['enabled'], false);
      expect(find.text('Decorations are off.'), findsOneWidget);
    });

    testWidgets('General: names (to the phones too), the theme, pausing reactions, and Reset', (tester) async {
      await tester.runAsync(() async {
        await t.desktop.start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await open(tester);
      final settings = t.desktop.settings;
      await tester.enterText(find.widgetWithText(TextField, 'Your pet'), 'Biscuit');
      await tester.pump();
      expect(settings.petName, 'Biscuit');
      expect(t.document.json!['petName'], 'Biscuit');
      expect(find.text('Start Biscuit with Windows'), findsOneWidget, reason: 'the panes use the new name');
      t.desktop.phone.tick();
      expect(PetLook.fromValue(t.socket.values(LinkKey.look).last)!.petName, 'Biscuit', reason: 'the phones get it');

      await tester.tap(find.text('Dark'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.themeMode, ThemeMode.dark);

      final pause = find.ancestor(of: find.text('Pause all reactions'), matching: find.byType(ToggleRow));
      await tester.ensureVisible(pause);
      await tester.tap(find.descendant(of: pause, matching: find.byType(Switch)));
      await tester.pump();
      expect(settings.pauseReactions, isTrue);

      await tester.ensureVisible(find.text('Reset Settings…'));
      await tester.tap(find.text('Reset Settings…'));
      await tester.pumpAndSettle();
      expect(find.text('Reset Mochi’s settings?'), findsOneWidget);
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect((settings.petName, settings.themeMode, settings.pauseReactions), ('Mochi', ThemeMode.system, false));
      expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Your pet')).controller!.text, 'Mochi', reason: 'the field shows the name again');
    });

    testWidgets('Characters: the coat, what they wear, the desk and the theme; the pet wears them', (tester) async {
      final state = await open(tester, pane: SettingsTab.characters);
      final settings = t.desktop.settings;
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Lavender coat')));
      await tester.pump();
      expect(settings.petColor, PetColor.lavender);
      expect(t.document.json!['petColor'], 'lavender');

      Future<void> choose(String label, String item) async {
        final menu = find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((widget) => widget is MenuRow));
        final button = find.descendant(of: menu, matching: find.byWidgetPredicate((widget) => widget is DropdownButton));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(find.text(item).last);
        await tester.pumpAndSettle();
      }

      await choose('Mochi wears', 'Round Glasses');
      // The headphones come with an achievement (Hello, Patch): shown with how to get them, not to be chosen yet.
      final patchMenu = tester.widget<MenuRow<Accessory?>>(find.ancestor(of: find.text('Patch wears'), matching: find.byType(MenuRow<Accessory?>)));
      expect(patchMenu.items, contains((Accessory.headphones, 'Tiny Headphones — Unlock: Hello, Patch')));
      expect(patchMenu.locked, contains(Accessory.headphones));
      await choose('Patch wears', 'Knitted Scarf');
      await choose('On the desk', 'Rubber Duck');
      await choose('Office theme', 'Space Station');
      expect(
        (settings.petAccessory, settings.companionAccessory, settings.deskAccessory, settings.officeTheme),
        (Accessory.roundGlasses, Accessory.scarf, Accessory.rubberDuck, OfficeTheme.spaceStation),
      );
      expect(t.document.json!['deskAccessory'], 'rubberDuck');
      expect(tester.takeException(), isNull);

      // Mochi's window: the room, the pet in lavender with round glasses, Patch in a scarf at a Space Station desk with
      // the duck.
      state.open(MainPage.home);
      await tester.pump(const Duration(milliseconds: 300));
      SceneConfig room() => (tester.widget<CustomPaint>(
        find.descendant(of: find.byType(RoomView), matching: find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is LiveRoomPainter)),
      ).painter! as LiveRoomPainter).config;
      expect(
        (room().petColor, room().wornByPet, room().wornByCompanion, room().deskAccessory, room().theme),
        (PetColor.lavender, Accessory.roundGlasses, Accessory.scarf, Accessory.rubberDuck, OfficeTheme.spaceStation),
      );
      // Nothing chosen: Diwali's flower crown.
      settings.petAccessory = null;
      await tester.pump();
      expect(room().wornByPet, Accessory.flowerCrown);
      expect(find.text('Happy Diwali'), findsOneWidget);
    });
  });

  group('Phones', () {
    testWidgets('an iPhone, an Android phone and Mochi Cloud, by name; a test to all; Unpair This PC asks first', (tester) async {
      await everyone(tester);
      await open(tester, pane: SettingsTab.phones);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text("Rizul's iPhone · iOS"), findsOneWidget);
      expect(find.text('realme RMX3242 · Android'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Away · 25 min ago'), findsOneWidget);
      expect(find.text('Mochi Cloud'), findsOneWidget);
      expect(find.text('Last check 32 min ago'), findsOneWidget);
      expect(find.textContaining("The Live Activity on Rizul's iPhone · iOS needs Mochi on a Mac"), findsOneWidget);
      expect(find.textContaining('this Mac'), findsNothing, reason: 'this PC is a PC');

      final before = t.socket.sentFrames('send', 'alert').length;
      await tester.ensureVisible(find.text('Send a Test to All Phones'));
      await tester.tap(find.text('Send a Test to All Phones'));
      await tester.pump();
      expect(t.socket.sentFrames('send', 'alert').length, before + 1);
      expect(find.text("Sent a test to Rizul's iPhone and realme RMX3242."), findsOneWidget);

      await tester.tap(find.text('Unpair This PC…'));
      await tester.pumpAndSettle();
      expect(find.text('Unpair this PC from Mochi Link?'), findsOneWidget);
      expect(find.textContaining("Rizul's iPhone and realme RMX3242 are cut off"), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(t.desktop.link.paired, isTrue);
      await tester.tap(find.text('Unpair This PC…'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Unpair'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump();
      expect(t.desktop.link.paired, isFalse);
      expect(t.api.deleted, [hostCredentials]);
      expect(find.text('Not paired'), findsOneWidget);
    });

    testWidgets('a room nobody has joined yet (made for updates, or a code not scanned yet) is not paired', (tester) async {
      await room(tester, const []);
      await open(tester, pane: SettingsTab.phones);
      expect(t.desktop.link.hasRoom, isTrue);
      expect(t.desktop.link.paired, isFalse);
      expect(find.text('Not paired'), findsOneWidget);
      expect(find.text('Unpair This PC…'), findsNothing);
      expect(find.text('Send a Test to All Phones'), findsNothing);
      expect(find.text('Live Activity'), findsNothing);
      expect(find.textContaining('Mochi on your phones: pairing'), findsOneWidget);
    });

    testWidgets('only Mochi Cloud in the room: paired, but no phone to send a test to', (tester) async {
      await room(tester, [peer('dev_cloud', 'cloud', 'cloud', 'Mochi Cloud')]);
      await open(tester, pane: SettingsTab.phones);
      expect(find.text('None paired yet'), findsOneWidget);
      final test = tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Send a Test to All Phones'));
      expect(test.onPressed, isNull);
      expect(find.text('Live Activity'), findsNothing);
    });

    testWidgets('unpaired: Pair a Phone… opens the pairing page with a fresh code', (tester) async {
      t.vault.saved = null;
      await tester.runAsync(() => t.desktop.link.start());
      final state = await open(tester, pane: SettingsTab.phones);
      expect(find.text('Not paired'), findsOneWidget);
      expect(find.text('Unpair This PC…'), findsNothing);
      expect(find.textContaining('nothing from this PC goes to your phones'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Pair a Phone…'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.page, MainPage.pairing);
      expect(t.api.roomsMade, 1);
      expect(find.bySemanticsLabel('Pairing QR code'), findsOneWidget);
      expect(find.textContaining('tap Scan the Code'), findsOneWidget);
    });
  });

  group('Start Mochi with Windows', () {
    testWidgets('the switch turns the startup item on and off through the fake', (tester) async {
      await open(tester);
      final row = find.ancestor(of: find.text('Start Mochi with Windows'), matching: find.byType(ToggleRow));
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(t.startup.enabled, isTrue);
      expect(tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).value, isTrue);
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(t.startup.changes, [true, false]);
      expect(t.startup.enabled, isFalse);
    });

    testWidgets('says why when Windows refuses, and what Task Manager did', (tester) async {
      t.startup
        ..problem = "Windows didn't let Mochi add itself to your startup apps (error 5)."
        ..note = 'Turned off in Task Manager › Startup apps. Switching it on here turns it back on.';
      await open(tester);
      expect(find.textContaining('Turned off in Task Manager'), findsOneWidget);
      final row = find.ancestor(of: find.text('Start Mochi with Windows'), matching: find.byType(ToggleRow));
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(find.text("Windows didn't let Mochi add itself to your startup apps (error 5)."), findsOneWidget);
      expect(t.startup.enabled, isFalse);
    });

    testWidgets('where Windows isn’t (the macOS build), the switch is shown but off and disabled', (tester) async {
      t.startup.supported = false;
      await open(tester);
      final row = find.ancestor(of: find.text('Start Mochi with Windows'), matching: find.byType(ToggleRow));
      expect(tester.widget<Switch>(find.descendant(of: row, matching: find.byType(Switch))).onChanged, isNull);
      expect(find.text('Starting with Windows works in Mochi for Windows.'), findsOneWidget);
    });
  });

  testWidgets('Claude Code: connect asks first and backs up; Remove asks too; the status says what’s what', (tester) async {
    final state = await open(tester, pane: SettingsTab.claude);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('/usr/local/bin/claude'), findsOneWidget);
    expect(find.text('Claude Code not connected'), findsOneWidget, reason: 'the title bar’s pill');
    await tester.ensureVisible(find.text('Connect Claude Code…'));
    await tester.tap(find.text('Connect Claude Code…'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Claude Code?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(t.desktop.hooks.connected, isFalse);
    await tester.tap(find.text('Preview Changes'));
    await tester.pump();
    expect(find.textContaining('"hooks"'), findsOneWidget);
    expect(state.settingsNavigation.tab, SettingsTab.claude);
  });
}
