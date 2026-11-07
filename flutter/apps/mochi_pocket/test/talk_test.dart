import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/talk/speech_listener.dart';
import 'package:mochi_pocket/src/talk/talk_model.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';

import 'support/fakes.dart';

/// Hold to talk (A3), as on the iPhone (TalkModel, PhoneListener): with a fake recognizer and the fake relay as the Mac.
void main() {
  late FakeRelay relay;
  late FakeSpeechListener speech;
  late PocketModel model;
  late TalkModel talk;

  Future<void> start(WidgetTester tester, {bool paired = true}) async {
    relay = FakeRelay();
    speech = FakeSpeechListener();
    model = PocketModel(
      credentialStore: MemoryCredentialStore(paired ? phoneCredentials : null),
      doneDocument: MemoryDocument(),
      notifier: FakeNotifier(),
      connect: relay.connect,
    );
    talk = TalkModel(model: model, listener: speech, haptics: false);
    await model.load();
    await tester.pump();
    if (paired) {
      relay.devices(platform: 'macOS', name: 'BELPL-LT-636', online: true);
      relay.presence(macOnline: true);
      await tester.pump();
    }
  }

  Future<void> finish(WidgetTester tester) async {
    talk.dispose();
    model.dispose();
    await tester.pump(const Duration(seconds: 60));
  }

  /// What the phone sent as commands.
  List<LinkCommand> commands() => [for (final value in relay.sentValues(LinkKey.command)) LinkCommand.fromValue(value)!];

  testWidgets('hold: Mochi listens, shows the words as they come, and letting go sends them spoken; the answer comes back', (tester) async {
    await start(tester);
    unawaited(talk.earHeld());
    await tester.pump();
    expect([talk.phase, talk.bubble, talk.isHolding], [TalkPhase.approaching, "I'm listening…", true]);
    expect(speech.starts, 1);
    await tester.pump(const Duration(milliseconds: 800));
    expect(talk.phase, TalkPhase.listening, reason: 'once Mochi has turned its ear');
    speech.say('what is');
    speech.say("what's pending");
    expect([talk.transcript, talk.bubble], ["what's pending", "what's pending"]);

    unawaited(talk.earReleased());
    await tester.pump();
    expect(talk.phase, TalkPhase.sending);
    expect(talk.bubble, '“what\'s pending”');
    final sent = commands().single;
    expect([sent.text, sent.typed], ["what's pending", false]);
    expect(model.exchanges.single.text, "what's pending");

    await tester.pump(const Duration(milliseconds: 1100));
    expect([talk.phase, talk.bubble], [TalkPhase.waiting, 'Sending to your Mac…']);
    relay.fromMac(LinkKey.reply, LinkReply(id: sent.id, state: 'working', at: now()).toValue());
    await tester.pump();
    expect(talk.bubble, 'Your Mac is on it…');
    relay.fromMac(LinkKey.reply, LinkReply(id: sent.id, state: 'done', text: 'Two things are waiting.', at: now()).toValue());
    await tester.pump();
    expect([talk.phase, talk.bubble], [TalkPhase.replied, 'Two things are waiting.']);
    await tester.pump(const Duration(seconds: 8));
    expect([talk.phase, talk.bubble], [TalkPhase.idle, null]);
    await finish(tester);
  });

  testWidgets("nothing heard: Mochi says so and sends nothing; the recognizer's own last words win", (tester) async {
    await start(tester);
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    unawaited(talk.earReleased());
    await tester.pump();
    expect([talk.phase, talk.bubble], [TalkPhase.idle, "I didn't catch that. Hold me and talk."]);
    expect(commands(), isEmpty);
    await tester.pump(const Duration(seconds: 3));
    expect(talk.bubble, isNull);

    // The recognizer finishes the sentence after you let go.
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech
      ..say('run the')
      ..finalWords = 'run the tests';
    unawaited(talk.earReleased());
    await tester.pump();
    expect(commands().single.text, 'run the tests');
    await finish(tester);
  });

  testWidgets('slide away and let go: cancelled, nothing sent; slide back and it sends', (tester) async {
    await start(tester);
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech.say('never mind');
    talk.slid(away: true);
    expect(talk.cancelArmed, isTrue);
    unawaited(talk.earReleased());
    await tester.pump();
    expect([talk.phase, talk.bubble, speech.cancels > 0], [TalkPhase.idle, null, true]);
    expect(commands(), isEmpty);

    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech.say('play a song');
    talk
      ..slid(away: true)
      ..slid(away: false);
    unawaited(talk.earReleased());
    await tester.pump();
    expect(commands().single.text, 'play a song');
    await finish(tester);
  });

  testWidgets('a tap (or Stop) while waiting cancels: a late answer changes nothing', (tester) async {
    await start(tester);
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech.say('check my mail');
    unawaited(talk.earReleased());
    await tester.pump(const Duration(seconds: 2));
    expect(talk.isBusy, isTrue);
    talk.cancel();
    expect([talk.phase, talk.bubble], [TalkPhase.idle, null]);
    relay.fromMac(LinkKey.reply, LinkReply(id: commands().single.id, state: 'done', text: 'Late', at: now()).toValue());
    await tester.pump();
    expect([talk.phase, talk.bubble], [TalkPhase.idle, null]);
    await finish(tester);
  });

  testWidgets("the iPhone's 45 s: a computer that doesn't answer is named", (tester) async {
    await start(tester);
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech.say('hello');
    unawaited(talk.earReleased());
    await tester.pump(const Duration(milliseconds: 1100));
    expect(talk.phase, TalkPhase.waiting);
    await tester.pump(const Duration(seconds: 44));
    expect(talk.phase, TalkPhase.waiting);
    await tester.pump(const Duration(seconds: 2));
    expect([talk.phase, talk.bubble], [TalkPhase.failed, "Your Mac didn't answer. Is it awake and online?"]);
    await tester.pump(const Duration(seconds: 5));
    expect(talk.phase, TalkPhase.idle);
    await finish(tester);
  });

  testWidgets('the microphone is asked for in context: on the first hold, then hold again; tap to talk carries on', (tester) async {
    await start(tester);
    speech
      ..access_ = MicAccess.ask
      ..asking = Completer();
    unawaited(talk.earHeld());
    await tester.pump();
    expect(speech.requests, 1);
    // Android's question takes the finger away.
    talk.fingerLost();
    unawaited(talk.earReleased());
    speech.answerAccess(MicAccess.granted);
    await tester.pump();
    expect([talk.phase, talk.bubble], [TalkPhase.idle, 'Thanks! Now press and hold me and talk.']);
    expect([speech.starts, commands()], [0, isEmpty]);

    // Tap to talk (no finger to lose): listening starts right after the answer.
    speech
      ..access_ = MicAccess.ask
      ..asking = Completer();
    unawaited(talk.earHeld(byTap: true));
    await tester.pump();
    speech.answerAccess(MicAccess.granted);
    await tester.pump(const Duration(seconds: 1));
    expect([talk.phase, talk.byTap, speech.starts], [TalkPhase.listening, true, 1]);
    speech.say('what time is it');
    unawaited(talk.earReleased());
    await tester.pump();
    expect(commands().single.text, 'what time is it');
    await finish(tester);
  });

  testWidgets("a refused microphone says so; one refused for good offers Mochi's settings", (tester) async {
    await start(tester);
    speech
      ..access_ = MicAccess.ask
      ..afterAsking = MicAccess.ask;
    unawaited(talk.earHeld(byTap: true));
    await tester.pump();
    expect([talk.phase, talk.microphoneBlocked], [TalkPhase.failed, false]);
    expect(talk.bubble, "I can't hear you without the microphone. Hold me again to allow it.");

    speech.access_ = MicAccess.blocked;
    unawaited(talk.earHeld());
    await tester.pump();
    expect([talk.phase, talk.microphoneBlocked], [TalkPhase.failed, true]);
    expect(talk.bubble, "I can't hear you: allow the microphone for Mochi in Android's settings.");
    expect(speech.requests, 1, reason: "Android can't ask again: no question");
    await talk.openSettings();
    expect(speech.settings, 1);
    await finish(tester);
  });

  testWidgets("no recognizer, or one that fails while listening: Mochi says what's wrong", (tester) async {
    await start(tester);
    speech.startProblem = const SpeechProblem("Talking to Mochi needs a speech recognizer on this phone (Google's speech services).");
    unawaited(talk.earHeld());
    await tester.pump();
    expect([talk.phase, talk.bubble], [TalkPhase.failed, speech.startProblem!.message]);

    speech.startProblem = null;
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech.problemController.add(SpeechProblem(PlatformSpeechListener.explain(2)));
    await tester.pump();
    expect(
      [talk.phase, talk.bubble],
      [TalkPhase.failed, "I couldn't hear you: your phone's speech recognizer needs the internet right now."],
    );
    expect(PlatformSpeechListener.explain(9), contains('allow the microphone'));
    expect(PlatformSpeechListener.explain(12), contains('language'));
    await finish(tester);
  });

  testWidgets('unpaired: Mochi says to pair first instead of waiting', (tester) async {
    await start(tester, paired: false);
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech.say('hello');
    unawaited(talk.earReleased());
    await tester.pump();
    expect([talk.phase, talk.bubble], [TalkPhase.failed, 'Pair me with your Mac or PC first: Settings › Mochi Link.']);
    await finish(tester);
  });

  testWidgets('leaving the app while held cancels: nothing half-heard is sent', (tester) async {
    await start(tester);
    unawaited(talk.earHeld());
    await tester.pump(const Duration(seconds: 1));
    speech.say('delete everything');
    talk.paused();
    expect([talk.phase, speech.listening], [TalkPhase.idle, false]);
    expect(commands(), isEmpty);
    await finish(tester);
  });

  group('the platform recognizer', () {
    const channel = MethodChannel('com.insideedge.mochi/speech');
    final calls = <String>[];

    Future<void> fromAndroid(WidgetTester tester, String method, Map<String, Object?> arguments) => tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, channel.codec.encodeMethodCall(MethodCall(method, arguments)), (_) {});

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'available' => {'available': true, 'onDevice': true},
          'access' => 'blocked',
          'start' => true,
          _ => null,
        };
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    testWidgets('streams the words, ends with the last ones, and never waits more than two seconds', (tester) async {
      final listener = PlatformSpeechListener();
      expect(await listener.access(), MicAccess.blocked);
      final heard = <String>[];
      await listener.start(heard: heard.add);
      await fromAndroid(tester, 'heard', {'text': 'turn on'});
      await fromAndroid(tester, 'heard', {'text': 'turn on the lights'});
      expect(heard, ['turn on', 'turn on the lights']);

      String? last;
      unawaited(listener.stop().then((words) => last = words));
      await tester.pump();
      await fromAndroid(tester, 'done', {'text': 'turn on the lights please'});
      await tester.pump();
      expect(last, 'turn on the lights please');

      // The recognizer never answers: the words so far, after two seconds.
      await listener.start(heard: heard.add);
      await fromAndroid(tester, 'heard', {'text': 'are you there'});
      last = null;
      unawaited(listener.stop().then((words) => last = words));
      await tester.pump(const Duration(milliseconds: 1900));
      expect(last, isNull);
      await tester.pump(const Duration(milliseconds: 200));
      expect(last, 'are you there');
      expect(calls, containsAllInOrder(['access', 'available', 'start', 'stop', 'cancel']));
    });

    testWidgets('no speech recognizer on the phone: a problem to show', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'available' ? {'available': false} : null,
      );
      await expectLater(PlatformSpeechListener().start(heard: (_) {}), throwsA(isA<SpeechProblem>()));
    });
  });

  group('on the home screen', () {
    Future<(PocketModel, FakeRelay, FakeSpeechListener)> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final relay = FakeRelay();
      final speech = FakeSpeechListener();
      final bridge = FakeBridge();
      final settings = AppSettings(MemoryDocument());
      final model = PocketModel(
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
          library: Future.value(null),
          speech: speech,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      relay.devices(platform: 'macOS', name: 'BELPL-LT-636', online: true);
      relay.presence(macOnline: true);
      await tester.pump();
      return (model, relay, speech);
    }

    Future<void> close(WidgetTester tester, PocketModel model) async {
      await tester.pumpWidget(const SizedBox());
      model.dispose();
      await tester.pump(const Duration(seconds: 60));
    }

    /// Mochi's hit area in the room.
    Finder mochiFinder() =>
        find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == 'Mochi. Tap to pet, press and hold to talk.');

    List<LinkCommand> sent(FakeRelay relay) => [for (final value in relay.sentValues(LinkKey.command)) LinkCommand.fromValue(value)!];

    testWidgets('press and hold Mochi: listening, the words in the bubble, and letting go sends them', (tester) async {
      final (model, relay, speech) = await open(tester);
      expect(find.text('Tap Mochi to pet · press and hold to talk'), findsOneWidget);
      final mochi = mochiFinder();
      final gesture = await tester.startGesture(tester.getCenter(mochi));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('Listening… let go to send, or slide away to cancel'), findsOneWidget);
      speech.say('what is waiting');
      await tester.pump();
      expect(find.text('what is waiting'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(sent(relay).single.text, 'what is waiting');
      expect(find.text('“what is waiting”'), findsOneWidget);
      expect(find.byTooltip('Stop'), findsOneWidget);
      await close(tester, model);
    });

    testWidgets('slide away from Mochi, then let go: cancelled', (tester) async {
      final (model, relay, speech) = await open(tester);
      final mochi = mochiFinder();
      final gesture = await tester.startGesture(tester.getCenter(mochi));
      await tester.pump(const Duration(milliseconds: 1200));
      speech.say('oops');
      await gesture.moveBy(const Offset(0, -150));
      await tester.pump();
      expect(find.text('Let go to cancel'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(sent(relay), isEmpty);
      expect(find.text('Tap Mochi to pet · press and hold to talk'), findsOneWidget);
      await close(tester, model);
    });

    testWidgets('Talk without holding (TalkBack friendly): tap Talk, then Send, or Cancel', (tester) async {
      final (model, relay, speech) = await open(tester);
      await tester.tap(find.byTooltip('Talk to Mochi'));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Listening… tap Send when you’re done'), findsOneWidget);
      speech.say('read my updates');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(sent(relay).single.text, 'read my updates');
      await tester.tap(find.byTooltip('Stop'));
      await tester.pump();

      await tester.tap(find.byTooltip('Talk to Mochi'));
      await tester.pump(const Duration(seconds: 1));
      speech.say('never mind');
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pump();
      expect(sent(relay), hasLength(1));
      // Mochi offers "Talk to Mochi" to TalkBack as an action of its own.
      final semantics = tester.widget<Semantics>(mochiFinder()).properties;
      expect(semantics.customSemanticsActions!.keys.single.label, 'Talk to Mochi');
      await close(tester, model);
    });
  });
}
