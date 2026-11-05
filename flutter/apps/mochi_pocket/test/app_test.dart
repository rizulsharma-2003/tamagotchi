import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';

import 'support/fakes.dart';

void main() {
  late FakeRelay relay;
  late FakeNotifier notifier;
  late FakeOpener opener;
  late MemoryCredentialStore store;
  late List<LinkCredentials> leaves;
  late PocketModel model;

  setUp(() {
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
        bridge: FakeBridge(initial: link),
        notifier: notifier,
        opener: opener,
        library: Future.value(null),
        scan: scan,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// The Mac shares its state and is online.
  Future<void> macShares(WidgetTester tester) async {
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
    expect(find.text('Pair with your Mac'), findsOneWidget);
    expect(find.textContaining('Pair Another Device'), findsOneWidget);
    await tester.tap(find.text('Scan the Code'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(model.phase, PairingPhase.paired);
    expect(store.saved, phoneCredentials);
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
    expect(find.text('Connecting…').evaluate().isNotEmpty || find.text('Mac away').evaluate().isNotEmpty, isTrue);
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
    relay.presence(macOnline: false, lastSeen: DateTime(2026, 11, 5, 14, 2).millisecondsSinceEpoch / 1000);
    await tester.pump();
    expect(find.textContaining('Mac away since'), findsOneWidget);
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

  testWidgets('Settings shows the pairing and the push note; Unpair goes back to pairing', (tester) async {
    store.saved = phoneCredentials;
    await launch(tester);
    await macShares(tester);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Paired with Test Mac'), findsOneWidget);
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
    expect(find.text('Pair with your Mac'), findsOneWidget);
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
    expect(find.text('Pair with your Mac'), findsOneWidget);
    expect(leaves, isEmpty, reason: 'the room is already gone');
    await finish(tester);
  });
}
