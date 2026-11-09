// Docs/SPRINT_2.md W23a: Settings › Agent (the Mac's AgentSettingsView): the main switch, connections with Check Connections
// and Connect…, how often, quiet hours and the briefing time, Tell me (worded for the phones actually paired), VIPs, what
// Mochi can see, and Recent with Check Now, Briefing Now, Forget and Done on each note. It's all reachable from the
// keyboard and every row reads as one thing to a screen reader. Nothing runs while the agent is off.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/agent/agent_settings.dart';
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
  Future<void> open(WidgetTester tester, {AgentSettings? agent, List<Map<String, Object?>> others = const []}) async {
    claude = AgentClaudeFake();
    opener = OpenerFake();
    t = TestDesktop.make(saved: hostCredentials, agentClaude: claude, opener: opener);
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
        initialPane: SettingsTab.agent,
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
