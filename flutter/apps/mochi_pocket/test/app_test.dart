import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/live/live_updates.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/model/updates_history.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';

import 'support/fakes.dart';

void main() {
  late FakeRelay relay;
  late FakeNotifier notifier;
  late FakeOpener opener;
  late MemoryCredentialStore store;
  late List<LinkCredentials> leaves;
  late PocketModel model;
  late FakeBridge bridge;
  late MemoryDocument settingsDocument;
  late AppSettings settings;
  late FakeSpeechEngine speech;
  late UpdatesReader reader;
  late List<String> announced;
  late FakeLiveNotifier liveNotifier;

  setUp(() {
    bridge = FakeBridge();
    settingsDocument = MemoryDocument();
    settings = AppSettings(settingsDocument);
    speech = FakeSpeechEngine();
    announced = [];
    liveNotifier = FakeLiveNotifier();
    reader = UpdatesReader(engine: speech, focus: bridge, settings: settings, language: () => 'en-IN', announce: announced.add);
    relay = FakeRelay();
    notifier = FakeNotifier();
    opener = FakeOpener();
    store = MemoryCredentialStore();
    leaves = [];
    model = PocketModel(
      credentialStore: store,
      doneDocument: MemoryDocument(),
      notifier: notifier,
      connect: relay.connect,
      join: (code, name) async => phoneCredentials,
      leave: (credentials) async => leaves.add(credentials),
      deviceName: 'Test Phone',
    );
  });

  /// The app on a tall phone (360 × 2400 dp), so every card is laid out without scrolling.
  Future<void> launch(WidgetTester tester, {String? link, Future<String?> Function(BuildContext)? scan}) async {
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MochiApp(
        model: model,
        bridge: bridge..initial = link,
        notifier: notifier,
        settings: settings,
        reader: reader,
        opener: opener,
        library: Future.value(null),
        scan: scan,
        live: LiveUpdates(notifier: liveNotifier, record: MemoryDocument(), enabled: () async => settings.showOnLockScreen),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The Mac shares its state and is online (the relay lists the room first, as its `sync` does).
  Future<void> macShares(WidgetTester tester) async {
    relay.devices();
    relay.presence(macOnline: true);
    relay.fromMac(LinkKey.look, sampleLook().toValue());
    relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'working', category: 'edit').toValue());
    relay.fromMac(LinkKey.sessions, sampleSessions().toValue());
    relay.fromMac(LinkKey.agent, sampleAgent().toValue());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    model.dispose();
    await tester.pump(const Duration(seconds: 10));
  }

  testWidgets('unpaired: the pairing screen; scanning the Mac\'s code pairs and shows home', (tester) async {
    await launch(tester, scan: (_) async => pairingCode.url);
    expect(find.text('Pair with your Mac or PC'), findsOneWidget);
    expect(find.textContaining('Pair a Phone'), findsOneWidget);
    expect(find.textContaining('Settings › Phones'), findsOneWidget);
    await tester.tap(find.text('Scan the Code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(model.phase, PairingPhase.paired);
    expect(store.saved, phoneCredentials);
    // Named from the pairing code until the relay lists the room, then by what it is.
    expect(find.text('and Patch, from Test Mac'), findsOneWidget);
    relay.devices();
    await tester.pump();
    expect(find.text('and Patch, from your Mac'), findsOneWidget);
    expect(notifier.permissionRequests, 1, reason: 'notifications are asked for once paired');
    await finish(tester);
  });

  testWidgets('a mochi://pair link that opened the app pairs it', (tester) async {
    await launch(tester, link: pairingCode.url);
    await tester.pump(const Duration(milliseconds: 50));
    expect(model.phase, PairingPhase.paired);
    expect(find.text('Mochi'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('home mirrors the iPhone: name, Mac online, friendship, the room, actions, cards', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    // Before the relay lists the room, the computer is only known by the pairing code's name.
    expect(find.text('Connecting…').evaluate().isNotEmpty || find.text('Computer away').evaluate().isNotEmpty, isTrue);
    await macShares(tester);
    expect(find.text('Mochi'), findsOneWidget);
    expect(find.text('Mac online'), findsOneWidget);
    expect(find.text('Friendship 3'), findsOneWidget);
    expect(find.text('Tap Mochi to pet'), findsOneWidget);
    for (final action in ['Pet', 'Play', 'Treat', 'Type']) {
      expect(find.text(action), findsOneWidget);
    }
    expect(find.text('Waiting for you'), findsOneWidget);
    expect(find.text('Priya is waiting on the invoice.'), findsOneWidget);
    expect(find.text('Priya Sharma'), findsOneWidget);
    expect(find.text('Invoice for October'), findsOneWidget);
    expect(find.text('Join'), findsOneWidget, reason: 'the meeting has a video link');
    expect(find.text('Claude on your Mac'), findsOneWidget);
    expect(find.text('1 session'), findsOneWidget);
    expect(find.text('mac-Tamagotchi'), findsOneWidget);
    expect(find.text('Finished'), findsOneWidget);
    expect(find.text('Gave Mochi its own voice.'), findsOneWidget);
    expect(find.text('Push it'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the Mac away shows honestly, with when it left', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    relay.devices();
    relay.presence(macOnline: false, lastSeen: DateTime(2026, 11, 5, 14, 2).millisecondsSinceEpoch / 1000);
    await tester.pump();
    expect(find.textContaining('Mac away since'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a PC host is named as a PC', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    relay.devices(platform: 'windows', name: 'DESKTOP-7');
    relay.presence(macOnline: false, lastSeen: DateTime(2026, 11, 5, 14, 2).millisecondsSinceEpoch / 1000);
    await tester.pump();
    expect(find.textContaining('PC away since'), findsOneWidget);
    expect(find.text('and Patch, from your PC'), findsOneWidget);
    expect(find.text('Claude on your PC'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Type sends a command; the reply shows in the bubble and in Recently', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.text('Type'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Water the plants');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    final command = LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!;
    expect(command.text, 'Water the plants');
    expect(command.typed, isTrue);
    expect(find.text('Recently'), findsOneWidget);
    expect(find.text('Sending to your Mac…'), findsOneWidget);
    relay.fromMac(LinkKey.reply, LinkReply(id: command.id, state: 'working', at: now()).toValue());
    await tester.pump();
    expect(find.text('Your Mac is on it…'), findsOneWidget);
    relay.fromMac(LinkKey.reply, LinkReply(id: command.id, state: 'done', text: 'Watered them.', at: now()).toValue());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Watered them.'), findsNWidgets(2), reason: 'in the speech bubble and in Recently');
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Watered them.'), findsOneWidget, reason: 'the bubble goes after a few seconds');
    await finish(tester);
  });

  testWidgets('a reply to a session goes to that session', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.text('Push it'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Send to Claude'));
    await tester.pump();
    final command = LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!;
    expect(command.text, 'Push it');
    expect(command.project, 'mac-Tamagotchi');
    expect(command.session, 'session-1');
    expect(find.text('To Claude in mac-Tamagotchi'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Send to Claude? is answered with a verdict', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    relay.fromMac(
      LinkKey.approval,
      ApprovalRequest(
        id: 'approval-1',
        target: 'session-1',
        project: 'mac-Tamagotchi',
        message: 'Run the tests and push.',
        at: now(),
      ).toValue(),
    );
    await tester.pump();
    expect(find.text('Send to Claude?'), findsOneWidget);
    expect(find.text('Run the tests and push.'), findsOneWidget);
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(find.text('Send to Claude?'), findsNothing);
    final verdict = LinkVerdict.fromValue(relay.sentValues(LinkKey.verdict).single)!;
    expect(verdict.id, 'approval-1');
    expect(verdict.allow, isTrue);
    await finish(tester);
  });

  testWidgets('marking an update done shares it with the Mac, and Undo puts it back', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.byTooltip('Mark Priya Sharma done'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Priya Sharma'), findsNothing);
    expect(AgentDoneList.fromValue(relay.sentValues(LinkKey.phoneDone).last)?.ids.keys, ['mail:18c2']);
    await tester.tap(find.text('Undo'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Priya Sharma'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('tapping an update opens its link; Pet sends a pet to the Mac', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.text('Invoice for October'));
    await tester.pump();
    expect(opener.opened, ['https://mail.google.com/mail/u/0/#inbox/18c2']);
    await tester.tap(find.text('Pet'));
    await tester.pump();
    expect(LinkInteraction.fromValue(relay.sentValues(LinkKey.phoneInteraction).single)?.kind, 'pet');
    await finish(tester);
  });

  testWidgets('an alert from the Mac becomes a notification', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    relay.alert({'title': 'Claude finished', 'body': 'Tests pass.', 'userInfo': <String, Object?>{}});
    await tester.pump();
    expect(notifier.shown.single.body, 'Tests pass.');
    await finish(tester);
  });

  testWidgets('with an FCM address registered, Settings says notifications are on (Firebase)', (tester) async {
    model = PocketModel(
      credentialStore: store..saved = phoneCredentials,
      doneDocument: MemoryDocument(),
      notifier: notifier,
      connect: relay.connect,
      push: FakePushService(),
      deviceName: 'Test Phone',
    );
    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Notifications: on (Firebase)'), findsOneWidget);
    expect(relay.socket.sent.where((frame) => frame['op'] == 'register'), hasLength(1));
    await finish(tester);
  });

  testWidgets('the speaker on Waiting for you reads it aloud, and a second tap stops it', (tester) async {
    store.saved = phoneCredentials;
    speech.hold = true;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.byTooltip('Read out loud'));
    await tester.pump();
    expect(speech.spoken.first.text, '2 things are waiting for you.');
    expect(find.byTooltip('Stop reading'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop reading'));
    await tester.pump();
    expect(reader.speaking, isFalse);
    expect(speech.stops, 1);
    expect(find.byTooltip('Read out loud'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('with TalkBack on, the speaker hands the script to TalkBack', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.byTooltip('Read out loud'));
    await tester.pump();
    expect(announced.single, startsWith('2 things are waiting for you.'));
    expect(speech.spoken, isEmpty);
    await finish(tester);
  });

  testWidgets('Updates: Read aloud, and leaving the screen stops it', (tester) async {
    store.saved = phoneCredentials;
    speech.hold = true;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.text('Waiting for you'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Read aloud'));
    await tester.pump();
    expect(reader.speaking, isTrue);
    expect(find.text('Stop'), findsOneWidget);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(reader.speaking, isFalse);
    expect(speech.stops, 1);
    await finish(tester);
  });

  testWidgets("Updates with a week of history: earlier days show below, and Read aloud reads only what's waiting", (tester) async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1)).millisecondsSinceEpoch / 1000;
    model = PocketModel(
      credentialStore: store..saved = phoneCredentials,
      doneDocument: MemoryDocument(),
      historyDocument: MemoryDocument(
        (UpdatesHistory()..record([
              AgentNote(
                id: 'mail:bank',
                source: AgentSource.gmail,
                title: 'HDFC Bank',
                detail: 'Statement',
                important: false,
                at: yesterday,
              ),
            ], now: yesterday))
            .toJson(),
      ),
      notifier: notifier,
      connect: relay.connect,
      deviceName: 'Test Phone',
    );
    speech.hold = true;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.text('Waiting for you'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('HDFC Bank'), findsOneWidget);
    await tester.tap(find.text('Read aloud'));
    await tester.pump();
    expect(speech.spoken.first.text, '2 things are waiting for you.');
    // Holding an earlier update marks it done from the menu; the history says where.
    await tester.longPress(find.text('HDFC Bank'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Mark as done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(model.isDone('mail:bank'), isTrue);
    expect(find.textContaining('Done here ·'), findsOneWidget);
    expect(AgentDoneList.fromValue(relay.sentValues(LinkKey.phoneDone).last)?.ids.keys, ['mail:bank']);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await finish(tester);
  });

  testWidgets('Appearance: Dark and Light apply at once, override the phone, and are saved', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    Brightness brightness() => Theme.of(tester.element(find.text('Appearance'))).brightness;
    expect(brightness(), Brightness.light, reason: 'System, and the test phone is light');
    await tester.tap(find.text('Dark'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(brightness(), Brightness.dark);
    expect(settingsDocument.json?['appearance'], 'dark');
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.tap(find.text('Light'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(brightness(), Brightness.light, reason: 'Light, although the phone is dark');
    await tester.tap(find.text('System'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(brightness(), Brightness.dark, reason: 'System follows the phone again');
    await finish(tester);
  });

  testWidgets("Voice: the iPhone's characters, a sample, and the phone's English voices", (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Further down the page, under Hands-free.
    await tester.scrollUntilVisible(find.text('Hear a sample'), 300, scrollable: find.byType(Scrollable).last);
    for (final title in ['Mochi', 'Tiny', 'Calm', 'Plain']) {
      expect(find.widgetWithText(ChoiceChip, title), findsOneWidget);
    }
    expect(find.textContaining('Best on this phone (English (India) · ENA'), findsOneWidget);
    expect(find.text('Everything is spoken on this phone; nothing is sent anywhere.'), findsOneWidget);
    await tester.tap(find.text('Hear a sample'));
    await tester.pump();
    expect(speech.spoken.first.text, "Hi, I'm Mochi!");
    expect(speech.spoken.first.pitch, closeTo(1.224, 0.001));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Tiny'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(settings.character.name, 'tiny');
    expect(speech.spoken.last.pitch, closeTo(1.498, 0.001));
    await tester.tap(find.textContaining('Best on this phone'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('English (US) · SFG · High quality · needs the internet'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(settings.voiceName, 'en-us-x-sfg-network');
    expect(find.textContaining('This voice needs the internet'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('Lock screen: a sample per phase, and the switch turns Mochi off there and takes it away', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Lock screen'), findsOneWidget);
    expect(find.text('Show Mochi on my lock screen while Claude works'), findsOneWidget);
    expect(find.textContaining('while Claude works on your Mac'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Needs you'));
    await tester.pump();
    await tester.tap(find.text('Show on Lock Screen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(liveNotifier.last!.title, 'Claude needs you');
    expect(liveNotifier.last!.actions, ['open', 'session']);
    await tester.tap(find.byTooltip('Remove the sample'));
    await tester.pump();
    expect(liveNotifier.showing, isFalse);
    // Off: saved, and nothing stays.
    await tester.tap(find.text('Show on Lock Screen'));
    await tester.pump();
    // The lock screen's switch (Mochi Cloud has one further down).
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(settings.showOnLockScreen, isFalse);
    expect(settingsDocument.json?['showOnLockScreen'], false);
    expect(liveNotifier.showing, isFalse);
    expect(find.text('Show on Lock Screen'), findsNothing);
    await finish(tester);
  });

  testWidgets("Open the Session in Mochi's notification brings Claude's sessions into view", (tester) async {
    store.saved = phoneCredentials;
    tester.view.physicalSize = const Size(1080, 1800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MochiApp(model: model, bridge: bridge, notifier: notifier, settings: settings, reader: reader, library: Future.value(null)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await macShares(tester);
    final sessions = find.text('Claude on your Mac');
    expect(sessions, findsNothing, reason: 'below the first screen, so not built yet');
    bridge.placeController.add('sessions');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(sessions, findsOneWidget);
    final top = tester.getTopLeft(sessions).dy;
    expect(top, inInclusiveRange(0, 600), reason: 'on screen');
    await finish(tester);
  });

  testWidgets('Settings shows the pairing and the push note; Unpair goes back to pairing', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Paired with Test Mac (Mac)'), findsOneWidget);
    expect(find.text('Test Phone'), findsOneWidget);
    expect(find.text('relay.test'), findsOneWidget);
    // This model has no push service: Settings says alerts only come while the app is open, and why.
    expect(find.text('Notifications: only while Mochi is open'), findsOneWidget);
    expect(find.textContaining('push is not part of this build'), findsOneWidget);
    await tester.tap(find.text('Unpair'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Unpair from Test Mac?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Unpair'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Pair with your Mac or PC'), findsOneWidget);
    expect(store.saved, isNull);
    expect(leaves.single.device, 'dev_phone');
    await finish(tester);
  });

  testWidgets('removed from the room: a banner says so, and Pair Again goes back to pairing', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    relay.socket.drop(4004);
    await tester.pump();
    expect(find.text('Not paired'), findsOneWidget);
    expect(find.textContaining("isn't in Test Mac's room any more"), findsOneWidget);
    await tester.tap(find.text('Pair Again'));
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Pair with your Mac or PC'), findsOneWidget);
    expect(leaves, isEmpty, reason: 'the room is already gone');
    await finish(tester);
  });
}
