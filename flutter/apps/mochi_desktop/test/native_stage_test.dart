// Mochi's native stage (docs/SPRINT_2.md N1): what goes over the `mochi/stage` channel to the Windows runner and back,
// the pictures (drawn once, premultiplied RGBA, the same as the taskbar's pictures of poses, kept within a budget and
// forgotten in the runner too), and frames that send only what changed.

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_desktop/src/platform/native_stage.dart';
import 'package:mochi_desktop/src/ui/pet/pose_sprites.dart';
import 'package:mochi_desktop/src/ui/stage/stage_cast.dart';
import 'package:mochi_desktop/src/ui/stage/stage_pet.dart';
import 'package:mochi_desktop/src/ui/stage/stage_sprites.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_art/mochi_art.dart' show PetAnimation;

import 'support/fake_stage.dart';
import 'support/fakes.dart';

SpriteRecipe square(Color color, {double size = 10, double ratio = 1}) => SpriteRecipe(
  bounds: Rect.fromLTWH(-size / 2, -size, size, size),
  ratio: ratio,
  paint: (canvas) => canvas.drawRect(Rect.fromLTWH(-size / 2, -size, size, size), Paint()..color = color),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('The channel', () {
    const channel = MethodChannel('mochi/stage');
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'info' ? {'sprites': 2, 'actors': 1} : null;
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    test('a frame is six numbers an actor, all actors in one call; pictures go together, RGBA as it is', () async {
      final stage = ChannelNativeStage();
      final pixels = Uint8List.fromList(List.filled(2 * 3 * 4, 7));
      stage.defineSprites([StageSpriteData(id: 4, width: 2, height: 3, rgba: pixels)]);
      stage.show([
        const StageShot(actor: 1, sprite: 4, left: -20, top: 30, alpha: 128, clickThrough: true),
        const StageShot(actor: 2, sprite: 5, left: 1920, top: 1000, topmost: false, hand: true),
      ]);
      stage
        ..hide([2])
        ..raise([1])
        ..remove([1, 2])
        ..dropSprites([4]);
      await pumpEventQueue();
      expect(calls.map((call) => call.method), ['sprites', 'show', 'hide', 'raise', 'remove', 'drop']);
      final sprites = calls[0].arguments as Map;
      expect(sprites['ids'], [4]);
      expect(sprites['widths'], [2]);
      expect(sprites['heights'], [3]);
      expect((sprites['pixels'] as List).single, pixels);
      expect(calls[1].arguments, isA<Int32List>());
      expect(calls[1].arguments, [1, 4, -20, 30, 128, 1 | 2, 2, 5, 1920, 1000, 255, 4]);
      expect(calls[4].arguments, [1, 2]);
      expect(await stage.info(), {'sprites': 2, 'actors': 1});
      // Nothing to send, nothing sent.
      calls.clear();
      stage
        ..show([])
        ..hide([])
        ..dropSprites([])
        ..defineSprites([]);
      await pumpEventQueue();
      expect(calls, isEmpty);
      stage.dispose();
    });

    test('pointer events and display changes come back from the runner', () async {
      final stage = ChannelNativeStage();
      final events = <StagePointer>[];
      var displays = 0;
      stage.pointer.listen(events.add);
      stage.displaysChanged.listen((_) => displays++);
      Future<void> send(String method, Object? arguments) => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
        'mochi/stage',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );
      await send('pointer', Int32List.fromList([3, 1, 10, 12, 510, 712]));
      await send('pointer', Int32List.fromList([3, 3, 11, 12, 511, 712]));
      await send('pointer', Int32List.fromList([3, 42, 0, 0, 0, 0]));
      await send('displays', null);
      await pumpEventQueue();
      expect(events.map((event) => event.kind), [StagePointerKind.down, StagePointerKind.up], reason: 'an unknown kind is ignored');
      expect((events.first.actor, events.first.x, events.first.y, events.first.screenX, events.first.screenY), (3, 10, 12, 510, 712));
      expect(displays, 1);
      stage.dispose();
    });

    test('the macOS build has no stage', () {
      final stage = NoNativeStage();
      expect(stage.supported, isFalse);
      stage.show([const StageShot(actor: 1, sprite: 1, left: 0, top: 0)]);
      expect(stage.newActor(), 1);
      expect(stage.newActor(), 2, reason: 'ids are still handed out');
    });
  });

  group('Pictures', () {
    testWidgets('drawn once at the display’s scale, premultiplied, with the art’s origin where it was drawn', (tester) async {
      final stage = FakeNativeStage();
      final sprites = StageSprites(stage)..use('1.5|light');
      final recipe = square(const Color(0x80FF0000), ratio: 1.5);
      final sprite = (await tester.runAsync(() => sprites.ensure('red', recipe)))!;
      expect(stage.sprites.keys, [sprite.id]);
      final data = stage.sprites[sprite.id]!;
      expect((data.width, data.height), (sprite.width, sprite.height));
      // 10 logical pixels at 1.5 is 15 physical ones, with a pixel spare on each side.
      expect(sprite.width, inInclusiveRange(15, 18));
      final (ox, oy) = PoseSprites.origin(recipe.bounds, 1.5);
      expect((sprite.originX, sprite.originY), (ox.round(), oy.round()));
      // Just above the origin is inside the square: red at half alpha, premultiplied (R ≈ A).
      final at = ((sprite.originY - 3) * sprite.width + sprite.originX) * 4;
      expect(data.rgba[at + 3], closeTo(128, 2));
      expect(data.rgba[at], closeTo(128, 2), reason: 'premultiplied: red is scaled by alpha');
      expect(data.rgba[at + 1], 0);
      // The spare pixel at the top left is outside what was drawn: transparent.
      expect(data.rgba.sublist(0, 4), [0, 0, 0, 0]);

      // Asked again: the same picture, nothing drawn.
      expect(sprites.lookup('red'), same(sprite));
      expect(await sprites.ensure('red', recipe), same(sprite));
      expect(sprites.drawn, 1);
      expect(stage.callsTo('sprites'), 1);

      // The shot that puts the origin at a point on the screen.
      final shot = sprite.at(9, 1000, 700, clickThrough: true);
      expect((shot.left, shot.top), (1000 - sprite.originX, 700 - sprite.originY));
    });

    testWidgets('asked for twice while drawing: drawn once', (tester) async {
      final stage = FakeNativeStage();
      final sprites = StageSprites(stage)..use('1');
      final (a, b) = (await tester.runAsync(() async {
        final first = sprites.ensure('blue', square(const Color(0xFF0000FF)));
        final second = sprites.ensure('blue', square(const Color(0xFF0000FF)));
        expect(sprites.pending, 1);
        return (await first, await second);
      }))!;
      expect(a, same(b));
      expect(sprites.drawn, 1);
      expect(stage.definedSprites, 1);
    });

    testWidgets('a new context throws every picture away, here and in the runner; one being drawn is dropped', (tester) async {
      final stage = FakeNativeStage();
      final sprites = StageSprites(stage)..use('1|light');
      await tester.runAsync(() => sprites.prepare({'a': square(Colors.red), 'b': square(Colors.green)}));
      expect(stage.sprites, hasLength(2));
      expect(stage.callsTo('sprites'), 1, reason: 'prepared pictures go over together');
      sprites.use('1|dark');
      expect(stage.sprites, isEmpty);
      expect(sprites.length, 0);
      expect(sprites.lookup('a'), isNull);
      // Drawn under the old context but finished under the new one: not kept.
      final late = await tester.runAsync(() {
        final future = sprites.ensure('c', square(Colors.blue));
        sprites.use('2|dark');
        return future;
      });
      expect(late, isNull);
      expect(sprites.length, 0);
    });

    testWidgets('within the budget: the least recently used go first, and the runner forgets them too', (tester) async {
      final stage = FakeNativeStage();
      // A 10 × 10 square is 12 × 12 pixels with its spare edge: 576 bytes. Room for three.
      final sprites = StageSprites(stage, budget: 1800)..use('1');
      for (final key in ['a', 'b', 'c']) {
        await tester.runAsync(() => sprites.ensure(key, square(Colors.red)));
      }
      expect(sprites.length, 3);
      sprites.lookup('a');
      await tester.runAsync(() => sprites.ensure('d', square(Colors.red)));
      expect(sprites.lookup('b'), isNull, reason: 'b was the least recently used');
      expect(sprites.lookup('a'), isNotNull);
      expect(stage.droppedSprites, 1);
      expect(stage.sprites, hasLength(3));
      expect(sprites.bytes, lessThanOrEqualTo(1800));
    });
  });

  group('Frames', () {
    test('only what changed is sent, all of it in one call; hiding and showing again', () {
      final stage = FakeNativeStage();
      final cast = StageCast(stage);
      const a = StageShot(actor: 1, sprite: 1, left: 0, top: 0);
      const b = StageShot(actor: 2, sprite: 2, left: 10, top: 0);
      cast
        ..place(a)
        ..place(b)
        ..flush();
      expect(stage.callsTo('show'), 1);
      expect(stage.shots, [a, b]);
      // The same again: nothing at all.
      cast
        ..place(a)
        ..place(b)
        ..flush();
      expect(stage.callsTo('show'), 1);
      expect(cast.unchanged, 2);
      // One moves: only that one.
      cast
        ..place(a.copyWith(left: 4))
        ..place(b)
        ..flush();
      expect(stage.shots.last, a.copyWith(left: 4));
      expect(stage.shots, hasLength(3));
      // Two changes before a flush: the last wins.
      cast
        ..place(b.copyWith(top: 1))
        ..place(b.copyWith(top: 2))
        ..flush();
      expect(stage.shots.last, b.copyWith(top: 2));
      expect(stage.shots, hasLength(4));
      cast
        ..hide(1)
        ..flush();
      expect(stage.showing.keys, [2]);
      expect(cast.showing(1), isFalse);
      // Shown again with the same shot as before it hid: sent (the window is hidden).
      cast
        ..place(a.copyWith(left: 4))
        ..flush();
      expect(stage.showing.keys, containsAll([1, 2]));
      cast.remove([1, 2]);
      expect(stage.windows, isEmpty);
    });
  });

  test('the same picture as the taskbar’s: PoseSprites.render puts the origin where PoseSprites.origin says', () async {
    const bounds = Rect.fromLTRB(-20, -30, 20, 5);
    final image = PoseSprites.render(bounds: bounds, ratio: 2, paint: (canvas) => canvas.drawCircle(Offset.zero, 2, Paint()..color = Colors.black));
    final (ox, oy) = PoseSprites.origin(bounds, 2);
    expect((image.width, image.height), ((ox + 40).ceil() + 1, (oy + 10).ceil() + 1));
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    expect(bytes.getUint8(((oy.round()) * image.width + ox.round()) * 4 + 3), 255, reason: 'the dot is at the origin');
    image.dispose();
  });

  group('Mochi on the stage', () {
    late TestDesktop t;
    late FakeNativeStage stage;
    late StageCast cast;
    late StageSprites sprites;
    late StagePet pet;

    setUp(() {
      t = TestDesktop.make();
      stage = FakeNativeStage();
      cast = StageCast(stage);
      sprites = StageSprites(stage);
      pet = StagePet(stage: stage, cast: cast, sprites: sprites, world: t.desktop.world, settings: t.desktop.settings);
    });

    tearDown(() => t.dispose());

    StrollSample sitting() => const StrollSample(x: 0, facing: 1, animation: PetAnimation.sit, animationTime: 0, activity: StrollActivity.rest);

    testWidgets('its feet where it’s told, at the display’s scale; the same pose again sends nothing; a move moves the same picture', (
      tester,
    ) async {
      final time = t.desktop.world.now();
      expect(pet.draw(time: time, motion: sitting(), feet: (600, 900), ratio: 1.5), isFalse, reason: 'the picture is being drawn');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      final shot = stage.showing[pet.actor]!;
      final sprite = pet.sprite!;
      expect((shot.left + sprite.originX, shot.top + sprite.originY), (600, 900));
      expect(shot.clickThrough, isFalse);
      expect(shot.hand, isTrue, reason: 'Mochi can be petted');
      // Mochi is drawn at 1.5 × its size: about 54 art units tall at 1.2 logical pixels each.
      expect(sprite.height, greaterThan(54 * 1.2 * 1.5));
      final calls = stage.callsTo('show');

      expect(pet.draw(time: time, motion: sitting(), feet: (600, 900), ratio: 1.5), isTrue);
      expect(stage.callsTo('show'), calls, reason: 'nothing changed');

      pet.draw(time: time, motion: sitting(), feet: (640, 900), ratio: 1.5);
      expect(stage.showing[pet.actor]!.sprite, sprite.id, reason: 'the same picture');
      expect(stage.showing[pet.actor]!.left, shot.left + 40);
      expect(stage.definedSprites, 1);

      // Fading (a hop): the window's opacity, not a new picture.
      pet.draw(time: time, motion: sitting(), feet: (640, 900), ratio: 1.5, opacity: 0.5, clickThrough: true);
      expect(stage.showing[pet.actor]!.alpha, closeTo(128, 1));
      expect(stage.showing[pet.actor]!.clickThrough, isTrue);
      expect(stage.definedSprites, 1);

      // Onto a display at another scale: drawn again for it, the old pictures forgotten.
      pet.draw(time: time, motion: sitting(), feet: (2400, 900), ratio: 1, clickThrough: true);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(stage.definedSprites, 2);
      expect(stage.sprites.keys, [pet.sprite!.id]);
      expect(pet.sprite!.height, lessThan(sprite.height));

      pet.hide();
      expect(stage.showing, isEmpty);
      expect(pet.feet, isNull);
    });

    testWidgets('a walk’s poses come round on the ring: drawn once each, then reused', (tester) async {
      var drawnAfterFirstLap = 0;
      for (var lap = 0; lap < 2; lap++) {
        for (var i = 0; i < 75; i++) {
          final odometer = i / 15;
          pet.draw(
            time: 1000 + lap * 5 + i / 15,
            motion: StrollSample(
              x: 0,
              facing: 1,
              animation: PetAnimation.walk,
              animationTime: odometer,
              activity: StrollActivity.trot,
              travelling: true,
            ),
            feet: (100 + i * 4, 900),
            ratio: 1,
          );
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
        }
        if (lap == 0) drawnAfterFirstLap = sprites.drawn;
      }
      expect(drawnAfterFirstLap, greaterThan(5));
      expect(sprites.drawn, drawnAfterFirstLap, reason: 'the second lap draws nothing new');
    });
  });
}
