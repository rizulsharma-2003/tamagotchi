import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_home_widget/mochi_home_widget.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/live/live_push.dart';
import 'package:mochi_pocket/src/live/live_updates.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/model/done_marks.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/services/push/push_messages.dart';
import 'package:mochi_pocket/src/services/push/shown_alerts.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';
import 'package:mochi_pocket/src/widget/home_widget.dart';

import 'support/fakes.dart';

/// The home-screen widget, "Mochi & Claude" (A2): what it knows, what it says (naming the real computer), how pushes
/// keep it fresh while Mochi is closed (only for the room it shows), and Settings' Add to Home Screen.
void main() {
  final t = now();
  bool notDone(String id) => false;

  WidgetSnapshot snapshot({String host = 'your Mac', WidgetClaude? claude, AgentPending? card, List<PhoneSessionCard>? sessions}) =>
      WidgetSnapshot(
        room: 'room_1',
        petName: 'Mochi',
        host: host,
        claude: claude,
        sessions: sessions ?? sampleSessions().sessions,
        sessionsShared: true,
        card: card ?? sampleAgent(),
        updatedAt: t,
      );

  group('what it says', () {
    test('Claude working on a project: the project and the computer, the pose, and when to stop believing it', () {
      final view = HomeWidgetView.of(
        snapshot(
          claude: WidgetClaude(art: 'working', title: 'Claude is working', at: t, frame: 3),
          sessions: [
            PhoneSessionCard(id: 's2', project: 'mochi-link', phase: 'working', files: const []),
            ...sampleSessions().sessions,
          ],
        ),
        isDone: notDone,
        now: t,
      );
      expect([view['title'], view['text'], view['art'], view['frame']], ['Claude is working', 'mochi-link · on your Mac', 'working', 3]);
      expect(view['staleAtMs'], ((t + 30 * 60) * 1000).round());
      expect([view['restTitle'], view['restText'], view['restArt']], ['Claude is idle', 'On your Mac', 'idle']);
      expect(view['sessionsTitle'], 'Claude on your Mac');
      expect(view['host'], 'your Mac', reason: "the Quick Settings tile's description names it too");
      expect(view['sessions'], [
        {'project': 'mochi-link', 'status': 'Working', 'phase': 'working'},
        {'project': 'mac-Tamagotchi', 'status': 'Finished', 'phase': 'done'},
      ]);
    });

    test('a PC is "your PC" everywhere', () {
      final view = HomeWidgetView.of(
        snapshot(
          host: 'your PC',
          claude: WidgetClaude(art: 'done', title: 'Claude finished!', at: t),
        ),
        isDone: notDone,
        now: t,
      );
      // The session that just finished is named.
      expect([view['text'], view['sessionsTitle'], view['restText']], ['mac-Tamagotchi · on your PC', 'Claude on your PC', 'On your PC']);
      expect(view.containsKey('staleAtMs'), isFalse, reason: 'a finished turn stays true');
      final idle = HomeWidgetView.of(
        snapshot(
          host: 'your PC',
          claude: WidgetClaude(art: 'idle', title: 'Claude is idle', at: t),
        ),
        isDone: notDone,
        now: t,
      );
      expect(idle['text'], 'On your PC');
    });

    test('waiting: what you marked done and meetings that started ten minutes ago are left out', () {
      final card = AgentPending(
        enabled: true,
        items: [
          ...sampleAgent().items,
          AgentNote(id: 'cal:old', source: AgentSource.calendar, title: 'Standup', detail: '', important: true, at: t, due: t - 700),
          AgentNote(id: 'notion:t', source: AgentSource.notion, title: 'Release notes', detail: 'Due today', important: false, at: t),
        ],
        updatedAt: t,
      );
      final view = HomeWidgetView.of(
        snapshot(card: card),
        isDone: (id) => id == 'mail:18c2',
        now: t,
      );
      final items = (view['items']! as List).cast<Map<String, Object?>>();
      expect(items.map((item) => item['text']), ['Design review', 'Release notes · Due today']);
      expect(items.first['kind'], 'calendar');
      final due = card.items[1].due!;
      expect(items.first['dueMs'], (due * 1000).round(), reason: "the widget writes the time the phone's way");
      expect(items.first['leavesMs'], ((due + 600) * 1000).round());
      expect(view['waitingKnown'], isTrue);
      expect(view['emptyText'], 'Nothing waiting. Mochi will tell you when something comes in.');
    });

    test('an email is who and what about; a VIP is marked', () {
      final view = HomeWidgetView.of(snapshot(), isDone: notDone, now: t);
      final mail = (view['items']! as List).cast<Map<String, Object?>>().first;
      expect(mail, containsPair('text', 'Priya Sharma: Invoice for October'));
      expect(mail, containsPair('vip', true));
      expect(mail, containsPair('important', true));
    });

    test('summaries off or no card: no sessions, no waiting list', () {
      final view = HomeWidgetView.of(
        WidgetSnapshot(room: 'room_1', host: 'your Mac', sessions: sampleSessions().sessions, sessionsShared: false, updatedAt: t),
        isDone: notDone,
        now: t,
      );
      expect(view['sessions'], isEmpty);
      expect(view['waitingKnown'], isFalse);
      expect([view['title'], view['text']], ['Mochi & Claude', 'On your Mac']);
    });

    test('the computer away: it says so, and Mochi naps', () {
      final away = WidgetSnapshot(
        room: 'room_1',
        host: 'your Mac',
        hostAway: true,
        claude: WidgetClaude(art: 'working', title: 'x', at: t),
      );
      final view = HomeWidgetView.of(away, isDone: notDone, now: t);
      expect([view['title'], view['text'], view['art']], ['Your Mac is away', 'Mochi is napping', 'asleep']);
    });

    test('not paired: it says how to start', () {
      final view = HomeWidgetView.of(
        const WidgetSnapshot(petName: 'Mochi'),
        isDone: notDone,
        now: t,
      );
      expect(
        [view['paired'], view['title'], view['text']],
        [false, "Mochi isn't paired yet", 'Open Mochi and pair it with your Mac or PC.'],
      );
    });

    test('kept as JSON and read back the same', () {
      final before = snapshot(
        claude: WidgetClaude(art: 'waiting', title: 'Claude needs you', at: t, frame: 7),
      );
      final after = WidgetSnapshot.fromJson(before.toJson())!;
      expect(after.toJson(), before.toJson());
      expect(WidgetSnapshot.fromJson(null), isNull);
    });
  });

  group('from pushes', () {
    LinkAlert alert(Map<String, Object?> userInfo) =>
        LinkAlert(id: 'a1', from: 'dev_mac', title: 'Mochi', body: 'news', userInfo: userInfo);

    test("Mochi's news: the computer's card replaces, an hourly cloud card adds, an older card is ignored", () {
      final base = snapshot();
      final newer = AgentPending(
        enabled: true,
        items: [AgentNote(id: 'mail:z', source: AgentSource.gmail, title: 'Zoe', detail: 'Hi', important: false, at: t)],
        updatedAt: t + 10,
      );
      expect(base.withAlert(alert({'pending': newer.toJson()}), now: t).card!.items.map((note) => note.id), ['mail:z']);
      final hourly = AgentPending(enabled: true, items: newer.items, updatedAt: t + 10, origin: 'cloud');
      expect(base.withAlert(alert({'pending': hourly.toJson()}), now: t).card!.items.length, 3);
      final older = AgentPending(enabled: true, items: newer.items, updatedAt: t - 9999);
      expect(base.withAlert(alert({'pending': older.toJson()}), now: t).card!.items.length, 2);
    });

    test('a finished turn moves its session to the top with its new status', () {
      final turn = PhoneSessionCard(id: 'session-1', project: 'mac-Tamagotchi', phase: 'waiting', files: const [], finishedAt: t);
      final next = snapshot(
        sessions: [
          PhoneSessionCard(id: 's0', project: 'other', phase: 'idle', files: const []),
          ...sampleSessions().sessions,
        ],
      ).withAlert(alert({'card': turn.toJson()}), now: t);
      expect(next.sessions.map((session) => '${session.id}:${session.phase}'), ['session-1:waiting', 's0:idle']);
    });

    test("Claude's Live Activity: the pose and the words; a title that didn't open is said the widget's way", () {
      final apns = macLiveActivity('update', 'waiting', timestamp: t.round(), frame: 6, alert: true);
      final opened = LinkLiveActivity.fromApns(apns, liveActivityKey: liveActivityKey, id: 'la1')!;
      final next = snapshot().withLiveActivity(opened, now: t);
      expect([next.claude!.art, next.claude!.frame, next.claude!.title], ['waiting', 6, 'Claude needs you']);
      final sealedElsewhere = LinkLiveActivity.fromApns(
        macLiveActivity(
          'update',
          'working',
          timestamp: t.round(),
          title: 'Claude is busy',
          key: LinkCrypto.liveActivityKey(LinkCrypto.newRoomKey()),
        ),
        liveActivityKey: liveActivityKey,
        id: 'la2',
      )!;
      expect(snapshot().withLiveActivity(sealedElsewhere, now: t).claude!.title, 'Claude is working');
    });
  });

  group('the widget', () {
    late FakeWidgetSurface surface;
    late MemoryDocument document;
    late HomeWidget widget;

    setUp(() {
      surface = FakeWidgetSurface();
      document = MemoryDocument();
      widget = HomeWidget(document: document, surface: surface);
    });

    test('drawn once for the same view, and kept for the push handler', () async {
      final same = snapshot();
      await widget.publish(same, isDone: notDone);
      await widget.publish(same, isDone: notDone);
      expect(surface.shown.length, 1);
      expect(document.json?['room'], 'room_1');
      await widget.publish(same, isDone: notDone, force: true);
      expect(surface.shown.length, 2);
    });

    test('the push handler updates it only for the room it shows', () async {
      await widget.publish(snapshot(), isDone: notDone);
      final done = MemoryDocument(DoneMarks(done: {'mail:18c2': t}).toJson());
      final card = AgentPending(enabled: true, items: sampleAgent().items, updatedAt: t + 5);
      final message = LinkAlert(id: 'a', from: 'dev_mac', userInfo: {'pending': card.toJson()});
      expect(await widget.alertArrived('room_other', message, done: done), isFalse);
      expect(surface.shown.length, 1);
      expect(await widget.alertArrived('room_1', message, done: done), isTrue);
      final items = (surface.shown.last['items']! as List).cast<Map<String, Object?>>();
      expect(items.map((item) => item['text']), ['Design review'], reason: 'done here, so gone from the widget');
    });

    test('marked done from a notification: it leaves the widget', () async {
      await widget.publish(snapshot(), isDone: notDone);
      expect(await widget.doneChanged('room_1', done: MemoryDocument(DoneMarks(done: {'cal:review': t}).toJson())), isTrue);
      expect((surface.shown.last['items']! as List).length, 1);
    });

    test('an unpaired phone takes no pushes', () async {
      await widget.publish(const WidgetSnapshot(), isDone: notDone);
      expect(await widget.doneChanged('room_1', done: MemoryDocument()), isFalse);
    });

    test('an alert push opened by the push handler reaches the widget, with its room', () async {
      await widget.publish(snapshot(), isDone: notDone);
      final card = AgentPending(
        enabled: true,
        items: [AgentNote(id: 'mail:n', source: AgentSource.gmail, title: 'Neha', detail: 'Lunch?', important: false, at: t)],
        updatedAt: t + 60,
      );
      final outcome = await PushMessages.handle(
        alertPush('p1', {
          'title': 'Mochi',
          'body': 'Neha: Lunch?',
          'userInfo': {'kind': 'agent', 'pending': card.toJson()},
        }),
        credentials: () async => phoneCredentials,
        notifier: FakeNotifier(),
        shown: MemoryShownAlerts(),
        opened: (alert, room) async => widget.alertArrived(room, alert, done: MemoryDocument()),
      );
      expect(outcome, PushOutcome.shown);
      expect((surface.shown.last['items']! as List).single, containsPair('text', 'Neha: Lunch?'));
    });

    test('a Live Activity push reaches the widget even with Mochi off the lock screen', () async {
      await widget.publish(snapshot(), isDone: notDone);
      final live = LiveUpdates(notifier: FakeLiveNotifier(), record: MemoryDocument(), enabled: () async => false);
      final outcome = await LivePush.handle(
        livePush('l1', macLiveActivity('start', 'working', timestamp: t.round(), frame: 2)),
        credentials: () async => phoneCredentials,
        live: live,
        host: (_) => LinkHostName(platform: LinkPlatform.macOS),
        opened: (activity, room) async => widget.liveActivityArrived(room, activity, done: MemoryDocument()),
      );
      expect(outcome, LiveOutcome.off);
      expect([surface.shown.last['title'], surface.shown.last['art'], surface.shown.last['frame']], ['Claude is working', 'working', 2]);
    });
  });

  group('following the app', () {
    late FakeRelay relay;
    late PocketModel model;
    late FakeWidgetSurface surface;
    late HomeWidgetSync sync;

    setUp(() async {
      relay = FakeRelay();
      surface = FakeWidgetSurface();
      model = PocketModel(
        credentialStore: MemoryCredentialStore(phoneCredentials),
        doneDocument: MemoryDocument(),
        notifier: FakeNotifier(),
        connect: relay.connect,
      );
      sync = HomeWidgetSync(
        model: model,
        widget: HomeWidget(document: MemoryDocument(), surface: surface),
        settle: const Duration(milliseconds: 10),
      )..start();
    });

    tearDown(() {
      sync.dispose();
      model.dispose();
    });

    test('nothing while the pairing loads; then the room as it changes, gathered for a moment', () async {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(surface.shown, isEmpty);
      await model.load();
      await pumpEventQueue();
      relay.devices(platform: 'windows', name: 'DESKTOP-7', online: true);
      relay.presence(macOnline: true);
      relay.fromMac(LinkKey.look, sampleLook(petName: 'Bun').toValue());
      relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'waiting').toValue());
      relay.fromMac(LinkKey.sessions, sampleSessions().toValue());
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final view = surface.shown.last;
      expect([view['title'], view['text'], view['sessionsTitle']], ['Claude needs you', 'On your PC', 'Claude on your PC']);
      expect(view['emptyText'], contains('Bun will tell you'));
      final drawn = surface.shown.length;
      model.markDone(['mail:18c2']);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(surface.shown.length, drawn + 1);
      expect((surface.shown.last['items']! as List).length, 1);
      // The PC goes to sleep.
      relay.presence(macOnline: false);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect([surface.shown.last['title'], surface.shown.last['art']], ['Your PC is away', 'asleep']);
    });

    test('until the room has said it since launch, what the widget showed before stays (same room only)', () async {
      sync.dispose();
      final before = WidgetSnapshot(
        room: 'room_1',
        petName: 'Bun',
        host: 'your Mac',
        claude: WidgetClaude(art: 'waiting', title: 'Claude needs you', at: t),
        card: sampleAgent(),
        updatedAt: t - 600,
      );
      sync = HomeWidgetSync(
        model: model,
        widget: HomeWidget(document: MemoryDocument(before.toJson()), surface: surface),
        settle: const Duration(milliseconds: 10),
      )..start();
      await model.load();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final view = surface.shown.last;
      expect([view['title'], view['waitingKnown'], (view['items']! as List).length], ['Claude needs you', true, 2]);
      expect(view['emptyText'], contains('Bun'));
      relay.fromMac(LinkKey.agent, AgentPending(enabled: true, updatedAt: t + 1).toValue());
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(surface.shown.last['items'], isEmpty, reason: "the room's own card wins once it comes");
    });

    test('unpaired: the widget says so', () async {
      await model.load();
      await pumpEventQueue();
      await model.unpair();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(surface.shown.last['paired'], isFalse);
    });
  });

  group('in the app', () {
    late FakeWidgetSurface surface;
    late FakeBridge bridge;
    late PocketModel model;
    late FakeRelay relay;

    Future<void> launch(WidgetTester tester, {double textScale = 1, bool dark = false}) async {
      tester.view.physicalSize = const Size(1080, 7200);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      surface = FakeWidgetSurface();
      bridge = FakeBridge();
      relay = FakeRelay();
      final settings = AppSettings(MemoryDocument());
      model = PocketModel(
        credentialStore: MemoryCredentialStore(phoneCredentials),
        doneDocument: MemoryDocument(),
        notifier: FakeNotifier(),
        connect: relay.connect,
      );
      await tester.pumpWidget(
        MochiApp(
          model: model,
          bridge: bridge,
          notifier: FakeNotifier(),
          settings: settings,
          reader: UpdatesReader(engine: FakeSpeechEngine(), focus: bridge, settings: settings, language: () => 'en-IN'),
          opener: FakeOpener(),
          homeWidget: HomeWidget(document: MemoryDocument(), surface: surface),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      relay.devices();
      relay.presence(macOnline: true);
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await tester.pump();
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await tester.pump(const Duration(seconds: 1));
    }

    for (final (dark, scale) in [(false, 1.0), (true, 2.0)]) {
      testWidgets(
        'Settings › Home screen: not added yet, then Add to Home Screen asks the launcher (${dark ? 'dark' : 'light'}, ${scale}x)',
        (tester) async {
          final semantics = tester.ensureSemantics();
          await launch(tester, textScale: scale, dark: dark);
          surface.placement = const HomeWidgetPlacement(canPin: true);
          await tester.tap(find.byTooltip('Settings'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 600));
          await tester.ensureVisible(find.text('Home screen'));
          await tester.pump();
          expect(tester.getSemantics(find.text('Home screen')).flagsCollection.isHeader, isTrue);
          expect(find.text('No widget yet'), findsOneWidget);
          expect(find.textContaining('what Claude is doing on your Mac'), findsOneWidget);
          await tester.tap(find.text('Add to Home Screen'));
          await tester.pump();
          expect(surface.pins, 1);
          expect(tester.takeException(), isNull);
          semantics.dispose();
          await finish(tester);
        },
      );
    }

    testWidgets("without the launcher's help, Settings says how to add it", (tester) async {
      await launch(tester);
      surface.placement = const HomeWidgetPlacement(placed: 1);
      await tester.tap(find.byTooltip('Settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Widget added'), findsOneWidget);
      expect(find.text('To add it: long-press your home screen, tap Widgets, and find Mochi.'), findsOneWidget);
      expect(find.text('Add to Home Screen'), findsNothing);
      await finish(tester);
    });

    testWidgets('a tap on the widget\'s "Waiting for you" opens Updates; on Mochi, the top', (tester) async {
      await launch(tester);
      bridge.placeController.add('updates');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Updates'), findsOneWidget);
      bridge.placeController.add('home');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Updates'), findsNothing);
      await finish(tester);
    });
  });
}

/// The widget without a phone: what it was asked to draw, and the launcher's answers.
class FakeWidgetSurface implements WidgetSurface {
  final List<Map<String, Object?>> shown = [];
  HomeWidgetPlacement placement = const HomeWidgetPlacement();
  int pins = 0;

  @override
  Future<void> show(Map<String, Object?> view) async => shown.add(view);

  @override
  Future<bool> pin() async {
    pins++;
    return placement.canPin;
  }

  @override
  Future<HomeWidgetPlacement> status() async => placement;
}
