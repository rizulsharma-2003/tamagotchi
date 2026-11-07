// Settings › Notifications on Windows, as on the Mac (docs/SPRINT_2.md W1): the settings model (each category's
// animate/badge/banner/sound, quiet mode and hours, sounds; older files), the policy (pausing, quiet, already looking,
// late and simulated events), banner batching, the reaction to each kind of event, and the whole path with fakes:
// Windows notifications batched and pointing at their session, sounds, the badge on Mochi, and a click that opens the
// session's card.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/notifications.dart';
import 'package:mochi_desktop/src/core/pet_cues.dart';
import 'package:mochi_desktop/src/core/sessions.dart';
import 'package:mochi_desktop/src/core/sounds.dart';
import 'package:mochi_desktop/src/core/toasts.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/settings/settings_kit.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/ui/widgets/session_card.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'support/fakes.dart';

final DateTime noon = DateTime(2026, 11, 7, 12);

DesktopSettings fresh([Map<String, Object?>? json]) => DesktopSettings(MemorySettingsDocument(json), clock: () => noon);

void main() {
  group('Quiet hours', () {
    test('a window in the day, one past midnight, off, and an empty one', () {
      const day = QuietHours(enabled: true, startMinute: 13 * 60, endMinute: 14 * 60 + 30);
      expect(day.isActive(DateTime(2026, 11, 7, 13)), isTrue);
      expect(day.isActive(DateTime(2026, 11, 7, 14, 29)), isTrue);
      expect(day.isActive(DateTime(2026, 11, 7, 14, 30)), isFalse, reason: 'the end is not quiet');
      const night = QuietHours(enabled: true);
      expect((night.startMinute, night.endMinute), (22 * 60, 8 * 60), reason: 'the Mac’s 22:00–08:00');
      expect(night.isActive(DateTime(2026, 11, 7, 23, 15)), isTrue);
      expect(night.isActive(DateTime(2026, 11, 8, 7, 59)), isTrue);
      expect(night.isActive(noon), isFalse);
      expect(const QuietHours().isActive(DateTime(2026, 11, 7, 23)), isFalse, reason: 'off by default');
      expect(const QuietHours(enabled: true, startMinute: 600, endMinute: 600).isActive(DateTime(2026, 11, 7, 10)), isFalse);
      expect(const QuietHours(enabled: true, startMinute: -60, endMinute: 1500).startMinute, 23 * 60, reason: 'kept within a day');
      expect((QuietHours.format(22 * 60), QuietHours.format(8 * 60 + 5)), ('22:00', '08:05'));
    });
  });

  group('The settings model', () {
    test('every category starts at the Mac’s defaults: banners off, badges where they belong', () {
      final settings = fresh();
      expect(settings.delivery(NotificationCategory.needsAttention), const CategoryDelivery(badge: true, sound: true));
      expect(settings.delivery(NotificationCategory.turnCompleted), const CategoryDelivery(sound: true));
      expect(settings.delivery(NotificationCategory.toolActivity), const CategoryDelivery());
      for (final category in NotificationCategory.values) {
        expect(settings.delivery(category).banner, isFalse, reason: category.title);
        expect(settings.delivery(category).animate, isTrue, reason: category.title);
      }
      expect((settings.soundEnabled, settings.soundVolume, settings.workSounds), (false, 0.45, false));
      expect((settings.quietMode, settings.quietHours.enabled), (false, false));
      expect(settings.deliveryAtDefaults, isTrue);
    });

    test('choices are saved and read back; banners and badges only where the category allows them', () {
      final first = fresh()
        ..setDelivery(NotificationCategory.turnCompleted, const CategoryDelivery(banner: true, sound: false))
        ..setDelivery(NotificationCategory.toolActivity, const CategoryDelivery(banner: true, badge: true, sound: true))
        ..setDelivery(NotificationCategory.sessionLifecycle, const CategoryDelivery(badge: true, banner: true))
        ..quietMode = true
        ..quietHours = const QuietHours(enabled: true, startMinute: 21 * 60 + 30, endMinute: 7 * 60)
        ..soundEnabled = true
        ..soundVolume = 0.8
        ..workSounds = true;
      expect(first.deliveryAtDefaults, isFalse);
      final again = fresh(first.toJson());
      expect(again.delivery(NotificationCategory.turnCompleted), const CategoryDelivery(banner: true));
      expect(again.delivery(NotificationCategory.toolActivity), const CategoryDelivery(sound: true), reason: 'never a banner or badge');
      expect(again.delivery(NotificationCategory.sessionLifecycle), const CategoryDelivery(banner: true), reason: 'banners but no badge');
      expect((again.quietMode, again.quietHours), (true, const QuietHours(enabled: true, startMinute: 21 * 60 + 30, endMinute: 7 * 60)));
      expect((again.soundEnabled, again.soundVolume, again.workSounds), (true, 0.8, true));
      again.restoreDeliveryDefaults();
      expect(again.delivery(NotificationCategory.turnCompleted), NotificationCategory.turnCompleted.defaultDelivery);
      expect(again.deliveryAtDefaults, isTrue);
      again.soundVolume = 7;
      expect(again.soundVolume, 1.0);
    });

    test('a version 3 file’s two switches become their categories’ animations', () {
      final settings = fresh({'v': 3, 'adoptedAt': noon.toIso8601String(), 'celebrateFinished': false, 'showSnags': false});
      expect(settings.delivery(NotificationCategory.turnCompleted), const CategoryDelivery(animate: false, sound: true));
      expect(settings.delivery(NotificationCategory.turnError).animate, isFalse);
      expect(settings.delivery(NotificationCategory.toolFailure), const CategoryDelivery(animate: false, badge: true));
      expect((settings.celebrateFinished, settings.showSnags), (false, false));
      final untouched = fresh({'v': 3, 'adoptedAt': noon.toIso8601String()});
      expect((untouched.celebrateFinished, untouched.showSnags, untouched.deliveryAtDefaults), (true, true, true));
    });

    test('a damaged file keeps what it can', () {
      final settings = fresh({
        'categoryDelivery': {'turnCompleted': 'nonsense', 'needsAttention': {'banner': true, 'sound': 'loud'}},
        'quietHours': [1, 2],
        'soundVolume': 'loud',
      });
      expect(settings.delivery(NotificationCategory.turnCompleted), NotificationCategory.turnCompleted.defaultDelivery);
      expect(settings.delivery(NotificationCategory.needsAttention), const CategoryDelivery(badge: true, banner: true, sound: true));
      expect((settings.quietHours, settings.soundVolume), (const QuietHours(), 0.45));
    });
  });

  group('The policy', () {
    NotificationContext at(DateTime now, {bool looking = false, bool late = false, bool simulated = false}) =>
        NotificationContext(now: now, lookingAtMochi: looking, isLate: late, isSimulated: simulated);

    test('what each category asks for, sounds only with Play sounds on (and keyboard taps only with them on too)', () {
      final settings = fresh()..setDelivery(NotificationCategory.turnCompleted, const CategoryDelivery(banner: true, sound: true));
      var decision = NotificationPolicy.decide(NotificationCategory.turnCompleted, settings, at(noon));
      expect(decision, const DeliveryDecision(animate: true, badge: false, banner: true, sound: false, quiet: false));
      settings.soundEnabled = true;
      decision = NotificationPolicy.decide(NotificationCategory.turnCompleted, settings, at(noon));
      expect(decision.sound, isTrue);
      settings.setDelivery(NotificationCategory.toolActivity, const CategoryDelivery(sound: true));
      expect(NotificationPolicy.decide(NotificationCategory.toolActivity, settings, at(noon)).sound, isFalse);
      settings.workSounds = true;
      expect(NotificationPolicy.decide(NotificationCategory.toolActivity, settings, at(noon)).sound, isTrue);
    });

    test('quiet hours and quiet mode take sounds and banners, never animations or badges', () {
      final settings = fresh()
        ..soundEnabled = true
        ..setDelivery(NotificationCategory.needsAttention, const CategoryDelivery(badge: true, banner: true, sound: true))
        ..quietHours = const QuietHours(enabled: true);
      final night = DateTime(2026, 11, 7, 23);
      expect(
        NotificationPolicy.decide(NotificationCategory.needsAttention, settings, at(night)),
        const DeliveryDecision(animate: true, badge: true, banner: false, sound: false, quiet: true),
      );
      expect(NotificationPolicy.decide(NotificationCategory.needsAttention, settings, at(noon)).banner, isTrue);
      settings.quietMode = true;
      expect(NotificationPolicy.decide(NotificationCategory.needsAttention, settings, at(noon)).banner, isFalse);
      expect(NotificationPolicy.isQuiet(settings, noon), isTrue);
    });

    test('paused: no animation, sound or banner; looking at Mochi: no banner or badge; late: nothing; simulated: no banner', () {
      final settings = fresh()
        ..soundEnabled = true
        ..setDelivery(NotificationCategory.needsAttention, const CategoryDelivery(badge: true, banner: true, sound: true));
      expect(
        NotificationPolicy.decide(NotificationCategory.needsAttention, settings, at(noon, looking: true)),
        const DeliveryDecision(animate: true, badge: false, banner: false, sound: true, quiet: false),
      );
      expect(NotificationPolicy.decide(NotificationCategory.needsAttention, settings, at(noon, late: true)), DeliveryDecision.none);
      expect(NotificationPolicy.decide(NotificationCategory.needsAttention, settings, at(noon, simulated: true)).banner, isFalse);
      settings.pauseReactions = true;
      expect(
        NotificationPolicy.decide(NotificationCategory.needsAttention, settings, at(noon)),
        const DeliveryDecision(animate: false, badge: true, banner: false, sound: false, quiet: false),
      );
    });
  });

  test('banners are batched: the first per key shows, the rest within 45 seconds are counted into the next', () {
    final coalescer = BannerCoalescer();
    expect(coalescer.register('turn-a', noon), 0);
    expect(coalescer.register('turn-a', noon.add(const Duration(seconds: 10))), isNull);
    expect(coalescer.register('turn-b', noon.add(const Duration(seconds: 10))), 0, reason: 'another session is another key');
    expect(coalescer.register('turn-a', noon.add(const Duration(seconds: 30))), isNull);
    expect(coalescer.register('turn-a', noon.add(const Duration(seconds: 46))), 2);
    expect(coalescer.register('turn-a', noon.add(const Duration(seconds: 100))), 0);
  });

  group('Each event’s reaction (the Mac’s EventToAnimationMapper)', () {
    late SessionRegistry registry;
    setUp(() => registry = SessionRegistry());

    Reaction? react(WireEvent event, {bool primary = true, bool many = false}) =>
        ReactionMapper.reaction(registry.apply(event)!, isPrimary: primary, multipleLiveSessions: many);

    test('a session starting and ending', () {
      final start = react(hook('SessionStart', at: noon)..source = 'startup')!;
      expect((start.category, start.cue, start.sound), (NotificationCategory.sessionLifecycle, PetCue.greet, SoundCue.greeting));
      expect(start.banner, const BannerContent(title: 'Claude Code session started', body: 'web'));
      expect(start.caption, 'session started');
      expect(react(hook('SessionStart', at: noon)..source = 'compact'), isNull, reason: 'compacting isn’t news');
      final end = react(hook('SessionEnd', at: noon))!;
      expect((end.cue, end.banner?.title, end.caption), (PetCue.goodbye, 'Claude Code session ended', 'session ended'));
    });

    test('Claude needs you, once for a permission request and its notification', () {
      final ask = react(hook('PermissionRequest', tool: 'Bash', at: noon))!;
      expect((ask.category, ask.cue, ask.attention), (NotificationCategory.needsAttention, PetCue.needsYou, AttentionLevel.attention));
      expect(ask.banner, const BannerContent(title: 'Claude needs your permission', body: 'web — Wants to use Bash'));
      expect(react(hook('Notification', notificationType: 'permission_prompt', at: noon)), isNull, reason: 'already waiting');
      final idle = react(hook('Notification', session: 's2', project: 'api', notificationType: 'idle_prompt', at: noon)..message = 'Claude is waiting for your input', many: true)!;
      expect((idle.attention, idle.banner?.title, idle.caption), (AttentionLevel.info, 'Claude is waiting for your input', 'api · waiting for you'));
    });

    test('a finished turn says what the build or test did, and a long one or a pass is a celebration', () {
      react(hook('UserPromptSubmit', at: noon));
      final test = hook('PostToolUse', tool: 'Bash', at: noon.add(const Duration(seconds: 30)))
        ..commandKind = 'test'
        ..commandReliable = true;
      final passed = react(test)!;
      expect((passed.category, passed.cue, passed.caption), (NotificationCategory.buildTest, PetCue.cheer, 'test command passed'));
      final done = react(hook('Stop', at: noon.add(const Duration(minutes: 1))))!;
      expect(done.banner, const BannerContent(title: 'Claude finished responding', body: 'web — A test command Claude ran exited successfully'));
      expect((done.cue, done.sound), (PetCue.finished, SoundCue.celebration));
      react(hook('UserPromptSubmit', at: noon.add(const Duration(minutes: 2))));
      final plain = react(hook('Stop', at: noon.add(const Duration(minutes: 3))))!;
      expect(plain.banner!.body, 'web — No build or test result was received this turn.');
      expect(plain.sound, SoundCue.success);
    });

    test('tool errors, the third in a row starts an investigation, and an API error', () {
      react(hook('UserPromptSubmit', at: noon));
      final first = react(hook('PostToolUseFailure', tool: 'Bash', at: noon)..exitCode = 1)!;
      expect((first.category, first.cue, first.attention), (NotificationCategory.toolFailure, PetCue.worry, AttentionLevel.info));
      expect(first.banner, const BannerContent(title: 'Bash reported an error', body: 'web — Claude may still be working on it.'));
      react(hook('PostToolUseFailure', tool: 'Bash', at: noon));
      final third = react(hook('PostToolUseFailure', tool: 'Bash', at: noon))!;
      expect(third.caption, 'several tool errors — investigating');
      final api = react(hook('StopFailure', at: noon)..reason = 'rate_limit')!;
      expect((api.category, api.cue, api.attention), (NotificationCategory.turnError, PetCue.snag, AttentionLevel.alert));
      expect(api.banner, const BannerContent(title: 'Turn ended with an API error', body: 'web — rate limit'));
    });

    test('tool activity is for the session Mochi follows, and never a banner', () {
      final prompt = react(hook('UserPromptSubmit', at: noon))!;
      expect((prompt.category, prompt.cue, prompt.banner), (NotificationCategory.toolActivity, PetCue.attend, null));
      expect(react(hook('PreToolUse', tool: 'Edit', at: noon))!.sound, SoundCue.keyboard);
      expect(react(hook('PreToolUse', tool: 'Read', at: noon))!.sound, isNull);
      expect(react(hook('PreToolUse', tool: 'Edit', at: noon), primary: false), isNull);
    });

    test('a milestone your script reports', () {
      final event = WireEvent(id: 'r1', ts: noon.millisecondsSinceEpoch / 1000, origin: WireOrigin.report, event: 'Report')
        ..session = 's1'
        ..project = 'web'
        ..report = const WireReport(kind: 'milestone', status: 'passed', label: 'v1 shipped');
      final milestone = react(event)!;
      expect((milestone.category, milestone.cue, milestone.sound), (NotificationCategory.milestone, PetCue.celebrate, SoundCue.celebration));
      expect(milestone.banner, const BannerContent(title: 'Milestone reached', body: 'v1 shipped'));
    });
  });

  group('Windows notifications, sounds and the badge, end to end with fakes', () {
    late TestDesktop t;
    late DateTime now;

    setUp(() async {
      now = noon;
      t = TestDesktop.make(clock: () => now);
      t.desktop.settings
        ..soundEnabled = true
        ..setDelivery(NotificationCategory.turnCompleted, const CategoryDelivery(banner: true, sound: true))
        ..setDelivery(NotificationCategory.needsAttention, const CategoryDelivery(badge: true, banner: true, sound: true));
      await t.desktop.start();
    });
    tearDown(() => t.dispose());

    void live(WireEvent event) => t.desktop.sessions.apply(event);

    test('a finished turn shows one Windows notification pointing at its session; repeats are batched', () {
      live(hook('UserPromptSubmit', at: now));
      live(hook('Stop', at: now));
      expect(t.toasts.shown, hasLength(1));
      final toast = t.toasts.shown.single;
      expect((toast.title, toast.body, toast.target), ('Claude finished responding', 'web — No build or test result was received this turn.', const ToastTarget.session('s1')));
      expect(toast.xml(), contains('<audio silent="true"/>'), reason: 'Mochi plays its own sound');
      expect(t.sound.played, hasLength(1), reason: 'the success chime');
      now = now.add(const Duration(seconds: 20));
      live(hook('UserPromptSubmit', at: now));
      live(hook('Stop', at: now));
      expect(t.toasts.shown, hasLength(1), reason: 'held back');
      now = now.add(const Duration(seconds: 40));
      live(hook('UserPromptSubmit', at: now));
      live(hook('Stop', at: now));
      expect(t.toasts.shown.last.body, endsWith('(+1 similar)'));
      expect(t.toasts.shown.last.tag, toast.tag, reason: 'it replaces the earlier one in the notification centre');
      expect(t.desktop.reactions.bannersPosted, 2);
    });

    test('nothing for late events from the spool, or for simulated ones', () {
      t.desktop.sessions
        ..apply(hook('UserPromptSubmit', at: now), delivery: Delivery.late)
        ..apply(hook('Stop', at: now), delivery: Delivery.late);
      final simulated = hook('Stop', session: 'sim', at: now)..origin = WireOrigin.simulator;
      live(simulated);
      expect(t.toasts.shown, isEmpty);
      expect(t.sound.played, isEmpty);
    });

    test('quiet hours keep the notification and the sound back, but Mochi still reacts', () async {
      final cues = <PetCue>[];
      final subscription = t.desktop.cues.listen(cues.add);
      t.desktop.settings.quietHours = const QuietHours(enabled: true, startMinute: 11 * 60, endMinute: 13 * 60);
      live(hook('UserPromptSubmit', at: now));
      live(hook('Stop', at: now));
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(t.toasts.shown, isEmpty);
      expect(t.sound.played, isEmpty);
      expect(cues, contains(PetCue.finished));
    });

    test('no notification while Windows has them off, or Mochi isn’t installed', () {
      t.toasts.availability = ToastAvailability.notInstalled;
      live(hook('UserPromptSubmit', at: now));
      live(hook('Stop', at: now));
      expect(t.toasts.shown, isEmpty);
    });

    test('the badge: on for Claude needs you, off once the session goes on; a tool error’s goes when you look', () {
      final reactions = t.desktop.reactions;
      live(hook('PermissionRequest', tool: 'Bash', at: now));
      expect((reactions.badge?.kind, reactions.badge?.level), (AttentionKind.needsYou, AttentionLevel.attention));
      live(hook('PostToolUse', tool: 'Bash', toolUseId: 'u1', at: now));
      expect(reactions.badge, isNull, reason: 'answered');
      live(hook('PostToolUseFailure', tool: 'Bash', at: now));
      expect(reactions.badge?.kind, AttentionKind.toolError);
      reactions.acknowledge();
      expect(reactions.badge, isNull);
      live(hook('PermissionRequest', tool: 'Bash', at: now));
      reactions.acknowledge();
      expect(reactions.badge?.kind, AttentionKind.needsYou, reason: 'that one stays until you answer');
    });

    test('with Mochi’s window open you’re looking already: no badge, no notification', () {
      t.desktop.reactions.lookingAtMochi = () => true;
      live(hook('PermissionRequest', tool: 'Bash', at: now));
      expect(t.desktop.reactions.badge, isNull);
      expect(t.toasts.shown, isEmpty);
    });

    testWidgets('clicking a notification opens Mochi’s window at the session’s card; an agent one opens the Agent pane', (tester) async {
      await tester.runAsync(() async {
        live(hook('UserPromptSubmit', session: 'abc', project: 'shop', at: now));
        live(hook('Stop', session: 'abc', project: 'shop', at: now));
      });
      final shell = FakeShell();
      await tester.pumpWidget(DesktopApp(desktop: t.desktop, shell: shell, library: Future<PoseLibrary?>.value()));
      await tester.pump(const Duration(milliseconds: 100));
      t.toasts.click(t.toasts.shown.single.target);
      await tester.pump(const Duration(milliseconds: 300));
      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      expect((state.surface, state.page, state.focusSession), (Surface.main, MainPage.home, 'abc'));
      await tester.pump(const Duration(milliseconds: 100));
      final card = find.byType(SessionCard);
      expect(tester.widget<SessionCard>(card).highlighted, isTrue);
      expect(tester.getRect(card).overlaps(tester.getRect(find.byType(DesktopApp))), isTrue, reason: 'scrolled into view');
      t.toasts.click(ToastTarget.agent);
      await tester.pump(const Duration(milliseconds: 300));
      expect((state.page, state.settingsNavigation.tab), (MainPage.settings, SettingsTab.agent));
      t.toasts.click(ToastTarget.parse('mochi:main'));
      await tester.pump(const Duration(milliseconds: 300));
      expect((state.page, state.focusSession), (MainPage.home, null));
    });
  });

  group('Toasts and sounds', () {
    test('a toast’s argument survives the trip, and its words are escaped', () {
      for (final target in const [ToastTarget.session('a b&c'), ToastTarget.main, ToastTarget.agent]) {
        expect(ToastTarget.parse(target.encode()), target);
      }
      expect(ToastTarget.parse('something else'), ToastTarget.main);
      expect(ToastTarget.parse(null), ToastTarget.main);
      const toast = Toast(title: 'Tests <failed>', body: 'web & "api"', target: ToastTarget.session('s1'), group: 'turnCompleted-s1');
      final xml = toast.xml();
      expect(xml, contains('<text hint-maxLines="1">Tests &lt;failed&gt;</text>'));
      expect(xml, contains('web &amp; &quot;api&quot;'));
      expect(xml, contains('launch="mochi:session=s1"'));
      expect(toast.tag, const Toast(title: 'x', body: 'y', target: ToastTarget.main, group: 'turnCompleted-s1').tag);
    });

    test('the Mac’s notes become a playable WAV, and a sound never repeats within a moment', () {
      final wav = SoundSynth.wav(SoundCue.success);
      final bytes = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(bytes.getUint32(24, Endian.little), SoundSynth.sampleRate);
      expect(bytes.getUint32(40, Endian.little), wav.length - 44);
      // 0.18 + 0.45 seconds and a quarter-second tail.
      expect((wav.length - 44) / 2 / SoundSynth.sampleRate, closeTo(0.88, 0.01));
      final quiet = SoundSynth.samples(SoundCue.success, volume: 0.1).fold<int>(0, (top, s) => s.abs() > top ? s.abs() : top);
      final loud = SoundSynth.samples(SoundCue.success, volume: 1).fold<int>(0, (top, s) => s.abs() > top ? s.abs() : top);
      expect(loud, greaterThan(quiet * 5));
      expect(SoundSynth.samples(SoundCue.keyboard).length, (0.22 * SoundSynth.sampleRate).floor());

      var now = noon;
      final output = FakeSound();
      final sounds = MochiSounds(output: output, volume: () => 0.5, clock: () => now);
      expect(sounds.play(SoundCue.success), isTrue);
      expect(sounds.play(SoundCue.success), isFalse);
      expect(sounds.play(SoundCue.attention), isTrue);
      now = now.add(const Duration(seconds: 2));
      expect(sounds.play(SoundCue.success), isTrue);
      output.systemSoundsOn = false;
      now = now.add(const Duration(seconds: 2));
      expect(sounds.play(SoundCue.success), isFalse, reason: 'Windows’ “No Sounds” scheme');
      expect(output.played, hasLength(3));
    });
  });

  group('Settings › Notifications', () {
    late TestDesktop t;
    setUp(() => t = TestDesktop.make(clock: () => noon));
    tearDown(() => t.dispose());

    Future<void> open(WidgetTester tester, {ToastAvailability? toasts}) async {
      if (toasts != null) t.toasts.availability = toasts;
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.notifications,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    Checkbox box(WidgetTester tester, String label) =>
        tester.widget<Checkbox>(find.descendant(of: find.bySemanticsLabel(label), matching: find.byType(Checkbox)));

    testWidgets('running from Downloads: says why notifications can’t work, offers to install, and banners can’t be ticked', (tester) async {
      await open(tester, toasts: ToastAvailability.notInstalled);
      expect(find.text('Needs Mochi installed'), findsOneWidget);
      expect(find.textContaining('can’t work reliably until Mochi is installed'), findsOneWidget);
      expect(find.text('Install Mochi…'), findsOneWidget);
      expect(box(tester, 'Claude needs you: Banner').onChanged, isNull);
      expect(box(tester, 'Claude needs you: Animate').onChanged, isNotNull);
    });

    testWidgets('turned off in Windows Settings: a way there; allowed: banners can be ticked, and tool activity never', (tester) async {
      await open(tester, toasts: ToastAvailability.offForMochi);
      final toasts = t.toasts;
      expect(find.text('Off for Mochi in Windows Settings'), findsOneWidget);
      await tester.ensureVisible(find.text('Open Notification Settings'));
      await tester.tap(find.text('Open Notification Settings'));
      expect(toasts.settingsOpened, 1);
      toasts.availability = ToastAvailability.ready;
      await tester.tap(find.text('Check Again'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Allowed'), findsOneWidget);
      final banner = find.bySemanticsLabel('Turn completed: Banner');
      await tester.ensureVisible(banner);
      await tester.tap(banner);
      await tester.pump();
      expect(t.desktop.settings.delivery(NotificationCategory.turnCompleted).banner, isTrue);
      expect(box(tester, 'Tool activity: Banner').onChanged, isNull);
      expect(box(tester, 'Session start & end: Badge').onChanged, isNull);
      expect(box(tester, 'Achievements: Animate').onChanged, isNotNull, reason: 'achievements on Windows now (W13)');
      expect(find.text(SoonRow.tag), findsNothing);
      expect(box(tester, 'Turn completed: Sound').onChanged, isNull, reason: 'Play sounds is off');
      await tester.ensureVisible(find.text('Restore Defaults'));
      await tester.tap(find.text('Restore Defaults'));
      await tester.pump();
      expect(t.desktop.settings.deliveryAtDefaults, isTrue);
    });

    testWidgets('sounds: the switch, the volume, Test and keyboard taps', (tester) async {
      await open(tester);
      final row = find.ancestor(of: find.text('Play sounds'), matching: find.byType(ToggleRow));
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pump();
      expect(t.desktop.settings.soundEnabled, isTrue);
      await tester.tap(find.text('Test'));
      expect(t.sound.played, hasLength(1));
      expect(box(tester, 'Turn completed: Sound').onChanged, isNotNull);
    });
  });
}
