// Docs/SPRINT_2.md W30, the performance budget: the taskbar pet's pictures of poses (ui/pet/pose_sprites.dart) look
// exactly like drawing the art (at every display scale and fraction of a pixel, alone and with Patch), hold everything
// the art can reach, are reused, thrown away when the look changes and kept within their budget; nothing is drawn and
// no timer runs while nobody can see the screen or the pet is hidden; UI Automation isn't asked while Mochi naps or
// while nothing on the taskbar changed; and Windows' timers are precise only while the popover's transitions run.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_desktop/src/core/pc_rhythm.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/pet_director.dart';
import 'package:mochi_desktop/src/ui/pet/pose_sprites.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/pet/world_poses.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import 'support/fakes.dart';

/// [paint] at [ratio] into an image [size] (logical) big, as RGBA bytes.
Future<Uint8List> pixels(Size size, double ratio, void Function(Canvas canvas) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(ratio);
  paint(canvas);
  final picture = recorder.endRecording();
  final image = await picture.toImage((size.width * ratio).round(), (size.height * ratio).round());
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

/// How two pictures differ: the largest difference in any channel, how many pixels differ at all, and how many by more
/// than a rounding (two levels).
({int max, int count, int beyondRounding}) difference(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var max = 0, count = 0, beyond = 0;
  for (var i = 0; i < a.length; i += 4) {
    var pixel = 0;
    for (var c = 0; c < 4; c++) {
      pixel = math.max(pixel, (a[i + c] - b[i + c]).abs());
    }
    if (pixel > 0) count++;
    if (pixel > 2) beyond++;
    max = math.max(max, pixel);
  }
  return (max: max, count: count, beyondRounding: beyond);
}

/// Where the art reaches from its origin (art units), from a drawing at 2 pixels a unit.
Future<Rect?> reach(void Function(Canvas canvas) paint) async {
  const size = Size(900, 900), origin = Offset(450, 650), k = 2.0;
  final bytes = await pixels(size, 1, (canvas) {
    canvas
      ..translate(origin.dx, origin.dy)
      ..scale(k);
    paint(canvas);
  });
  int? l, t, r, b;
  final w = size.width.toInt();
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] == 0) continue;
    final x = (i ~/ 4) % w, y = (i ~/ 4) ~/ w;
    l = l == null || x < l ? x : l;
    r = r == null || x > r ? x : r;
    t ??= y;
    b = y;
  }
  if (l == null) return null;
  return Rect.fromLTRB((l - origin.dx) / k, (t! - origin.dy) / k, (r! + 1 - origin.dx) / k, (b! + 1 - origin.dy) / k);
}

/// How far a picture's pixel may be from the art's (of 255), and how many may differ by more than rounding. The art
/// itself, drawn a few whole pixels further along, already comes out a little different on a few edge pixels
/// (coordinates round differently in floating point), and a partly covered pixel can round one level differently
/// through the picture's own image. How much depends on the rasteriser: at 1.25× the art differs from itself by up to
/// 20 levels on macOS and up to 39 on Windows (the idle pose; measured 2026-11-08), where the picture's worst edge
/// pixel was 41. Nothing a person could see; the share of pixels beyond rounding is the stricter check.
const int tolerance = 48;
const double share = 0.01;

void expectSame(Uint8List a, Uint8List b, String what) {
  final diff = difference(a, b);
  final said = '$what: ${diff.count} pixels differ by up to ${diff.max}, ${diff.beyondRounding} by more than 2';
  expect(diff.max, lessThanOrEqualTo(tolerance), reason: said);
  expect(diff.beyondRounding, lessThanOrEqualTo(a.length / 4 * share), reason: said);
}

bool within(Rect inner, Rect outer) =>
    inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right && inner.bottom <= outer.bottom;

