// The room on the home screen, run by Mochi's world (A5): drawn and ticked only while it can be seen (never in the
// background, behind another screen or scrolled away), smooth only for a moment, calmer with animations off; it tells
// TalkBack what Mochi and Patch are doing; the phone's petting reaches the computer while the friendship shown stays
// the computer's; and talking takes over Mochi's pose as on the iPhone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_pocket/src/app.dart';
import 'package:mochi_pocket/src/model/app_settings.dart';
import 'package:mochi_pocket/src/model/pocket_model.dart';
import 'package:mochi_pocket/src/scene/phone_world.dart';
import 'package:mochi_pocket/src/scene/room_view.dart';
import 'package:mochi_pocket/src/services/credential_store.dart';
import 'package:mochi_pocket/src/services/local_file.dart';
import 'package:mochi_pocket/src/talk/talk_model.dart';
import 'package:mochi_pocket/src/voice/updates_reader.dart';
import 'package:mochi_world/mochi_world.dart' show InteractionID, PetPoseEvaluator, PoseContext;

import 'support/fakes.dart';

void main() {
  late FakeRelay relay;
  late PocketModel model;
  late PhoneWorld world;

  /// The app on a phone-sized view ([height] dp tall), paired, with the computer sharing its look and Claude at work.
  Future<void> open(WidgetTester tester, {double height = 700, double textScale = 1, bool dark = false, bool calm = false}) async {
    tester.view.physicalSize = Size(1080, height * 3);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
    if (calm) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    relay = FakeRelay();
    final bridge = FakeBridge();
    final settings = AppSettings(MemoryDocument());
    model = PocketModel(
      credentialStore: MemoryCredentialStore(phoneCredentials),
      doneDocument: MemoryDocument(),
      notifier: FakeNotifier(),
      connect: relay.connect,
      deviceName: 'realme RMX3242',
    );
    // The world's clocks follow the test's (fake) time.
    final start = tester.binding.clock.now();
    world = PhoneWorld(
      model: model,
      clock: () => tester.binding.clock.now(),
      uptime: () => tester.binding.clock.now().difference(start).inMicroseconds / 1e6,
    );
    await tester.pumpWidget(
      MochiApp(
        model: model,
        world: world,
        bridge: bridge,
        notifier: FakeNotifier(),
        settings: settings,
        reader: UpdatesReader(engine: FakeSpeechEngine(), focus: bridge, settings: settings, language: () => 'en-IN'),
        speech: FakeSpeechListener(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    relay.devices(online: true);
    relay.presence(macOnline: true);
    relay.fromMac(LinkKey.look, sampleLook().toValue());
    relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'working', category: 'edit').toValue());
    relay.fromMac(LinkKey.sessions, sampleSessions().toValue());
    relay.fromMac(LinkKey.agent, sampleAgent().toValue());
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    world.dispose();
    model.dispose();
    await tester.pump(const Duration(seconds: 10));
  }

  RoomViewState room(WidgetTester tester) => tester.state<RoomViewState>(find.byType(RoomView, skipOffstage: false));

  testWidgets('the room ticks and draws only while it can be seen: never in the background, behind Settings or scrolled '
      'away', (tester) async {
    await open(tester);
    expect(world.ticking, isTrue);
    expect(room(tester).framesPerSecond, 15, reason: 'a calm loop: Patch typing, Mochi watching');

    // The app goes to the background (home button, screen off), then comes back.
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(world.ticking, isFalse);
    expect(room(tester).framesPerSecond, 0);
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(world.ticking, isTrue);
    expect(room(tester).framesPerSecond, 15);

    // A system dialog over the app (inactive) still shows the room.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 100));
    expect(world.ticking, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    // Settings covers the home screen.
    await tester.tap(find.byTooltip('Settings'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Room and pet'), findsOneWidget);
    expect(world.ticking, isFalse);
    expect(room(tester).framesPerSecond, 0);
    await tester.pageBack();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(world.ticking, isTrue);

    // Scrolled down to what's waiting, the room is off screen (still built, just out of sight).
    await tester.drag(find.byType(ListView).first, const Offset(0, -560));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RoomView, skipOffstage: false), findsOneWidget);
    expect(tester.getRect(find.byType(RoomView, skipOffstage: false)).bottom, lessThan(0));
    expect(world.ticking, isFalse);
    expect(room(tester).framesPerSecond, 0);
    // Further down the list lets the room go altogether: still nothing ticks.
    await tester.drag(find.byType(ListView).first, const Offset(0, -1500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(world.ticking, isFalse);
    await tester.drag(find.byType(ListView).first, const Offset(0, 4000));
    await tester.pump(const Duration(milliseconds: 500));
    expect(world.ticking, isTrue);
    expect(room(tester).framesPerSecond, 15);
    await close(tester);
    expect(world.ticking, isFalse);
  });

  testWidgets('a pet is a moment, drawn every frame, then back to the calm rate; the computer is told; the friendship '
      "shown stays the computer's", (tester) async {
    await open(tester);
    await tester.tap(find.text('Pet'));
    await tester.pump(Duration.zero);
    expect(world.world.pet.current.animation, PetAnimation.petted);
    expect(room(tester).framesPerSecond, RoomView.smooth);
    expect(relay.sentValues(LinkKey.phoneInteraction), hasLength(1));
    await tester.pump(const Duration(seconds: 5));
    expect(world.world.pet.isPlayingOneShot, isFalse);
    expect(room(tester).framesPerSecond, 15);
    for (var i = 0; i < 25; i++) {
      await tester.tap(find.text('Treat'));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(find.text('Friendship 3'), findsOneWidget, reason: "the computer's level, from its look");
    // The computer's play plays here too.
    await tester.pump(const Duration(seconds: 5));
    relay.fromMac(LinkKey.macInteraction, LinkInteraction(id: 'mac-1', kind: 'play', at: now()).toValue());
    await tester.pump(Duration.zero);
    expect(world.world.pet.current.animation, PetAnimation.play);
    await close(tester);
  });

  testWidgets("Claude's news is a moment drawn at 30 frames a second: a high five when the turn on the computer ends", (tester) async {
    await open(tester);
    await tester.pump(const Duration(seconds: 3));
    relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'done').toValue());
    await tester.pump(Duration.zero);
    expect(world.world.interaction?.id, InteractionID.highFive);
    expect(room(tester).framesPerSecond, 30);
    await tester.pump(const Duration(seconds: 8));
    expect(world.world.interaction, isNull);
    expect(room(tester).framesPerSecond, 15);
    await close(tester);
  });

  testWidgets('TalkBack hears what Mochi and Patch are doing, and Mochi is a button with Talk as an action', (tester) async {
    final semantics = tester.ensureSemantics();
    await open(tester);
    expect(find.bySemanticsLabel("Mochi's room. Mochi is watching Claude work. Patch is typing at his desk."), findsOneWidget);
    expect(find.bySemanticsLabel('Mochi. Tap to pet, press and hold to talk.'), findsOneWidget);
    relay.fromMac(LinkKey.claude, const ClaudeMirror(phase: 'waiting').toValue());
    await tester.pump(Duration.zero);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.bySemanticsLabel("Mochi's room. Claude needs you. Patch is waiting for you."), findsOneWidget);
    semantics.dispose();
    await close(tester);
  });

  for (final dark in [false, true]) {
    testWidgets('dark ${dark ? 'on' : 'off'}, 2× text, animations off: the room draws, calmer and at most 10 frames a second', (
      tester,
    ) async {
      await open(tester, dark: dark, textScale: 2, calm: true);
      expect(tester.takeException(), isNull);
      expect(world.world.reducedMotion, isTrue, reason: "the Mac's Reduce Motion poses");
      expect(room(tester).framesPerSecond, 10);
      model.interact('play');
      await tester.pump(const Duration(milliseconds: 300));
      expect(world.busy, isTrue);
      expect(room(tester).framesPerSecond, 10, reason: 'even for a moment');
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      await close(tester);
    });
  }

  testWidgets('talking takes over Mochi and is drawn every frame until it settles', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('Talk to Mochi'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(room(tester).framesPerSecond, RoomView.smooth);
    await tester.tap(find.byTooltip('Cancel'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(room(tester).framesPerSecond, 15);
    await close(tester);
  });

  group("Mochi's pose while you talk (the iPhone's RoomView.pose)", () {
    final base = PetPose()..eyes = PetEyes.closed;
    PoseContext context(double time) => PoseContext(time: time, seed: 7);

    test('listening turns the idle Mochi to listen; sending nods; waiting looks around', () {
      final idle = PetPoseEvaluator.pose(PetAnimation.idle, elapsed: 12, context: context(12));
      expect(
        RoomView.talkPose(base, TalkPhase.approaching, elapsed: 0.3, time: 12).toJson(),
        ListeningPose.pose(idle, elapsed: 0.3, listening: false, time: 12).toJson(),
      );
      expect(RoomView.talkPose(base, TalkPhase.listening, elapsed: 3, time: 12).earListen, 1);
      final nod = RoomView.talkPose(base, TalkPhase.sending, elapsed: 2, time: 12);
      expect(nod.earPerk, 0.8);
      expect(
        (nod..earPerk = 0).toJson(),
        (PetPoseEvaluator.pose(PetAnimation.nod, elapsed: 0.9, duration: 1, context: context(12))..earPerk = 0).toJson(),
      );
      expect(RoomView.talkPose(base, TalkPhase.waiting, elapsed: 5.3, time: 12).earPerk, 0.7);
    });

    test('an answer: a bounce, then the world’s Mochi smiling; a failure: a worried look; idle: the world’s Mochi', () {
      final smiling = RoomView.talkPose(base, TalkPhase.replied, elapsed: 3, time: 12);
      expect(smiling.eyes, PetEyes.happy);
      expect(smiling.mouth, PetMouth.smile);
      expect(smiling.blush, 0.85);
      expect(base.eyes, PetEyes.closed, reason: "the world's pose is left as it was");
      expect(
        RoomView.talkPose(base, TalkPhase.replied, elapsed: 0.4, time: 12).toJson(),
        PetPoseEvaluator.pose(PetAnimation.happyBounce, elapsed: 0.4, duration: 1, context: context(12)).toJson(),
      );
      expect(
        RoomView.talkPose(base, TalkPhase.failed, elapsed: 9, time: 12).toJson(),
        PetPoseEvaluator.pose(PetAnimation.concerned, elapsed: 2.2, context: context(12)).toJson(),
      );
      expect(identical(RoomView.talkPose(base, TalkPhase.idle, elapsed: 1, time: 12), base), isTrue);
    });

    test('frame rates: your moments every frame, other moments 30, loops 15, naps 6, animations off at most 10', () {
      expect(RoomView.frameRate(moment: true, yours: true, napping: false), RoomView.smooth);
      expect(RoomView.frameRate(moment: false, yours: true, napping: false), RoomView.smooth, reason: 'talking');
      expect(RoomView.frameRate(moment: true, napping: false), 30);
      expect(RoomView.frameRate(moment: false, napping: false), 15);
      expect(RoomView.frameRate(moment: false, napping: true), 6);
      expect(RoomView.frameRate(moment: true, yours: true, napping: false, calm: true), 10);
      expect(RoomView.frameRate(moment: false, napping: true, calm: true), 6);
    });
  });

  test("the room's look: colours, things to wear and today's holiday (a costume unless one was chosen)", () {
    final diwali = RoomView.sceneConfig(sampleLook(), season: SeasonalEvent.diwali);
    expect(diwali.season, SeasonalEvent.diwali);
    expect(diwali.wornByPet, Accessory.flowerCrown);
    expect(diwali.deskAccessory, Accessory.plant);
    final chosen = RoomView.sceneConfig(
      const PetLook(
        petName: 'Mochi',
        companionName: 'Patch',
        petColor: 'mint',
        petAccessory: 'scarf',
        theme: 'cyberpunk',
        friendshipLevel: 1,
      ),
      season: SeasonalEvent.diwali,
    );
    expect(chosen.petColor, PetColor.mint);
    expect(chosen.theme, OfficeTheme.cyberpunk);
    expect(chosen.wornByPet, Accessory.scarf);
    expect(chosen.deskAccessory, isNull, reason: 'no desk accessory in the look means none');
  });
}
