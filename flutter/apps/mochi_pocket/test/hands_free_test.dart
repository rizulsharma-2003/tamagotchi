import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/services/platform_bridge.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';
import 'package:mochi_pocket/src/widget/home_widget.dart';

import 'home_widget_test.dart' show FakeWidgetSurface;
import 'support/fakes.dart';

/// Hands-free (A4): the Quick Settings tile, the app shortcuts and Hey Google open Mochi at a place (`mochi://talk`,
/// `waiting`, `check`); Mochi listens, reads what's waiting in its own voice, or checks, and answers out loud when
/// Hey Google asked. Settings › Hands-free adds the tile.
void main() {
  test('a place and whether Hey Google asked for it', () {
    expect(AppPlace.parse('check:voice'), ('check', true));
    expect(AppPlace.parse('waiting'), ('waiting', false));
  });

  late FakeRelay relay;
  late FakeBridge bridge;
  late FakeSpeechEngine speech;
  late FakeSpeechListener listener;
  late AppSettings settings;
  late PocketModel model;
  late List<String> asked;
  late List<String> announced;
  late MemoryDocument widgetDocument;

  setUp(() {
    relay = FakeRelay();
    bridge = FakeBridge();
    speech = FakeSpeechEngine();
    listener = FakeSpeechListener();
    settings = AppSettings(MemoryDocument());
    asked = [];
    announced = [];
    widgetDocument = MemoryDocument();
    model = PocketModel(
      credentialStore: MemoryCredentialStore(phoneCredentials),
      doneDocument: MemoryDocument(),
      notifier: FakeNotifier(),
      connect: relay.connect,
      cloudPost: (url, headers, body) async {
        asked.add((jsonDecode(body) as Map)['text'] as String);
        return 200;
      },
    );
  });

  /// The app, then the room: synced (as the relay's first frame), the computer online, and [agent] and [cloud] if given.
  Future<void> launch(
    WidgetTester tester, {
    AgentPending? agent,
    bool cloud = false,
    bool talkBack = false,
    double textScale = 1,
    bool dark = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
    if (talkBack) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    await tester.pumpWidget(
      MochiApp(
        model: model,
        bridge: bridge,
        notifier: FakeNotifier(),
        settings: settings,
        reader: UpdatesReader(engine: speech, focus: bridge, settings: settings, language: () => 'en-IN', announce: announced.add),
        opener: FakeOpener(),
        library: Future.value(null),
        speech: listener,
        homeWidget: HomeWidget(document: widgetDocument, surface: FakeWidgetSurface()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    relay.socket.deliver({'v': 1, 'op': 'sync', 'state': <Object?>[]});
    relay.devices(online: true);
    relay.presence(macOnline: true);
    relay.fromMac(LinkKey.look, sampleLook().toValue());
    if (agent != null) relay.fromMac(LinkKey.agent, agent.toValue());
    if (cloud) {
      relay.fromMac(
        LinkKey.cloud,
        const CloudTrigger(url: 'https://api.anthropic.com/v1/claude_code/routines/t/fire', token: 't').toValue(),
      );
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> go(WidgetTester tester, String place) async {
    bridge.placeController.add(place);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    await tester.pump(const Duration(seconds: 12));
  }

  testWidgets('Talk to Mochi (the tile, a shortcut): Mochi listens, with Send and Cancel', (tester) async {
    await launch(tester, agent: sampleAgent());
    await go(tester, 'talk');
    await tester.pump(const Duration(seconds: 1));
    expect(listener.listening, isTrue);
    expect(find.text('Listening… tap Send when you’re done'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
    expect(find.byTooltip('Cancel'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump();
    expect(listener.listening, isFalse);
    await finish(tester);
  });

  testWidgets("What's waiting: Updates opens and Mochi reads it in its own voice", (tester) async {
    await launch(tester, agent: sampleAgent());
    await go(tester, 'waiting:voice');
    expect(find.text('Updates'), findsOneWidget);
    expect(speech.spoken.first.text, '2 things are waiting for you.');
    expect(speech.spoken.map((line) => line.text), contains('Priya Sharma needs you: Invoice for October.'));
    expect(announced, isEmpty);
    await finish(tester);
  });

  testWidgets("What's waiting with TalkBack on: TalkBack reads it, so two voices never talk at once", (tester) async {
    await launch(tester, agent: sampleAgent(), talkBack: true);
    await go(tester, 'waiting');
    expect(speech.spoken, isEmpty);
    expect(announced.single, startsWith('2 things are waiting for you.'));
    await finish(tester);
  });

  testWidgets("What's waiting before the room has said: what the home-screen widget last showed", (tester) async {
    widgetDocument.json = WidgetSnapshot(
      room: 'room_1',
      host: 'your Mac',
      card: AgentPending(
        enabled: true,
        items: [AgentNote(id: 'mail:zz', source: AgentSource.gmail, title: 'Zoe', detail: 'Lunch?', important: false, at: now())],
        updatedAt: now(),
      ),
    ).toJson();
    await launch(tester);
    bridge.placeController.add('waiting');
    await tester.pump();
    // The room never sends its card: after a few seconds Mochi reads the widget's.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Updates'), findsOneWidget);
    expect(speech.spoken.map((line) => line.text), ['One thing is waiting for you.', 'From Zoe: Lunch.', "That's everything."]);
    await finish(tester);
  });

  testWidgets('Check now from Hey Google: Mochi Cloud checks and Mochi says so out loud', (tester) async {
    await launch(tester, agent: sampleAgent(), cloud: true);
    await go(tester, 'check:voice');
    expect(asked, ['check now']);
    expect(find.text('Asking Mochi Cloud… your news arrives as a notification in a minute or two.'), findsOneWidget);
    expect(speech.spoken.map((line) => line.text), ['Checking now.', "I'll send you a notification in a minute or two."]);
    await finish(tester);
  });

  testWidgets('Check now from a shortcut, without Mochi Cloud: the computer is asked, quietly', (tester) async {
    await launch(tester, agent: sampleAgent());
    await go(tester, 'check');
    expect(asked, isEmpty);
    expect(LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!.text, "What's pending?");
    expect(speech.spoken, isEmpty);
    await finish(tester);
  });

  testWidgets('Check now by voice, without Mochi Cloud: Mochi says it asked the computer, by name', (tester) async {
    await launch(tester, agent: sampleAgent());
    await go(tester, 'check:voice');
    expect(speech.spoken.single.text, 'Asking your Mac now.');
    await finish(tester);
  });

  for (final (dark, scale) in [(false, 1.0), (true, 2.0)]) {
    testWidgets('Settings › Hands-free: Add to Quick Settings asks Android (${dark ? 'dark' : 'light'}, ${scale}x)', (tester) async {
      final semantics = tester.ensureSemantics();
      bridge.tile = const TalkTileState(canAsk: true);
      await launch(tester, textScale: scale, dark: dark);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.scrollUntilVisible(find.text('Add to Quick Settings'), 300, scrollable: find.byType(Scrollable).last);
      expect(tester.getSemantics(find.text('Hands-free')).flagsCollection.isHeader, isTrue);
      expect(find.text('No tile yet'), findsOneWidget);
      expect(find.textContaining('It goes to your Mac'), findsOneWidget);
      expect(find.textContaining('work once Mochi comes from Google Play'), findsOneWidget);
      await tester.ensureVisible(find.text('Add to Quick Settings'));
      await tester.pump();
      await tester.tap(find.text('Add to Quick Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(bridge.tileRequests, 1);
      // On the page, and on the home page under it.
      expect(find.text('Added “Talk to Mochi” to Quick Settings.'), findsWidgets);
      expect(find.text('Tile added'), findsOneWidget);
      expect(find.text('Add to Quick Settings'), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await finish(tester);
    });
  }

  testWidgets('before Android 13 Settings says how to add the tile by hand', (tester) async {
    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.scrollUntilVisible(find.textContaining('tap the pencil'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('Add to Quick Settings'), findsNothing);
    await finish(tester);
  });
}