void main() {
  late PoseLibrary library;

  setUpAll(() => library = PoseLibrary.parse(File('assets/pose_tracks.json.deflate').readAsBytesSync()));

  group('Pictures of poses', () {
    testWidgets('a picture is the art: at every display scale, and wherever it lands between pixels', (tester) async {
      await tester.runAsync(() async {
        final poses = <String, PetPose>{
          'idle': library.petTrack(PetAnimation.idle)!.at(1.2),
          'walking left': library.petTrack(PetAnimation.walk)!.at(0.8).mirrored(),
          'asleep (z)': library.petTrack(PetAnimation.sleep)!.at(2.4),
          'a happy bounce (sparkles)': library.petTrack(PetAnimation.happyBounce)!.at(0.4),
        };
        const box = Size(64, 40);
        const scale = 40 * SurfaceSizes.taskbarFill / 66;
        for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
          for (final x in [32.0, 31.5, 30.25, 33.75]) {
            final at = Offset(x, 40 - 40 * SurfaceSizes.taskbarFeet);
            for (final MapEntry(key: name, value: pose) in poses.entries) {
              void art(Canvas canvas, Offset origin) => PetRenderer.draw(
                pose,
                GContext(canvas),
                origin,
                scale,
                PetPalette(PetColor.peach),
                accessory: Accessory.witchHat,
                detail: RenderDetail.tiny,
              );
              final direct = await pixels(box, ratio, (canvas) => art(canvas, at));
              final sprites = PoseSprites();
              // Twice: drawn into the picture, then the picture reused.
              for (final pass in ['drawn', 'reused']) {
                final copied = await pixels(box, ratio, (canvas) {
                  sprites.draw(
                    canvas,
                    name,
                    at: at,
                    bounds: (Offset.zero & box).shift(-at),
                    ratio: ratio,
                    paint: (c) => art(c, Offset.zero),
                  );
                });
                expectSame(direct, copied, '$name at ${ratio}x, x $x, $pass');
              }
              expect((sprites.misses, sprites.hits), (1, 1));
              sprites.dispose();
            }
          }
        }
      });
    });

    testWidgets('a picture holds everything Mochi and Patch can show (every recorded pose, both ways round, all they wear)', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final worn = [null, ...Accessory.values.where((accessory) => accessory.slot == AccessorySlot.wearable)];
        var poses = 0;
        for (final detail in RenderDetail.values) {
          for (final track in library.pet) {
            for (var i = 0; i < track.frames.length; i += 5) {
              for (final facing in [1.0, -1.0]) {
                final pose = facing < 0 ? track.frames[i].mirrored() : track.frames[i];
                if (!ArtReach.fits(pose)) continue;
                final accessory = worn[(i ~/ 5 + track.animation.index) % worn.length];
                final extent = await reach(
                  (c) => PetRenderer.draw(pose, GContext(c), Offset.zero, 1, PetPalette(PetColor.cream), detail: detail, accessory: accessory),
                );
                poses++;
                if (extent != null) {
                  expect(within(extent, ArtReach.pet), isTrue, reason: '${track.animation.name} frame $i ($accessory): $extent');
                }
              }
            }
          }
        }
        for (final track in library.companion) {
          for (var i = 0; i < track.frames.length; i += 6) {
            final pose = track.frames[i];
            if (pose.x != 0) continue;
            for (final theme in OfficeTheme.values) {
              final accessory = worn[(i ~/ 6 + theme.index) % worn.length];
              final extent = await reach(
                (c) => CompanionRenderer.draw(
                  pose,
                  GContext(c),
                  Offset.zero,
                  1,
                  accessory: accessory,
                  time: i / 15,
                  deskFront: (desk) => ThemeRenderer.deskFront(theme, desk, accessory: Accessory.plant),
                ),
              );
              poses++;
              if (extent != null) {
                expect(within(extent, ArtReach.patch), isTrue, reason: 'Patch ${track.animation.name} frame $i: $extent');
              }
            }
          }
        }
        // The loops the taskbar keeps pictures of, as Mochi's world plays them (on the ring, for a seed), both ways round.
        final world = w.MochiWorld(seed: 0x5EED5);
        final ring = WorldPoses(world);
        for (final loop in const [
          PetAnimation.idle,
          PetAnimation.sleep,
          PetAnimation.watch,
          PetAnimation.waveGently,
          PetAnimation.walk,
          PetAnimation.carry,
          PetAnimation.sit,
          PetAnimation.curl,
          PetAnimation.run,
        ]) {
          for (var time = 0.0; time < WorldPoses.ring; time += 0.4) {
            for (final facing in [1.0, -1.0]) {
              final pose = facing < 0 ? ring.petLoop(loop, time).mirrored() : ring.petLoop(loop, time);
              final extent = await reach(
                (c) => PetRenderer.draw(pose, GContext(c), Offset.zero, 1, PetPalette(PetColor.cream), detail: RenderDetail.tiny, accessory: Accessory.witchHat),
              );
              poses++;
              if (extent != null) expect(within(extent, ArtReach.pet), isTrue, reason: 'world ${loop.name} at $time: $extent');
            }
          }
        }
        expect(poses, greaterThan(1000));
      });
    }, timeout: const Timeout(Duration(minutes: 6)));

    testWidgets('Patch: two times with the same time key draw the same picture', (tester) async {
      await tester.runAsync(() async {
        final random = math.Random(4);
        for (final animation in [CompanionAnimation.idleAtDesk, CompanionAnimation.typing, CompanionAnimation.thinking]) {
          final track = library.companionTrack(animation)!;
          final pose = track.at(1.0);
          final byKey = <String, Uint8List>{};
          for (var n = 0; n < 24; n++) {
            final time = 100 + random.nextDouble() * 10;
            final key = CompanionRenderer.timeKey(pose, time);
            final picture = await pixels(const Size(80, 50), 1, (canvas) {
              CompanionRenderer.draw(pose, GContext(canvas), const Offset(50, 45), 0.4, time: time);
            });
            final earlier = byKey[key];
            if (earlier != null) expect(difference(earlier, picture).count, 0, reason: '${animation.name} at $time ($key)');
            byKey[key] = picture;
          }
          expect(byKey.length, greaterThan(1), reason: 'the cursor blinks, the antenna spins');
        }
      });
    });

    testWidgets('pictures are reused, all thrown away when the look changes, and kept within their budget', (tester) async {
      await tester.runAsync(() async {
        final sprites = PoseSprites(budget: 64 * 64 * 4 * 3);
        void draw(String key, {double ratio = 1}) => sprites.draw(
          Canvas(ui.PictureRecorder()),
          key,
          at: const Offset(32, 60),
          bounds: const Rect.fromLTRB(-32, -60, 32, 4),
          ratio: ratio,
          paint: (canvas) => canvas.drawCircle(Offset.zero, 10, Paint()),
        );
        sprites.use('cream|light|1x');
        draw('a');
        draw('a');
        draw('b');
        expect((sprites.hits, sprites.misses, sprites.length), (1, 2, 2));
        // Another coat (or scale, or theme): every picture goes.
        sprites.use('peach|light|1x');
        expect((sprites.length, sprites.bytes), (0, 0));
        draw('a');
        expect(sprites.misses, 3);
        // Within the budget: the least recently used go first.
        for (final key in ['b', 'c', 'd', 'a', 'e']) {
          draw(key);
        }
        expect(sprites.length, lessThanOrEqualTo(3));
        expect(sprites.bytes, lessThanOrEqualTo(sprites.budget));
        final before = sprites.misses;
        draw('a');
        draw('e');
        expect(sprites.misses, before, reason: 'the most recent stayed');
        draw('b');
        expect(sprites.misses, before + 1, reason: 'the oldest went');
        sprites.dispose();
        expect(sprites.length, 0);
      });
    });
  });

  group('The taskbar pet', () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make(settings: {'companionVisibility': 'always'}));
    tearDown(() => t.dispose());

    /// The pet drawn at [time] with and without pictures, at [ratio], [size] big; their pixels.
    Future<(Uint8List, Uint8List)> both(
      WidgetTester tester, {
      required double time,
      required double ratio,
      required Size size,
      StrollSample? Function()? stroll,
      CompanionDirector? companion,
      DuoLayout? Function()? duo,
      double scale = 1,
    }) async {
      final keys = [GlobalKey(), GlobalKey()];
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = Size(size.width * 2 * ratio, size.height * ratio);
      addTearDown(tester.view.reset);
      Widget pet(int index) => SizedBox.fromSize(
        size: size,
        child: RepaintBoundary(
          key: keys[index],
          child: MochiView(
            world: t.desktop.world,
            sessions: t.desktop.sessions,
            lastActivity: () => t.desktop.sessions.now,
            fill: SurfaceSizes.taskbarFill,
            feet: SurfaceSizes.taskbarFeet,
            detail: RenderDetail.tiny,
            stroll: stroll,
            companion: companion,
            duo: duo,
            sprites: index == 0,
            time: () => time,
          ),
        ),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: ratio),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Align(alignment: Alignment.topLeft, child: Row(mainAxisSize: MainAxisSize.min, children: [pet(0), pet(1)])),
          ),
        ),
      );
      await tester.pump();
      Future<Uint8List> capture(GlobalKey key) async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: ratio);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      }

      final result = await tester.runAsync(() async => (await capture(keys[0]), await capture(keys[1])));
      final sprites = tester.state<MochiViewState>(find.byType(MochiView).first).sprites;
      expect(sprites.misses + sprites.hits, greaterThan(0), reason: 'the first view drew with pictures');
      return result!;
    }

    testWidgets('alone on the taskbar: the same pixels as drawing the art (resting, walking, asleep), at 1×, 1.25× and 1.5×', (
      tester,
    ) async {
      for (final ratio in [1.0, 1.25, 1.5]) {
        for (final (name, sample) in [
          ('resting', const StrollSample(x: 0, facing: 1, animation: PetAnimation.idle, animationTime: 2.0, activity: StrollActivity.rest)),
          (
            'walking left',
            const StrollSample(x: 0, facing: -1, animation: PetAnimation.walk, animationTime: 1.6, activity: StrollActivity.wander, travelling: true),
          ),
          ('asleep', const StrollSample(x: 0, facing: 1, animation: PetAnimation.sleep, animationTime: 2.0, activity: StrollActivity.sleep)),
        ]) {
          final (copied, direct) = await both(tester, time: 2.0, ratio: ratio, size: const Size(64, 40), stroll: () => sample);
          expectSame(copied, direct, '$name at ${ratio}x');
        }
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('with Patch at his desk: the same pixels as drawing the art', (tester) async {
      final companion = CompanionDirector(t.desktop.world);
      expect(companion.visible, isTrue);
      const unit = 40 * SurfaceSizes.taskbarFill / 66;
      final stage = TaskbarStage(
        bar: const PixelRect(0, 1032, 1920, 1080),
        scale: 1,
        zones: const [(minX: 190.0, maxX: 680.0)],
      );
      final home = stage.home(unit: unit, near: 400)!;
      final width = stage.homeWidth(home);
      final frame = stage.homeFrame(home, Size(width, stage.box.height));
      final layout = DuoLayout(home: home, originX: frame.left.toDouble());
      for (final ratio in [1.0, 1.5]) {
        final (copied, direct) = await both(
          tester,
          time: 2.0,
          ratio: ratio,
          size: Size(width, stage.box.height),
          stroll: () => StrollSample(x: home.petHome, facing: 1, animation: PetAnimation.sit, animationTime: 2.0, activity: StrollActivity.company),
          companion: companion,
          duo: () => layout,
        );
        expectSame(copied, direct, 'with Patch at ${ratio}x');
      }
      await tester.pumpWidget(const SizedBox());
      companion.dispose();
    });

    testWidgets('nothing is drawn, and no timer runs, while nobody can see the screen', (tester) async {
      final usage = FakeUsage(const SystemActivity(idleSeconds: 2));
      final rhythm = PcRhythm(settings: t.desktop.settings, sampler: usage)..start();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            width: 64,
            height: 40,
            child: MochiView(
              world: t.desktop.world,
              sessions: t.desktop.sessions,
              lastActivity: () => t.desktop.sessions.now,
              rhythm: rhythm,
            ),
          ),
        ),
      );
      final view = tester.state<MochiViewState>(find.byType(MochiView));
      expect(view.fps, 12, reason: 'a calm loop');
      expect(view.ticking, isTrue);

      // The display goes off (or the PC is locked): everything stops.
      usage.change(const SystemActivity(idleSeconds: 2, displaysAsleep: true));
      await tester.pump();
      expect(rhythm.unseen, isTrue);
      expect((view.fps, view.ticking), (0, false));
      await tester.pump(const Duration(seconds: 30));
      expect(view.ticking, isFalse);

      // Back: drawing carries on.
      usage.change(const SystemActivity(idleSeconds: 0));
      await tester.pump();
      expect(view.ticking, isTrue);
      expect(view.fps, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      rhythm.dispose();
    });
  });

  group('The stroll\'s timers', () {
    late TestDesktop t;
    late FakePetWindow window;
    late FakeShell shell;
    late FakeTaskbar taskbar;
    late PcRhythm rhythm;
    final strolls = <TaskbarStroll>[];

    setUp(() {
      t = TestDesktop.make(activity: const SystemActivity(idleSeconds: 1));
      window = FakePetWindow();
      shell = FakeShell(petWindow: window);
      final reading = FakeTaskbar.bottomTaskbar();
      taskbar = FakeTaskbar(reading, FakeTaskbar.windows11Buttons(reading));
      rhythm = PcRhythm(settings: t.desktop.settings, sampler: FakeUsage(const SystemActivity(idleSeconds: 1)))..start();
    });

    tearDown(() => t.dispose());

    /// Every stroll and the rhythm (and their timers) go before the test ends: pending timers are checked before
    /// tear-downs.
    void strollTest(String description, Future<void> Function(WidgetTester tester) body) => testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final stroll in strolls) {
          stroll.dispose();
        }
        strolls.clear();
        rhythm.dispose();
      }
    });

    Future<TaskbarStroll> start(WidgetTester tester) async {
      final stroll = TaskbarStroll(
        shell: shell,
        taskbar: taskbar,
        settings: t.desktop.settings,
        motion: t.desktop.motion,
        cues: t.desktop.cues,
        rhythm: rhythm,
        clock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
        random: math.Random(5),
      );
      strolls.add(stroll);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      return stroll;
    }

    Future<void> elapse(WidgetTester tester, double seconds, {double step = 0.5}) async {
      for (var s = 0.0; s < seconds; s += step) {
        await tester.pump(Duration(microseconds: (step * 1e6).round()));
      }
    }

    strollTest('nobody can see the screen: every timer stops, and Mochi carries on when it\'s back', (tester) async {
      final stroll = await start(tester);
      expect(stroll.placement, PetPlacement.taskbar);
      expect((stroll.watchingPointer, stroll.checking), (true, true));
      (rhythm.sampler as FakeUsage).change(const SystemActivity(idleSeconds: 400, displaysAsleep: true));
      await tester.pump();
      expect(stroll.paused, isTrue);
      expect(stroll.anyTimer, isFalse);
      final moves = window.moves.length, measures = taskbar.measures, raises = window.raises;
      await elapse(tester, 60);
      expect((window.moves.length, taskbar.measures, window.raises), (moves, measures, raises), reason: 'nothing ran');

      (rhythm.sampler as FakeUsage).change(const SystemActivity(idleSeconds: 0));
      await tester.pump();
      expect(stroll.paused, isFalse);
      expect((stroll.watchingPointer, stroll.checking), (true, true));
      await elapse(tester, 60);
      expect(window.raises, greaterThan(raises), reason: 'over the taskbar again');
    });

    strollTest('napping with the pointer still: the pointer is checked twice a second; it moves, and it\'s ten again', (tester) async {
      final stroll = await start(tester);
      taskbar.pointer = (50, 50);
      await elapse(tester, 1);
      expect(stroll.pointerEvery, TaskbarStroll.pointerIntervalDefault);
      stroll.mood = PetMood.napping;
      await elapse(tester, 1);
      expect(stroll.pointerEvery, TaskbarStroll.napPointerInterval);
      final raises = window.raises;
      await elapse(tester, 10);
      expect(window.raises - raises, lessThanOrEqualTo(21), reason: 'twice a second, not ten times');
      // You're back: the pointer moves, and it's watched at the usual pace while it does.
      // Moving the pointer a little every tenth of a second: within the next nap check it's back to the usual pace,
      // and stays there while it moves.
      for (var i = 0; i < 20; i++) {
        taskbar.pointer = (60 + i * 7, 50);
        await tester.pump(const Duration(milliseconds: 100));
        if (i >= 6) expect(stroll.pointerEvery, TaskbarStroll.pointerIntervalDefault, reason: 'moving ($i)');
      }
    });

    strollTest('the pet hidden: no timer at all', (tester) async {
      final stroll = await start(tester);
      expect(stroll.anyTimer, isTrue);
      unawaited(stroll.show(Surface.hidden));
      await tester.pump();
      expect(stroll.anyTimer, isFalse);
      await elapse(tester, 10);
      expect(stroll.anyTimer, isFalse);
    });

    strollTest('UI Automation: only when the taskbar may have changed or once a minute, never while Mochi naps', (tester) async {
      taskbar.print = 'apps: 1';
      final stroll = await start(tester);
      final first = taskbar.measures;
      expect(first, greaterThan(0));
      // Nothing changes on the taskbar for 50 seconds: nothing measured.
      await elapse(tester, 50);
      expect(taskbar.measures, first);
      // An app opens: measured at the next look.
      taskbar.print = 'apps: 2';
      await elapse(tester, 7);
      expect(taskbar.measures, first + 1);
      // Nothing changes, but a minute goes by: measured once more.
      await elapse(tester, 61);
      expect(taskbar.measures, first + 2);

      // Napping: never, however much changes.
      stroll.mood = PetMood.napping;
      final napping = taskbar.measures;
      taskbar.print = 'apps: 3';
      await elapse(tester, 130);
      expect(taskbar.measures, napping);
      // Awake: measured at once.
      stroll.mood = PetMood.relaxed;
      await tester.pump();
      expect(taskbar.measures, napping + 1);
    });

    strollTest('precise timers: on only while the popover opens and closes, however it closes', (tester) async {
      final stroll = await start(tester);
      expect(window.precise, isFalse);
      // Opening: on; open: off.
      unawaited(stroll.show(Surface.popover));
      await tester.pump();
      expect(window.precise, isTrue);
      stroll.popoverOpened();
      expect(window.precise, isFalse);
      // Closing back to the taskbar: on while Mochi leaps, off when it lands.
      stroll.popoverClosing();
      expect(window.precise, isTrue);
      await stroll.returnFromPopover();
      expect(window.precise, isFalse);
      unawaited(stroll.show(Surface.pet));
      await tester.pump();

      // Closing to the desktop (roaming off meanwhile, no leap back): off as the pet shows.
      unawaited(stroll.show(Surface.popover));
      await tester.pump();
      stroll.popoverOpened();
      stroll.popoverClosing();
      expect(window.precise, isTrue);
      t.desktop.settings.roamTaskbar = false;
      unawaited(stroll.show(Surface.pet));
      await tester.pump();
      expect(window.precise, isFalse);
      expect(window.preciseChanges.where((on) => on).length, window.preciseChanges.where((on) => !on).length);
    });
  });

  group('Frame rates', () {
    test('a calm loop drawn 8 times a second never skips a blink (on the taskbar, or on its own)', () {
      bool shut(PetPose pose) => pose.eyes != PetEyes.open || pose.eyeOpenness < 0.5;
      final t = TestDesktop.make(uptime: () => 0);
      addTearDown(t.dispose);
      final quantum = MochiView.quantum(8);
      final ring = WorldPoses(t.desktop.world.world);
      // The blinks on the grid in one ring: runs of grid frames with the eyes shut.
      final steps = (WorldPoses.ring / quantum).round();
      final blinks = <int>[];
      for (var i = 0; i < steps; i++) {
        final closed = shut(ring.petLoop(PetAnimation.idle, i * quantum, quantum: quantum));
        final before = shut(ring.petLoop(PetAnimation.idle, ((i - 1) % steps) * quantum, quantum: quantum));
        if (closed && !before) blinks.add(i);
      }
      expect(blinks, isNotEmpty, reason: 'the idle loop blinks');
      for (final onTaskbar in [false, true]) {
        final director = PetDirector(t.desktop.world);
        // 16 rings of 5 s, drawn every 1/8 s from an odd start: every blink of every ring shows at least once.
        var seen = 0;
        var wasShut = false;
        for (var time = 0.037; time < 16 * WorldPoses.ring; time += 1 / 8) {
          final roam = onTaskbar
              ? StrollSample(x: 0, facing: 1, animation: PetAnimation.idle, animationTime: time, activity: StrollActivity.rest)
              : null;
          final closed = shut(director.pose(time, roam: roam, quantum: quantum).pose);
          if (closed && !wasShut) seen++;
          wasShut = closed;
        }
        expect(seen, greaterThanOrEqualTo(16 * blinks.length), reason: 'every blink of every ring (taskbar: $onTaskbar)');
      }
    });

    test("the world's loops come round exactly on the grid (so their pictures repeat), seamlessly", () {
      final world = w.MochiWorld(seed: 0x5EED5);
      final ring = WorldPoses(world);
      const quantum = 1 / 15;
      for (final loop in const [PetAnimation.idle, PetAnimation.watch, PetAnimation.walk, PetAnimation.sleep]) {
        for (final time in [0.2, 1.7, 3.3, 4.8]) {
          final first = ring.petLoop(loop, 1000 + time, quantum: quantum).toJson();
          final again = ring.petLoop(loop, 1000 + time + 7 * WorldPoses.ring, quantum: quantum).toJson();
          expect(again, first, reason: '${loop.name} at $time');
        }
        // No jump where the ring comes round: the last moment is next to the first.
        final end = ring.petLoop(loop, WorldPoses.ring - 1e-4);
        final start = ring.petLoop(loop, 0);
        expect(end.scaleY, closeTo(start.scaleY, 0.01), reason: '${loop.name} breathes on');
        expect(end.y, closeTo(start.y, 0.01), reason: '${loop.name} steps on');
      }
      for (final loop in const [CompanionAnimation.idleAtDesk, CompanionAnimation.typing, CompanionAnimation.sleep]) {
        final first = ring.companionLoop(loop, 1000.4, quantum: quantum).toJson();
        expect(ring.companionLoop(loop, 1000.4 + 3 * WorldPoses.ring, quantum: quantum).toJson(), first, reason: loop.name);
      }
      expect(WorldPoses.ringTime(1001.21, quantum), WorldPoses.ringTime(1006.21, quantum));
    });

    test('calm, roaming, napping: the Mac\'s rates, and the grid the animations are played on', () {
      const walking = StrollSample(x: 0, facing: 1, animation: PetAnimation.walk, animationTime: 0, activity: StrollActivity.wander, travelling: true);
      expect(MochiView.frameRate(mood: PetMood.relaxed, roam: walking), 25);
      expect(MochiView.frameRate(mood: PetMood.relaxed), 12);
      expect(MochiView.frameRate(mood: PetMood.napping), 6);
      expect(MochiView.frameRate(mood: PetMood.relaxed, oneShot: true), 24);
      // At the taskbar's size a calm loop is drawn 8 times a second (its breathing moves less than a pixel there).
      expect(MochiView.frameRate(mood: PetMood.relaxed, small: true), 8);
      expect(MochiView.frameRate(mood: PetMood.napping, small: true), 6);
      expect(MochiView.frameRate(mood: PetMood.relaxed, roam: walking, small: true), 25);
      expect(MochiView.quantum(25), 1 / 30);
      expect(MochiView.quantum(12), 1 / 15);
      expect(PetDirector.quantize(0.52, 1 / 15), closeTo(8 / 15, 1e-9));
      expect(PetDirector.quantize(0.52, null), 0.52);
    });
  });

  group("Mochi's world", () {
    late TestDesktop t;

    setUp(() => t = TestDesktop.make());
    tearDown(() => t.dispose());

    testWidgets('ticks four times a second while the screen can be seen, and adds no timer while it can\'t', (tester) async {
      final usage = FakeUsage(const SystemActivity(idleSeconds: 2));
      final rhythm = PcRhythm(settings: t.desktop.settings, sampler: usage)..start();
      final world = DesktopWorld(
        settings: t.desktop.settings,
        rhythm: rhythm,
        sounds: t.desktop.sounds,
        toasts: t.toasts,
        uptime: testSeconds,
      )..start();
      expect(world.ticking, isTrue);
      final before = world.world.now;
      await tester.pump(const Duration(seconds: 1));
      expect(world.world.now - before, closeTo(1, 0.01));

      // The display goes off (or the PC is locked): the world stops with everything else, and saves what it learned.
      usage.change(const SystemActivity(idleSeconds: 2, displaysAsleep: true));
      await tester.pump();
      expect(world.ticking, isFalse);
      final asleepAt = world.world.now;
      await tester.pump(const Duration(minutes: 5));
      expect(world.ticking, isFalse, reason: 'still nothing after minutes with the screen off');
      expect(world.world.pet.current.startedAt, lessThanOrEqualTo(asleepAt), reason: 'nothing moved meanwhile');

      // Back: it ticks again.
      usage.change(const SystemActivity(idleSeconds: 0));
      await tester.pump();
      expect(world.ticking, isTrue);
      world.dispose();
      rhythm.dispose();
    });
  });
}
