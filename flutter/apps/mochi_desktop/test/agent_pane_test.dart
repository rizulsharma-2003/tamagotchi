// Docs/SPRINT_2.md W23a: Settings › Agent (the Mac's AgentSettingsView): the main switch, connections with Check Connections
// and Connect…, how often, quiet hours and the briefing time, Tell me (worded for the phones actually paired), VIPs, what
// Mochi can see, and Recent with Check Now, Briefing Now, Forget and Done on each note. It's all reachable from the
// keyboard and every row reads as one thing to a screen reader. Nothing runs while the agent is off.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/agent/agent_settings.dart';
import 'package:mochi_desktop/src/core/agent/cloud_token_vault.dart';
import 'package:mochi_desktop/src/core/claude_cli.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_link/mochi_link.dart';

import 'support/agent_fakes.dart';
import 'support/fakes.dart';

Map<String, Object?> peer(String id, String role, String platform, String name) => {
  'id': id,
  'role': role,
  'platform': platform,
  'name': name,
  'online': true,
};

void main() {
  late TestDesktop t;
  late AgentClaudeFake claude;
  late OpenerFake opener;
  late MemoryCloudTokenVault vault;
  tearDown(() => t.dispose());

  /// A pane test: what it opened is closed again at its end (the desktop's own timers belong to the test's clock).
  void paneTest(String name, Future<void> Function(WidgetTester tester) body) => testWidgets(name, (tester) async {
    await body(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(t.dispose);
    await tester.pump();
  });

  final host = peer('dev_pc', 'host', 'windows', 'TEST-PC');
  final android = peer('dev_droid', 'pocket', 'android', 'realme RMX3242');

  /// Opens Settings › Agent, with [others] in this PC's room.
  Future<void> open(WidgetTester tester, {AgentSettings? agent, List<Map<String, Object?>> others = const [], String? token, SettingsTab pane = SettingsTab.agent}) async {
    claude = AgentClaudeFake();
    opener = OpenerFake();
    vault = MemoryCloudTokenVault(token);
    t = TestDesktop.make(saved: hostCredentials, agentClaude: claude, opener: opener, cloudTokens: vault);
    if (agent != null) t.desktop.settings.agent = agent;
    await tester.runAsync(() async {
      await t.desktop.link.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t.socket.sync(devices: [host, ...others]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    t.desktop.agent.start();
    tester.view.physicalSize = const Size(1100, 5200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      DesktopApp(
        desktop: t.desktop,
        shell: FakeShell(),
        initialSurface: Surface.main,
        initialPage: MainPage.settings,
        initialPane: pane,
        library: Future<PoseLibrary?>.value(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> work(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  AgentSettings agent() => t.desktop.settings.agent;

  /// The VIP field (the sidebar has a search field too).
  final Finder vipField = find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Name, email address or @company.com');

  Finder switchOf(String title) => find.descendant(of: find.ancestor(of: find.text(title), matching: find.byType(InkWell)).first, matching: find.byType(Switch));

  group('The main switch', () {
    paneTest('off at first: nothing runs, nothing is probed, the buttons wait; on, it starts, and off ends it', (tester) async {
      await open(tester);
      expect(find.text('Let Mochi keep an eye on my mail, calendar and tasks'), findsOneWidget);
      expect(tester.widget<Switch>(switchOf('Let Mochi keep an eye on my mail, calendar and tasks')).value, isFalse);
      expect(claude.runs, isEmpty, reason: 'opening the pane runs nothing while the agent is off');
      expect(t.desktop.agent.ticking, isFalse);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Check Now')).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Briefing Now')).onPressed, isNull);
      expect(find.text('Turn on Mochi’s agent above to check.'), findsOneWidget);
      expect(find.textContaining('Every few minutes Mochi asks Claude Haiku'), findsOneWidget);
      expect(find.textContaining('nothing is ever sent, changed or deleted'), findsOneWidget);

      await tester.tap(switchOf('Let Mochi keep an eye on my mail, calendar and tasks'));
      await tester.pump();
      expect(agent().enabled, isTrue);
      expect(t.desktop.agent.ticking, isTrue);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Check Now')).onPressed, isNotNull);

      await tester.tap(find.text('Let Mochi keep an eye on my mail, calendar and tasks'));
      await tester.pump();
      expect(agent().enabled, isFalse, reason: 'the whole row is the switch');
      expect(t.desktop.agent.ticking, isFalse);
    });

    paneTest('on at open, with nothing known: one short look at the connections, once', (tester) async {
      await open(tester, agent: const AgentSettings(enabled: true));
      await work(tester);
      expect(claude.probes, hasLength(1));
      expect(find.text('Connected'), findsNWidgets(3));
      expect(find.text('Connect Gmail…'), findsNothing);
    });
  });

  group('Connections', () {
    paneTest('Check Connections reads each state; Connect… is only for what is not connected and opens the Mac’s page', (tester) async {
      await open(tester);
      expect(find.text('Unknown'), findsNWidgets(3));
      claude.probe = probeOutput(calendar: false);
      await tester.tap(find.text('Check Connections'));
      await work(tester);
      expect(claude.probes, hasLength(1));
      expect(find.text('Connected'), findsNWidgets(2));
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text('Connect Gmail…'), findsNothing);
      await tester.tap(find.text('Connect Google Calendar…'));
      await work(tester);
      expect(opener.opened, [Uri.parse('https://claude.ai/customize/connectors')]);
      expect(find.textContaining('Come back and press Check Connections'), findsOneWidget, reason: 'off: nothing watches by itself');
    });

    paneTest('Watch turns a source on or off, keeping the usual order', (tester) async {
      await open(tester);
      await tester.tap(find.byWidgetPredicate((widget) => widget is Checkbox && widget.semanticLabel == 'Watch Gmail'));
      await tester.pump();
      expect(agent().watched, [AgentSource.calendar, AgentSource.notion]);
      await tester.tap(find.byWidgetPredicate((widget) => widget is Checkbox && widget.semanticLabel == 'Watch Gmail'));
      await tester.pump();
      expect(agent().watched, AgentSource.values);
    });

    paneTest('the footer says Mochi notices when you are back, while the agent is on', (tester) async {
      await open(tester, agent: const AgentSettings(enabled: true));
      await work(tester);
      expect(find.textContaining('Mochi notices when you’re back'), findsOneWidget);
    });
  });

  group('How often', () {
    paneTest('the interval, quiet hours, and the briefing time', (tester) async {
      await open(tester);
      expect(find.text('15 minutes'), findsOneWidget);
      await tester.tap(find.text('15 minutes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('30 minutes').last);
      await tester.pumpAndSettle();
      expect(agent().intervalMinutes, 30);

      expect(find.text('No checks from 23:00 to 08:00.'), findsOneWidget);
      await tester.tap(find.text('23:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('22:00').last);
      await tester.pumpAndSettle();
      expect(agent().quietHours.startMinute, 22 * 60);

      await tester.tap(find.text('09:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('07:30').last);
      await tester.pumpAndSettle();
      expect(agent().briefingMinute, 7 * 60 + 30);

      await tester.tap(find.text('Quiet hours'));
      await tester.pump();
      expect(agent().quietHours.enabled, isFalse);
      expect(find.text('Check around the clock.'), findsOneWidget);
      expect(tester.widget<DropdownButton<int>>(find.byType(DropdownButton<int>).at(1)).onChanged, isNull, reason: 'the times wait for quiet hours');

      await tester.tap(find.text('Morning briefing'));
      await tester.pump();
      expect(agent().briefingEnabled, isFalse);
      expect(tester.widget<DropdownButton<int>>(find.byType(DropdownButton<int>).last).onChanged, isNull);
    });

    paneTest('the footer names Ask Mochi’s shortcut', (tester) async {
      await open(tester);
      expect(find.textContaining('“what’s pending?” in Ask Mochi (Ctrl+Alt+Space)'), findsOneWidget);
    });
  });

  group('Tell me', () {
    paneTest('each switch is its setting', (tester) async {
      await open(tester);
      for (final (title, read) in <(String, bool Function(AgentSettings))>[
        ('In Mochi’s speech bubble', (s) => s.tellInBubble),
        ('With a dot on Mochi and the tray icon', (s) => s.tellWithBadge),
      ]) {
        expect(read(agent()), isTrue, reason: title);
        await tester.tap(find.text(title));
        await tester.pump();
        expect(read(agent()), isFalse, reason: title);
      }
    });

    paneTest('no phone yet: “my phones”, with how to pair one', (tester) async {
      await open(tester);
      expect(find.text('On my phones: notifications and a “Waiting for you” card in Mochi'), findsOneWidget);
      expect(find.text('Keep newsletters and automated mail off my phones'), findsOneWidget);
      expect(find.text('Pair a phone in Settings › Phones › Mochi Link to get these on your phones.'), findsOneWidget);
    });

    paneTest('an Android phone is named, and the iPhone is never assumed', (tester) async {
      await open(tester, others: [android]);
      expect(find.text('On realme RMX3242: notifications and a “Waiting for you” card in Mochi'), findsOneWidget);
      expect(find.text('Keep newsletters and automated mail off realme RMX3242'), findsOneWidget);
      expect(find.textContaining('iPhone'), findsNothing);
      expect(find.textContaining('Pair a phone in Settings'), findsNothing);
      await tester.tap(find.textContaining('On realme RMX3242'));
      await tester.pump();
      expect(agent().tellPhone, isFalse);
      expect(tester.widget<Switch>(switchOf('Keep newsletters and automated mail off realme RMX3242')).onChanged, isNull, reason: 'it waits for “On my phones”');
    });

    paneTest('both an iPhone and an Android are named', (tester) async {
      await open(tester, others: [peer('dev_ios', 'pocket', 'ios', 'Rizul’s iPhone'), android]);
      expect(find.textContaining('Rizul’s iPhone and realme RMX3242'), findsWidgets);
    });
  });

  group('VIPs', () {
    paneTest('add by typing and pressing Enter, add with the button, no duplicates, remove', (tester) async {
      await open(tester);
      expect(find.textContaining('Add the people whose mail matters most'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Add')).onPressed, isNull, reason: 'nothing typed');
      await tester.enterText(vipField, '  Amogh Sharma ');
      await tester.pump();
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Add')).onPressed, isNotNull);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(agent().vips, ['Amogh Sharma']);
      expect(tester.widget<TextField>(vipField).controller?.text, isEmpty);
      expect(find.text('Amogh Sharma'), findsOneWidget);
      expect(find.textContaining('Only mail from these people (and meetings) rings'), findsOneWidget);

      await tester.enterText(vipField, '@insideedge.club');
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Add'));
      await tester.pump();
      expect(agent().vips, ['Amogh Sharma', '@insideedge.club']);

      await tester.enterText(vipField, 'amogh sharma');
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Add'));
      await tester.pump();
      expect(agent().vips, hasLength(2), reason: 'already there, whatever the case');

      await tester.tap(find.byTooltip('Remove Amogh Sharma'));
      await tester.pump();
      expect(agent().vips, ['@insideedge.club']);
      await tester.tap(find.byTooltip('Remove @insideedge.club'));
      await tester.pump();
      expect(agent().vips, isEmpty);
      expect(find.textContaining('Add the people whose mail matters most'), findsOneWidget);
    });
  });

  group('What Mochi can see', () {
    paneTest('says what is read from each source, and that only what Mochi told you is kept', (tester) async {
      await open(tester);
      expect(find.text('Sender, subject and first lines of new mail in your inbox'), findsOneWidget);
      expect(find.text('Title, time and place of your coming events'), findsOneWidget);
      expect(find.text('Titles and due dates of open tasks assigned to you'), findsOneWidget);
      expect(find.textContaining('This PC keeps only what Mochi told you (below) for two weeks'), findsOneWidget);
    });
  });

  group('Recent', () {
    paneTest('Check Now and Briefing Now look and say what they found; Last looked; Done; Forget', (tester) async {
      await open(tester, agent: const AgentSettings(enabled: true));
      claude.check = digestOutput(
        headline: 'A busy day',
        emails: [mail('t1', from: 'Figma', subject: 'Comment on Mochi', gist: 'Someone mentioned you', reply: true)],
        events: [meeting('e1', DateTime.now().add(const Duration(hours: 3)), title: 'Standup')],
      );
      expect(find.text('Nothing yet.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Check Now'));
      await work(tester);
      expect(claude.checks, hasLength(1));
      expect(find.textContaining('New email from Figma: Someone mentioned you (needs a reply)'), findsWidgets);
      expect(find.text('Last looked just now'), findsOneWidget);
      expect(find.text('Nothing yet.'), findsNothing);
      expect(find.text('Figma'), findsOneWidget);
      expect(find.text('Comment on Mochi'), findsOneWidget);
      expect(find.text('Standup'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Briefing Now'));
      await work(tester);
      expect(claude.checks, hasLength(2));
      expect(find.text('A busy day'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Done').first);
      await tester.pump();
      expect(t.desktop.agent.doneCount, 1);
      expect(find.textContaining('· done'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Done'), findsOneWidget, reason: 'the other one is still open');

      await tester.tap(find.widgetWithText(TextButton, 'Forget'));
      await tester.pump();
      expect(find.text('Nothing yet.'), findsOneWidget);
      expect(t.desktop.agent.notes, isEmpty);
    });

    paneTest('a problem is said, not hidden', (tester) async {
      await open(tester, agent: const AgentSettings(enabled: true));
      await work(tester);
      claude.check = '{"type":"result","is_error":true,"result":"Usage limit reached"}';
      await tester.tap(find.widgetWithText(FilledButton, 'Check Now'));
      await work(tester);
      expect(find.text('Usage limit reached'), findsOneWidget);
    });

    paneTest('the buttons wait while a look is under way', (tester) async {
      await open(tester, agent: const AgentSettings(enabled: true));
      await work(tester);
      claude.hold = Completer<ClaudeRun>();
      await tester.tap(find.widgetWithText(FilledButton, 'Check Now'));
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Check Now')).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Check Connections')).onPressed, isNull);
      expect(find.bySemanticsLabel('Looking'), findsOneWidget);
      claude.hold!.complete(ClaudeRun(exitCode: 0, output: digestOutput()));
      await work(tester);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Check Now')).onPressed, isNotNull);
    });
  });

  const fireUrl = 'https://api.anthropic.com/v1/claude_code/routines/trig_012eNQcMDqqHfiWcYGoXKjts/fire';
  const fireToken = 'sk-ant-oat01-abcDEF_1234567890';
  const saved = AgentSettings(cloudFireURL: fireUrl);
  final Finder urlField = find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Fire URL (from the task’s API trigger)');
  final Finder tokenField = find.byWidgetPredicate((widget) => widget is TextField && widget.decoration?.labelText == 'Token');

  /// What Clipboard.setData is given from now on.
  List<String> clipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return copied;
  }

  /// Tab until the focus is on a widget that satisfies [test] (at most 80 presses).
  Future<bool> tabUntil(WidgetTester tester, bool Function(Element focused) test) async {
    for (var i = 0; i < 80; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final context = FocusManager.instance.primaryFocus?.context;
      if (context is Element && test(context)) return true;
    }
    return false;
  }

  bool isInsideRowOf(Element focused, String title) {
    var found = false;
    focused.visitAncestorElements((element) {
      if (element.widget is InkWell && find.descendant(of: find.byWidget(element.widget), matching: find.text(title)).evaluate().isNotEmpty) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool isTextButton(Element focused, String label) {
    var found = false;
    focused.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is TextButton && widget.child is Text && (widget.child! as Text).data == label) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  group('When I mark something done (W23b)', () {
    paneTest('the Mac’s switch and words, on by default; the “Not on Windows yet” rows are gone', (tester) async {
      await open(tester);
      expect(find.text('When I mark something done'), findsOneWidget);
      expect(find.text('Mark the email read in Gmail'), findsOneWidget);
      expect(tester.widget<Switch>(switchOf('Mark the email read in Gmail')).value, isTrue);
      expect(
        find.text(
          'Tap ✓ on anything in “Waiting for you” on your phone (or Done below) and it leaves the card on every device. With this on, '
          'Mochi also removes Gmail’s unread mark from that thread — the only change Mochi ever makes to your mail, and only for what you marked.',
        ),
        findsOneWidget,
      );
      expect(find.text('Not on Windows yet'), findsNothing);
      expect(find.text('From the Mac'), findsNothing);
      await tester.tap(find.text('Mark the email read in Gmail'));
      await tester.pump();
      expect(agent().markReadWhenDone, isFalse, reason: 'the whole row is the switch');
      await tester.tap(switchOf('Mark the email read in Gmail'));
      await tester.pump();
      expect(agent().markReadWhenDone, isTrue);
    });

    paneTest('it names the phone that is paired', (tester) async {
      await open(tester, others: [android]);
      expect(find.textContaining('on realme RMX3242 (or Done below)'), findsOneWidget);
      expect(find.textContaining('iPhone'), findsNothing);
    });

    paneTest('Tab reaches the switch and Space works it', (tester) async {
      await open(tester);
      expect(await tabUntil(tester, (focused) => isInsideRowOf(focused, 'Mark the email read in Gmail')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(agent().markReadWhenDone, isFalse);
    });

    paneTest('the row reads as one thing to a screen reader: the title and the explanation together', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);
      final row = find.bySemanticsLabel(RegExp('^Mark the email read in Gmail'));
      expect(row, findsWidgets);
      expect(tester.getSemantics(row.first).label, contains('the only change Mochi ever makes to your mail'));
      semantics.dispose();
    });
  });

  group('Mochi Cloud’s trigger (W23b)', () {
    paneTest('fields until one is saved; Save waits for both; the Mac’s explanation, for this PC', (tester) async {
      await open(tester);
      expect(urlField, findsOneWidget);
      expect(tokenField, findsOneWidget);
      expect(tester.widget<TextField>(tokenField).obscureText, isTrue, reason: 'the token is hidden as you type');
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
      await tester.enterText(urlField, fireUrl);
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNull);
      await tester.enterText(tokenField, fireToken);
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed, isNotNull);
      expect(find.text('Copy Watcher Script'), findsNothing, reason: 'it shows only when a trigger is saved');
      // On Windows the vault is DPAPI: “sealed with Windows Data Protection”; the test's vault is memory.
      expect(
        find.text('The token can only start this one task. It’s kept on this PC, in memory only (this build), and shared with your phones through Mochi Link, end-to-end encrypted.'),
        findsOneWidget,
      );
    });

    paneTest('a wrong URL or token says so, with the Mac’s words, and nothing is kept', (tester) async {
      await open(tester);
      await tester.enterText(urlField, 'https://example.com/fire');
      await tester.enterText(tokenField, fireToken);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(find.text('Paste the Fire URL from the task’s API trigger (it ends in /fire).'), findsOneWidget);
      await tester.enterText(urlField, fireUrl);
      await tester.enterText(tokenField, 'short');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(find.text('Paste the token shown when you generated it.'), findsOneWidget);
      expect(find.text('Paste the Fire URL from the task’s API trigger (it ends in /fire).'), findsNothing);
      expect(agent().cloudFireURL, '');
      expect(vault.token, isNull);
    });

    paneTest('Save keeps the token in the vault only, shows the saved state, and never shows the token again', (tester) async {
      await open(tester, others: [android]);
      await tester.enterText(urlField, fireUrl);
      await tester.enterText(tokenField, fireToken);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(vault.token, fireToken);
      expect(agent().cloudFireURL, fireUrl);
      expect(jsonEncode(agent().toJson()), isNot(contains(fireToken)));
      expect(urlField, findsNothing);
      expect(tokenField, findsNothing);
      expect(find.text('On realme RMX3242, “Check now” can ask the cloud when this PC doesn’t answer'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Copy Watcher Script'), findsOneWidget);
      expect(find.text('Open script.google.com'), findsOneWidget);
      expect(
        find.text(
          'Mochi Watcher, a small script in your own Google account, wakes the cloud only when new mail or a calendar change arrives (8:00–23:00), '
          'so Claude runs for real news instead of every hour.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining(fireToken), findsNothing);
    });

    paneTest('Remove takes it away and the fields come back, the token field empty', (tester) async {
      await open(tester, agent: saved, token: fireToken);
      await tester.tap(find.text('Remove'));
      await tester.pump();
      expect(vault.token, isNull);
      expect(agent().cloudFireURL, '');
      expect(tokenField, findsOneWidget);
      expect(tester.widget<TextField>(tokenField).controller!.text, isEmpty);
      expect(find.text('Copy Watcher Script'), findsNothing);
    });

    paneTest('Copy Watcher Script puts the Mac’s script (this PC’s zone, the trigger, the VIPs) on the clipboard and says what next', (tester) async {
      await open(tester, agent: const AgentSettings(cloudFireURL: fireUrl, vips: ['Amogh']), token: fireToken);
      final copied = clipboard(tester);
      await tester.tap(find.text('Copy Watcher Script'));
      await tester.pump();
      await tester.pump();
      expect(copied, hasLength(1));
      expect(copied.single, startsWith('/**\n * Mochi Watcher: wakes Mochi Cloud only when something new arrives'));
      expect(copied.single, contains("fireUrl: '$fireUrl'"));
      expect(copied.single, contains("token: '$fireToken'"));
      expect(copied.single, contains('vips: ["Amogh"],'));
      expect(copied.single, contains("timeZone: '"));
      expect(copied.single, isNot(contains('__')));
      expect(
        find.text('Copied. At script.google.com: New project, paste over everything, pick “setup” next to Run, press Run and allow access.'),
        findsOneWidget,
      );
    });

    paneTest('a token that can’t sit in the script: nothing is copied, and it says to save again', (tester) async {
      await open(tester, agent: saved, token: "abcdefghijklmnopqrstuvwxyz';alert(1);'");
      final copied = clipboard(tester);
      await tester.tap(find.text('Copy Watcher Script'));
      await tester.pump();
      expect(copied, isEmpty);
      expect(find.text('Save Mochi Cloud’s Fire URL and token first.'), findsOneWidget);
    });

    paneTest('Open script.google.com and Open claude.ai/code go through the app’s opener', (tester) async {
      await open(tester, agent: saved, token: fireToken);
      await tester.tap(find.text('Open script.google.com'));
      await tester.tap(find.text('Open claude.ai/code'));
      await tester.pump();
      expect(opener.opened, [Uri.parse('https://script.google.com/home/projects/create'), Uri.parse('https://claude.ai/code')]);
    });

    paneTest('changing the VIPs after a trigger is saved says to copy the script again; with none saved, nothing', (tester) async {
      await open(tester, agent: saved, token: fireToken);
      const note = 'Copy the Watcher Script again (below) and run “setup” once more, so Mochi Cloud knows your VIPs too.';
      expect(find.text(note), findsNothing);
      await tester.enterText(vipField, 'Rahul');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text(note), findsOneWidget);
    });

    paneTest('with no trigger saved, changing the VIPs says nothing about the script', (tester) async {
      await open(tester);
      await tester.enterText(vipField, 'Rahul');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining('Copy the Watcher Script again'), findsNothing);
    });

    paneTest('from the keyboard: Enter in the token field saves; Tab reaches Remove and Enter removes', (tester) async {
      await open(tester);
      await tester.enterText(urlField, fireUrl);
      await tester.tap(tokenField);
      await tester.pump();
      await tester.enterText(tokenField, fireToken);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(vault.token, fireToken, reason: 'Enter in the token field saves');
      expect(await tabUntil(tester, (focused) => isTextButton(focused, 'Remove')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(vault.token, isNull);
    });

    paneTest('Tab reaches the URL field, then the token field, then Save', (tester) async {
      await open(tester);
      await tester.enterText(urlField, fireUrl);
      await tester.enterText(tokenField, fireToken);
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      bool onField(Element focused, Finder field) => focused.findAncestorWidgetOfExactType<EditableText>() != null && find.descendant(of: field, matching: find.byWidget(focused.findAncestorWidgetOfExactType<EditableText>()!)).evaluate().isNotEmpty;
      expect(await tabUntil(tester, (focused) => onField(focused, urlField)), isTrue);
      expect(await tabUntil(tester, (focused) => onField(focused, tokenField)), isTrue);
      expect(await tabUntil(tester, (focused) => focused.findAncestorWidgetOfExactType<FilledButton>() != null), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(vault.token, fireToken);
    });

    paneTest('the fields and buttons say what they are to a screen reader; a problem is announced', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester);
      expect(find.bySemanticsLabel(RegExp('Fire URL')), findsWidgets);
      final token = tester.getSemantics(find.bySemanticsLabel(RegExp('^Token')).first);
      expect(token.flagsCollection.isObscured, isTrue);
      await tester.enterText(urlField, 'nope');
      await tester.enterText(tokenField, fireToken);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      final problem = tester.getSemantics(find.bySemanticsLabel(RegExp('^Paste the Fire URL')));
      expect(problem.flagsCollection.isLiveRegion, isTrue);
      semantics.dispose();
    });

    paneTest('the agent being off changes nothing here: the trigger belongs to the cloud, and nothing runs', (tester) async {
      await open(tester);
      expect(agent().enabled, isFalse);
      await tester.enterText(urlField, fireUrl);
      await tester.enterText(tokenField, fireToken);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      expect(find.text('Copy Watcher Script'), findsOneWidget);
      expect(claude.runs, isEmpty);
    });
  });

  group('Privacy and search (W23b)', () {
    paneTest('Settings › Privacy says the one change made in Gmail and where the token lives', (tester) async {
      await open(tester, pane: SettingsTab.privacy, agent: saved, token: fireToken);
      final text = find.textContaining('The one change it can make:');
      expect(text, findsOneWidget);
      expect(find.textContaining('removes Gmail’s unread mark from those threads'), findsOneWidget);
      expect(find.textContaining('token stays on this PC sealed with Windows Data Protection'), findsOneWidget);
      expect(find.text('Mochi Cloud’s trigger token'), findsOneWidget);
      expect(find.textContaining(fireToken), findsNothing, reason: 'the token is never shown');
    });

    test('the Agent pane is found by searching for its W23b features', () {
      for (final query in ['fire url', 'token', 'watcher script', 'script.google.com', 'mark read', 'unread', 'check now']) {
        expect(SettingsTab.agent.matches(query), isTrue, reason: query);
      }
    });
  });

  group('Keyboard and screen reader', () {
    /// Tab until the focus is inside a widget that satisfies [test] (at most [limit] presses).
    Future<bool> tabTo(WidgetTester tester, bool Function(Element focused) test, {int limit = 80}) async {
      for (var i = 0; i < limit; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final context = FocusManager.instance.primaryFocus?.context;
        if (context is Element && test(context)) return true;
      }
      return false;
    }

    bool inside<T extends Widget>(Element focused, {bool Function(T widget)? where}) {
      var found = false;
      focused.visitAncestorElements((element) {
        if (element.widget is T && (where?.call(element.widget as T) ?? true)) {
          found = true;
          return false;
        }
        return true;
      });
      return found || (focused.widget is T && (where?.call(focused.widget as T) ?? true));
    }

    paneTest('Tab reaches the main switch and Space turns it on; then Check Now works from the keyboard', (tester) async {
      await open(tester);
      expect(await tabTo(tester, (focused) => inside<Switch>(focused, where: (each) => !each.value)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(agent().enabled, isTrue, reason: 'the first switch on the page is the main one');
      expect(await tabTo(tester, (focused) => inside<FilledButton>(focused)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await work(tester);
      expect(claude.checks, hasLength(1));
    });

    paneTest('the VIP field is reached by Tab and Enter adds', (tester) async {
      await open(tester);
      expect(await tabTo(tester, (focused) => inside<EditableText>(focused)), isTrue);
      await tester.enterText(vipField, 'Rahul');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(agent().vips, ['Rahul']);
    });

    paneTest('each control says what it is', (tester) async {
      final semantics = tester.ensureSemantics();
      await open(tester, agent: const AgentSettings(enabled: true, vips: ['Amogh']));
      await work(tester);
      expect(find.bySemanticsLabel(RegExp('^Let Mochi keep an eye on my mail')), findsWidgets);
      final watch = tester.getSemantics(find.bySemanticsLabel('Watch Gmail'));
      expect(watch.flagsCollection.isChecked, isTrue, reason: 'a checkbox that says whether it is on');
      final remove = tester.getSemantics(find.byTooltip('Remove Amogh'));
      expect(remove.flagsCollection.isButton, isTrue);
      expect('${remove.label} ${remove.tooltip}', contains('Remove Amogh'), reason: 'its own stop, named for the person');
      final button = tester.getSemantics(find.widgetWithText(OutlinedButton, 'Check Connections'));
      expect(button.label, contains('Check Connections'));
      expect(button.flagsCollection.isButton, isTrue);
      expect(find.bySemanticsLabel(RegExp('^Gmail')), findsWidgets, reason: 'the source row reads its name and state together');
      claude.check = digestOutput(emails: [mail('t1', from: 'Figma', reply: true)]);
      await tester.tap(find.widgetWithText(FilledButton, 'Check Now'));
      await work(tester);
      expect(find.bySemanticsLabel('Mark Figma done'), findsOneWidget);
      expect(find.bySemanticsLabel('Last looked just now'), findsOneWidget);
      semantics.dispose();
    });
  });
}
