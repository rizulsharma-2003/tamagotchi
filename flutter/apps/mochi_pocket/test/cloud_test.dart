import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/model/mochi_cloud.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';

import 'support/fakes.dart';

/// Mochi Cloud on the phone (A7): "Check now" straight to the cloud (or the computer first, and the cloud when it
/// doesn't answer), "Draft a reply…", the hourly cloud cards merged into "Waiting for you", and Settings › Mochi Cloud.
void main() {
  final mac = LinkHostName(platform: LinkPlatform.macOS);
  final pc = LinkHostName(platform: LinkPlatform.windows);
  const trigger = CloudTrigger(url: 'https://api.anthropic.com/v1/claude_code/routines/trig_1/fire', token: 'sk-ant-test-token');

  group('the trigger', () {
    test("only Anthropic's API over HTTPS gets the token", () {
      expect(MochiCloud.usable(trigger), same(trigger));
      for (final url in [
        'http://api.anthropic.com/v1/fire',
        'https://api.anthropic.com.evil.test/v1/fire',
        'https://example.com/v1/fire',
        'not a url',
      ]) {
        expect(
          MochiCloud.usable(CloudTrigger(url: url, token: 't')),
          isNull,
          reason: url,
        );
      }
      expect(MochiCloud.usable(const CloudTrigger(url: 'https://api.anthropic.com/v1/fire', token: '')), isNull);
      expect(MochiCloud.usable(null), isNull);
    });

    test("a trigger on this phone only for a development build's test room", () {
      const local = CloudTrigger(url: 'http://127.0.0.1:8789/fire', token: 't');
      expect(MochiCloud.usable(local), isNull);
      expect(MochiCloud.usable(local, allowLocal: true), same(local));
      expect(MochiCloud.usable(const CloudTrigger(url: 'http://10.0.0.2:8789/fire', token: 't'), allowLocal: true), isNull);
    });
  });

  group('firing it', () {
    test("the iPhone's request: the token as a bearer, the routine beta headers, the words as JSON", () async {
      final calls = <(Uri, Map<String, String>, String)>[];
      final logs = <String>[];
      final problem = await MochiCloud.fire(
        trigger,
        post: (url, headers, body) async {
          calls.add((url, headers, body));
          return 200;
        },
        host: mac,
        log: logs.add,
      );
      expect(problem, isNull);
      final (url, headers, body) = calls.single;
      expect(url.toString(), trigger.url);
      expect(headers['authorization'], 'Bearer sk-ant-test-token');
      expect(headers['anthropic-beta'], 'experimental-cc-routine-2026-04-01');
      expect(headers['anthropic-version'], '2023-06-01');
      expect(headers['content-type'], 'application/json');
      expect(jsonDecode(body), {'text': 'check now'});
      expect(logs.single, 'asked Mochi Cloud (check): HTTP 200');
      expect(logs.join(), isNot(contains('sk-ant')), reason: 'never the token');
    });

    test('what went wrong, naming the computer whose Settings hold the token', () async {
      Future<String?> answer(int status, LinkHostName host) =>
          MochiCloud.fire(trigger, post: (url, headers, body) async => status, host: host);
      expect(
        await answer(401, mac),
        'Mochi Cloud refused the request. Save a fresh API token on your Mac (Settings › Agent › Mochi Cloud).',
      );
      expect(await answer(403, pc), contains('on your PC'));
      expect(await answer(429, mac), 'Mochi Cloud is busy (too many requests this hour). Try again in a few minutes.');
      expect(await answer(500, mac), "Couldn't reach Mochi Cloud (HTTP 500).");
      expect(await answer(204, mac), isNull);
      final logs = <String>[];
      final offline = await MochiCloud.fire(
        trigger,
        post: (url, headers, body) async => throw const SocketExceptionStandIn(),
        host: mac,
        log: logs.add,
      );
      expect(offline, "Couldn't reach Mochi Cloud. Check the phone's connection and try again.");
      expect(logs.single, 'asking Mochi Cloud failed (SocketExceptionStandIn)');
    });

    test('a draft request: the thread, then one line of what to say, without angle brackets, at most 300 characters', () {
      expect(MochiCloud.draftRequest('18c2ab', ''), 'draft 18c2ab');
      expect(MochiCloud.draftRequest('18c2ab', '  say yes,\nThursday 3 pm <works>  '), 'draft 18c2ab say yes, Thursday 3 pm works');
      expect(MochiCloud.draftRequest('18c2ab', 'x' * 400), 'draft 18c2ab ${'x' * 300}');
      expect(MochiCloud.draftRequest('18c2ab', '👍' * 301)!.runes.length, 'draft 18c2ab '.length + 300);
      expect(MochiCloud.draftRequest(null, 'hi'), isNull);
      expect(MochiCloud.draftRequest('', 'hi'), isNull);
      expect(MochiCloud.draftRequest('18c2 ab', 'hi'), isNull);
      expect(MochiCloud.draftRequest('../x', 'hi'), isNull);
    });
  });

  group('cards from Mochi Cloud', () {
    final t = now();
    AgentNote mail(String id, {double? at, bool important = false}) =>
        AgentNote(id: 'mail:$id', source: AgentSource.gmail, title: id, detail: 'About $id', important: important, at: at ?? t - 60);
    final macCard = AgentPending(
      enabled: true,
      headline: 'From the Mac',
      items: [mail('a'), mail('b', important: true)],
      lookedAt: t - 600,
      updatedAt: t - 600,
    );

    test('an hourly cloud card only adds what it found that hour', () {
      final hourly = AgentPending(
        enabled: true,
        headline: 'From the cloud',
        items: [
          mail('c'),
          mail('a', at: t - 30),
        ],
        lookedAt: t - 10,
        updatedAt: t - 10,
        origin: 'cloud',
      );
      final merged = AgentCards.merge(macCard, hourly, now: t);
      expect(merged.items.map((note) => note.id), ['mail:b', 'mail:a', 'mail:c'], reason: 'needs-you first, then newest first');
      expect(merged.headline, 'From the cloud');
      expect([merged.lookedAt, merged.updatedAt, merged.origin], [t - 10, t - 10, 'cloud']);
      // Nothing new that hour: the computer's headline stays.
      final empty = AgentCards.merge(
        macCard,
        AgentPending(enabled: true, lookedAt: t, updatedAt: t, origin: 'cloud'),
        now: t,
      );
      expect(empty.items.length, 2);
      expect(empty.headline, 'From the Mac');
    });

    test('a "Check now" card from the cloud, or the computer\'s, is the whole day: it replaces the card', () {
      final manual = AgentPending(enabled: true, items: [mail('z')], updatedAt: t, origin: 'cloud-manual');
      expect(AgentCards.merge(macCard, manual, now: t), same(manual));
      final again = AgentPending(enabled: true, items: [mail('y')], updatedAt: t);
      expect(AgentCards.merge(manual, again, now: t), same(again));
    });

    test('meetings leave ten minutes after they start, the rest after 30 hours, at most eight, meetings first', () {
      final notes = [
        mail('old', at: t - 31 * 3600),
        AgentNote(id: 'cal:gone', source: AgentSource.calendar, title: 'Gone', detail: '', important: true, at: t, due: t - 700),
        AgentNote(id: 'cal:soon', source: AgentSource.calendar, title: 'Soon', detail: '', important: true, at: t, due: t + 600),
        AgentNote(id: 'cal:now', source: AgentSource.calendar, title: 'Now', detail: '', important: true, at: t, due: t - 300),
        for (var i = 0; i < 10; i++) mail('m$i', at: t - i),
      ];
      final kept = AgentCards.prune(notes, now: t).map((note) => note.id).toList();
      expect(kept, ['cal:now', 'cal:soon', 'mail:m0', 'mail:m1', 'mail:m2', 'mail:m3', 'mail:m4', 'mail:m5']);
    });
  });

  group('the model', () {
    late FakeRelay relay;
    late MemoryDocument hostDocument;
    late List<(Uri, Map<String, String>, String)> posts;
    late int status;
    late PocketModel model;

    PocketModel make({bool allowLocal = false, Duration silence = const Duration(milliseconds: 40)}) => PocketModel(
      credentialStore: MemoryCredentialStore(phoneCredentials),
      doneDocument: MemoryDocument(),
      hostDocument: hostDocument,
      notifier: FakeNotifier(),
      connect: relay.connect,
      cloudPost: (url, headers, body) async {
        posts.add((url, headers, body));
        return status;
      },
      allowLocalCloud: allowLocal,
      macSilence: silence,
    );

    setUp(() async {
      relay = FakeRelay();
      hostDocument = MemoryDocument();
      posts = [];
      status = 200;
      model = make();
      await model.load();
      await pumpEventQueue();
      relay.devices();
      await pumpEventQueue();
    });

    tearDown(() => model.dispose());

    String text(int index) => (jsonDecode(posts[index].$3) as Map)['text'] as String;

    test("the computer's trigger makes Mochi Cloud available; one that isn't Anthropic's doesn't", () async {
      expect(model.cloudAvailable, isFalse);
      relay.fromMac(LinkKey.cloud, trigger.toValue());
      await pumpEventQueue();
      expect([model.cloudAvailable, model.draftsAvailable], [true, true]);
      relay.fromMac(LinkKey.cloud, const CloudTrigger(url: 'https://example.com/fire', token: 't').toValue());
      await pumpEventQueue();
      expect(model.cloudAvailable, isFalse);
      relay.fromMac(LinkKey.cloud, const CloudTrigger(url: 'http://127.0.0.1:8789/fire', token: 't').toValue());
      await pumpEventQueue();
      expect(model.cloudAvailable, isFalse, reason: 'a local trigger only in the test room');
    });

    test("a development build's test room may use a trigger on the phone", () async {
      model.dispose();
      relay = FakeRelay();
      model = make(allowLocal: true);
      await model.load();
      await pumpEventQueue();
      relay.fromMac(LinkKey.cloud, const CloudTrigger(url: 'http://127.0.0.1:8789/fire', token: 't').toValue());
      await pumpEventQueue();
      expect(model.cloudAvailable, isTrue);
    });

    test('Check now straight to the cloud: one request, "checking" until its card comes, and not twice meanwhile', () async {
      relay.fromMac(LinkKey.cloud, trigger.toValue());
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await pumpEventQueue();
      expect(await model.checkNow(useCloud: true), CheckRoute.cloud);
      expect(posts.length, 1);
      expect(text(0), 'check now');
      expect(relay.sentValues(LinkKey.command), isEmpty, reason: 'the computer is not asked');
      expect(model.cloudChecking, isTrue);
      expect(await model.checkNow(useCloud: true), CheckRoute.busy);
      expect(posts.length, 1);
      // Mochi Cloud's answer: a "Check now" card, looked at after it was asked.
      final answer = AgentPending(
        enabled: true,
        items: sampleAgent().items,
        lookedAt: now() + 1,
        updatedAt: now() + 1,
        origin: 'cloud-manual',
      );
      relay.fromMac(LinkKey.agent, answer.toValue());
      await pumpEventQueue();
      expect(model.cloudChecking, isFalse);
      expect(model.checkedByCloud, isTrue);
      expect(model.cloudSeenAt, isNotNull);
      expect(hostDocument.json?['cloudSeenAt'], model.cloudSeenAt, reason: 'kept across launches');
    });

    test('a refused request says why, and Check now is free to try again', () async {
      relay.fromMac(LinkKey.cloud, trigger.toValue());
      await pumpEventQueue();
      status = 401;
      expect(await model.checkNow(useCloud: true), CheckRoute.failed);
      expect(model.cloudError, contains('Save a fresh API token on your Mac'));
      expect(model.cloudChecking, isFalse);
      status = 200;
      expect(await model.checkNow(useCloud: true), CheckRoute.cloud);
      expect(model.cloudError, isNull);
    });

    test('the computer first: "What\'s pending?", then Mochi Cloud when the computer stays silent', () async {
      relay.fromMac(LinkKey.cloud, trigger.toValue());
      await pumpEventQueue();
      var tookOver = 0;
      model.cloudTookOver.listen((_) => tookOver++);
      expect(await model.checkNow(useCloud: false), CheckRoute.computer);
      expect(LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!.text, "What's pending?");
      expect(posts, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(posts.length, 1);
      expect(text(0), 'check now');
      expect(tookOver, 1);
      expect(model.cloudChecking, isTrue);
    });

    test('the computer first, and it answers: Mochi Cloud stays out of it', () async {
      relay.fromMac(LinkKey.cloud, trigger.toValue());
      await pumpEventQueue();
      await model.checkNow(useCloud: false);
      final command = LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!;
      relay.fromMac(LinkKey.reply, LinkReply(id: command.id, state: 'working', at: now()).toValue());
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(posts, isEmpty);
    });

    test('without Mochi Cloud, Check now only asks the computer', () async {
      expect(await model.checkNow(useCloud: true), CheckRoute.computer);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(posts, isEmpty);
      expect(relay.sentValues(LinkKey.command).length, 1);
      expect(await model.checkInCloudNow(), "Mochi Cloud isn't set up yet. Set it up on your Mac (Settings › Agent).");
    });

    test('Draft a reply: the thread and what to say go to Mochi Cloud', () async {
      final email = sampleAgent().items.first;
      expect(await model.draftReply(email, 'say yes'), 'Set up Mochi Cloud on your Mac first (Settings › Agent › Mochi Cloud).');
      relay.fromMac(LinkKey.cloud, trigger.toValue());
      await pumpEventQueue();
      expect(await model.draftReply(email, 'say yes'), isNull);
      expect(text(0), 'draft 18c2 say yes');
      expect(await model.draftReply(sampleAgent().items.last, ''), "That email can't be found.", reason: 'a meeting has no thread');
      expect(model.cloudChecking, isFalse, reason: 'a draft is not a check');
    });

    test("cards: the newest wins, an hourly cloud card adds to the computer's, and an alert's card counts too", () async {
      final t = now();
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await pumpEventQueue();
      expect(model.waiting.length, 2);
      final hourly = AgentPending(
        enabled: true,
        items: [AgentNote(id: 'mail:new', source: AgentSource.gmail, title: 'Asha', detail: 'Lunch?', important: false, at: t)],
        lookedAt: t,
        updatedAt: t,
        origin: 'cloud',
      );
      relay.alert({
        'title': 'Mochi',
        'body': 'Asha: Lunch?',
        'userInfo': {'kind': 'agent', 'pending': hourly.toJson()},
      });
      await pumpEventQueue();
      expect(model.waiting.map((note) => note.id), containsAll(['mail:18c2', 'cal:review', 'mail:new']));
      expect(model.checkedByCloud, isTrue);
      // An older card (the room catching up late) doesn't undo it.
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      await pumpEventQueue();
      expect(model.waiting.length, 3);
    });
  });

  group('on screen', () {
    late FakeRelay relay;
    late PocketModel model;
    late AppSettings settings;
    late MemoryDocument settingsDocument;
    late List<String> asked;
    late int status;

    setUp(() {
      relay = FakeRelay();
      asked = [];
      status = 200;
      settingsDocument = MemoryDocument();
      settings = AppSettings(settingsDocument);
      model = PocketModel(
        credentialStore: MemoryCredentialStore(phoneCredentials),
        doneDocument: MemoryDocument(),
        notifier: FakeNotifier(),
        connect: relay.connect,
        cloudPost: (url, headers, body) async {
          asked.add((jsonDecode(body) as Map)['text'] as String);
          return status;
        },
      );
    });

    Future<void> launch(WidgetTester tester, {bool cloud = true, double textScale = 1}) async {
      tester.view.physicalSize = const Size(1080, 7200);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      final bridge = FakeBridge();
      await tester.pumpWidget(
        MochiApp(
          model: model,
          bridge: bridge,
          notifier: FakeNotifier(),
          settings: settings,
          reader: UpdatesReader(engine: FakeSpeechEngine(), focus: bridge, settings: settings, language: () => 'en-IN'),
          opener: FakeOpener(),
          library: Future.value(null),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      relay.devices();
      relay.presence(macOnline: false);
      relay.fromMac(LinkKey.look, sampleLook().toValue());
      relay.fromMac(LinkKey.agent, sampleAgent().toValue());
      if (cloud) relay.fromMac(LinkKey.cloud, trigger.toValue());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    /// The room never stops moving, so pump through a sheet's or page's transition instead of settling.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
    }

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await tester.pump(const Duration(seconds: 12));
    }

    testWidgets('Check now asks Mochi Cloud: Mochi says so, and the card says it is checking', (tester) async {
      await launch(tester);
      expect(find.textContaining('Only your Mac can check'), findsNothing);
      await tester.tap(find.text('Check now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(asked, ['check now']);
      expect(find.text('Asking Mochi Cloud… your news arrives as a notification in a minute or two.'), findsOneWidget);
      expect(find.text('Mochi Cloud is checking. Results arrive as a notification in a minute or two.'), findsOneWidget);
      expect(find.text('Checking…'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('Check now with the setting off goes to the computer first', (tester) async {
      settings.checkNowUsesCloud = false;
      await launch(tester);
      await tester.tap(find.text('Check now'));
      await tester.pump();
      expect(asked, isEmpty);
      expect(LinkCommand.fromValue(relay.sentValues(LinkKey.command).single)!.text, "What's pending?");
      await finish(tester);
    });

    testWidgets('without Mochi Cloud the card says how to set it up on the computer, by name', (tester) async {
      await launch(tester, cloud: false);
      expect(
        find.text("Only your Mac can check right now. Set up Mochi Cloud on your Mac (Settings › Agent) to check while it's off."),
        findsOneWidget,
      );
      await finish(tester);
    });

    testWidgets('a refusal shows on the card', (tester) async {
      status = 429;
      await launch(tester);
      await tester.tap(find.text('Check now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Mochi Cloud is busy (too many requests this hour). Try again in a few minutes.'), findsOneWidget);
      await finish(tester);
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('Draft a reply… from an email\'s menu (${scale}x text)', (tester) async {
        final semantics = tester.ensureSemantics();
        await launch(tester, textScale: scale);
        await tester.longPress(find.text('Priya Sharma'));
        await settle(tester);
        await tester.tap(find.text('Draft a reply…'));
        await settle(tester);
        expect(find.bySemanticsLabel('Draft a reply'), findsOneWidget);
        expect(tester.getSemantics(find.text('Draft a reply')).flagsCollection.isHeader, isTrue);
        expect(find.textContaining('It lands in Gmail Drafts: nothing is sent until you send it.'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'say yes, Thursday works');
        await tester.tap(find.text('Draft It'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(asked, ['draft 18c2 say yes, Thursday works']);
        expect(find.text("On its way. You'll get a notification when the draft is in Gmail (about a minute)."), findsOneWidget);
        expect(tester.takeException(), isNull);
        // It closes by itself.
        await tester.pump(const Duration(seconds: 2));
        await settle(tester);
        expect(find.text('Draft It'), findsNothing);
        semantics.dispose();
        await finish(tester);
      });
    }

    testWidgets("a meeting has no Draft a reply…, and neither has anything when Mochi Cloud isn't set up", (tester) async {
      await launch(tester, cloud: false);
      await tester.longPress(find.text('Priya Sharma'));
      await settle(tester);
      expect(find.text('Draft a reply…'), findsNothing);
      await tester.tap(find.text('Close'));
      await settle(tester);
      relay.fromMac(LinkKey.cloud, trigger.toValue());
      await tester.pump();
      await tester.longPress(find.text('Design review'));
      await settle(tester);
      expect(find.text('Draft a reply…'), findsNothing);
      await tester.tap(find.text('Close'));
      await settle(tester);
      await finish(tester);
    });

    testWidgets('Settings › Mochi Cloud: ready, never heard from, and where Check now goes', (tester) async {
      await launch(tester);
      await tester.tap(find.byTooltip('Settings'));
      await settle(tester);
      await tester.ensureVisible(find.text('Check now always asks Mochi Cloud'));
      await tester.pump();
      expect(find.text('Mochi Cloud'), findsOneWidget);
      expect(find.text('No news from the cloud yet'), findsOneWidget);
      expect(find.text('Check now without your Mac'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.textContaining('Check now goes straight to the cloud, whether your Mac is on or off.'), findsOneWidget);
      await tester.tap(find.byType(Switch).last);
      await tester.pump();
      expect(settings.checkNowUsesCloud, isFalse);
      expect(settingsDocument.json?['checkNowUsesCloud'], false);
      expect(find.textContaining('Check now asks your Mac first'), findsOneWidget);
      await finish(tester);
    });
  });
}

/// A connection failure without a real socket.
class SocketExceptionStandIn implements Exception {
  const SocketExceptionStandIn();
}
