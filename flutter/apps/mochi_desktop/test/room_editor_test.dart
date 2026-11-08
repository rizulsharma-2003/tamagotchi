// The room makeover on Windows (docs/SPRINT_2.md W18), as the Mac's RoomEditorController: the twelve pieces unlocked by
// friendship and achievements, added from the tray (a click or a drag), dragged about in their band, flipped, put away
// (a button, the keyboard, or dropped on the tray), at most eight; kept under the Mac's `room` key and drawn in every
// room. Decorate in the popover (the Mac's) or from the menus in Mochi's window; Settings › Fun › Room. Light and dark,
// 1× and 2× text, the keyboard and the screen reader.

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart' show MemoryWorldStore;
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/room_editor.dart';
import 'package:mochi_desktop/src/ui/pet/room_view.dart';
import 'package:mochi_desktop/src/ui/popover/popover_view.dart';
import 'package:mochi_desktop/src/ui/shell.dart';

import 'support/fakes.dart';

/// A friendship at level 2 with the first session and turn earned: the lamp, the bookshelf, the clock and the photo
/// are unlocked besides the four everyone has.
MemoryWorldStore friends() => MemoryWorldStore({
  'v': 1,
  'seed': 7,
  'world': {
    'v': 1,
    'progress': {
      'affectionPoints': 42,
      'interactionDays': ['2026-10-28', '2026-10-30', '2026-11-02'],
      'firstMetAt': DateTime(2026, 10, 25).toUtc().toIso8601String(),
      'unlocked': {
        'firstSession': DateTime(2026, 10, 25, 10).toUtc().toIso8601String(),
        'firstTurn': DateTime(2026, 10, 25, 10, 20).toUtc().toIso8601String(),
      },
    },
    'history': <Object?>[],
  },
});

void main() {
  final now = DateTime(2026, 11, 20, 15);
  late TestDesktop t;

  group('Arranging', () {
    tearDown(() => t.dispose());

    test('only unlocked pieces; each kept under the Mac’s `room` key, snapped into its band', () {
      t = TestDesktop.make(clock: () => now);
      final room = t.desktop.room;
      expect(room.add(FurnitureCatalog.kind('lamp')!), isNull, reason: 'the lamp needs friendship level 1');
      final rug = room.add(FurnitureCatalog.kind('rug')!)!;
      expect(room.selection, rug.id, reason: 'a new piece is selected');
      final saved = (t.document.json!['room']! as Map)['items']! as List;
      expect((saved.single as Map).keys, containsAll(['id', 'kind', 'x', 'y', 'flipped']));
      final poster = room.add(FurnitureCatalog.kind('poster')!, position: (0.3, 0.9))!;
      expect(poster.y, RoomLayout.wallBand.$2, reason: 'a wall piece stays on the wall');
      room.move(poster.id, (0.8, 0.1));
      expect(t.desktop.settings.room.items.last.y, RoomLayout.wallBand.$1);
      room.flip(poster.id);
      expect(t.desktop.settings.room.items.last.flipped, isTrue);
      room.remove(poster.id);
      expect(t.desktop.settings.room.items.map((i) => i.kind), ['rug']);
      room.clear();
      expect(t.desktop.settings.room.items, isEmpty);
    });

    test('friendship and achievements unlock more; eight pieces at most', () {
      t = TestDesktop.make(clock: () => now, worldStore: friends());
      final room = t.desktop.room;
      final unlocked = FurnitureCatalog.unlocked(room.progress).map((k) => k.id).toSet();
      expect(unlocked, {'rug', 'cushion', 'plant', 'poster', 'lamp', 'bookshelf', 'clock', 'photo'});
      for (final id in unlocked) {
        expect(room.add(FurnitureCatalog.kind(id)!), isNotNull, reason: id);
      }
      expect(t.desktop.settings.room.isFull, isTrue);
      expect(room.add(FurnitureCatalog.kind('rug')!), isNull, reason: 'the room is full');
      expect(t.desktop.settings.room.summary(room.progress), '8 of 12 pieces unlocked · 8 of 8 placed');
    });

    test('dropping: a new piece lands where it’s dropped; a placed one dropped on the tray is put away', () {
      t = TestDesktop.make(clock: () => now);
      final room = t.desktop.room..begin();
      final plant = FurnitureCatalog.kind('plant')!;
      room.pickUp(plant, anchor: const Offset(100, 200));
      room.follow(anchor: const Offset(100, 200), overTray: false);
      room.drop((0.3, 0.9));
      final placed = t.desktop.settings.room.items.single;
      expect((placed.kind, placed.x), ('plant', 0.3));
      room.lift(placed, plant, anchor: const Offset(100, 200));
      expect(RoomDecor.liftedID, placed.id, reason: 'the scene leaves it out while it’s carried');
      room.follow(anchor: const Offset(100, 20), overTray: true);
      room.drop((0.3, 0.9));
      expect(t.desktop.settings.room.items, isEmpty);
      expect(RoomDecor.liftedID, isNull);
      room.pickUp(plant, anchor: const Offset(100, 20));
      room.drop((0.3, 0.9));
      expect(t.desktop.settings.room.items, isEmpty, reason: 'a new piece let go over the tray is cancelled');
    });
  });

  group('Decorating on screen', () {
    late FakeShell shell;

    setUp(() {
      shell = FakeShell();
      t = TestDesktop.make(clock: () => now, worldStore: friends());
    });
    tearDown(() => t.dispose());

    Future<DesktopAppState> open(WidgetTester tester, {double scale = 1, ThemeMode theme = ThemeMode.light, MainPage page = MainPage.home, SettingsTab? pane}) async {
      t.desktop.settings.themeMode = theme;
      tester.view.physicalSize = page == MainPage.settings ? SurfaceSizes.settings : SurfaceSizes.main;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: shell,
          initialSurface: Surface.main,
          initialPage: page,
          initialPane: pane,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      return tester.state<DesktopAppState>(find.byType(DesktopApp));
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    }

    Finder tray(String id) {
      final kind = FurnitureCatalog.kind(id)!;
      return find.byTooltip('${kind.title} — drag into the room, or click to add');
    }

    testWidgets('the tray from the menus: a click adds, a drag places, Flip and Remove, Escape is done', (tester) async {
      final state = await open(tester);
      shell.controller.add(ShellAction.decorate);
      await tester.pump(const Duration(milliseconds: 300));
      expect((state.page, t.desktop.room.isEditing), (MainPage.home, true));
      expect(find.byType(RoomEditorOverlay), findsOneWidget);
      expect(find.byType(FurnitureIcon), findsNWidgets(12), reason: 'the whole catalogue');
      expect(find.byTooltip('Toy Box — Unlock: Good Friends — Reach friendship level 3.'), findsNothing);
      expect(find.byTooltip(RegExp('^Fish Bowl — Unlock: ')), findsOneWidget, reason: 'locked, with how to earn it');

      await tester.tap(tray('rug'));
      await tester.pump();
      expect(t.desktop.settings.room.items.map((i) => i.kind), ['rug']);
      expect(find.byTooltip('Flip Round Rug'), findsOneWidget, reason: 'the new piece is selected');
      await tester.tap(find.byTooltip('Flip Round Rug'));
      await tester.pump();
      expect(t.desktop.settings.room.items.single.flipped, isTrue);

      final roomRect = tester.getRect(find.byType(RoomView));
      // With the mouse, as on a PC (Mochi's window doesn't scroll by dragging with it).
      final gesture = await tester.startGesture(tester.getCenter(tray('plant')), kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(0, 30));
      await tester.pump();
      await gesture.moveTo(Offset(roomRect.left + roomRect.width * 0.8, roomRect.bottom - 60));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      final plant = t.desktop.settings.room.items.firstWhere((i) => i.kind == 'plant');
      expect(plant.x, closeTo(0.8, 0.05), reason: 'placed where it was dropped');

      await tester.tap(find.byTooltip('Remove Big Plant'));
      await tester.pump();
      expect(t.desktop.settings.room.items.map((i) => i.kind), ['rug']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(t.desktop.room.isEditing, isFalse);
      expect(find.byType(RoomEditorOverlay), findsNothing);
      expect(state.surface, Surface.main, reason: 'Escape ended decorating first');
      await close(tester);
    });

    testWidgets('a placed piece dragged back onto the tray is put away; from the keyboard: arrows, F and Delete', (tester) async {
      await open(tester);
      final rug = t.desktop.room.add(FurnitureCatalog.kind('rug')!)!;
      t.desktop.room.begin();
      await tester.pump();
      final handle = find.byTooltip('Round Rug — drag to move');
      final start = tester.getCenter(handle);
      final roomRect = tester.getRect(find.byType(RoomView));
      final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      expect(t.desktop.room.drag?.existing, rug.id);
      await gesture.moveTo(Offset(roomRect.center.dx, roomRect.top + 15));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(t.desktop.settings.room.items, isEmpty, reason: 'dropped on the tray');

      final again = t.desktop.room.add(FurnitureCatalog.kind('poster')!)!;
      await tester.pump();
      final x = again.x;
      final focus = find.descendant(of: find.byType(RoomEditorOverlay), matching: find.byWidgetPredicate((w) => w is Focus && w.onFocusChange != null));
      Focus.of(tester.element(find.descendant(of: focus.first, matching: find.byType(MouseRegion)).first)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(t.desktop.settings.room.items.single.x, greaterThan(x));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(t.desktop.settings.room.items.single.flipped, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(t.desktop.settings.room.items, isEmpty);
      t.desktop.room.end();
      await close(tester);
    });

    testWidgets('the popover’s Decorate decorates its own room, light and dark at 1× and 2× text', (tester) async {
      final handle = tester.ensureSemantics();
      final companion = CompanionDirector(t.desktop.world);
      addTearDown(companion.dispose);
      for (final theme in [ThemeMode.light, ThemeMode.dark]) {
        for (final scale in [1.0, 2.0]) {
          tester.view.physicalSize = SurfaceSizes.popover;
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(brightness: theme == ThemeMode.dark ? Brightness.dark : Brightness.light),
              home: Scaffold(
                body: PopoverView(
                  desktop: t.desktop,
                  companion: companion,
                  lastActivity: () => now,
                  onClose: () {},
                  onOpenMain: () {},
                  onAsk: () {},
                  onSettings: () {},
                  onSetUpClaude: () {},
                ),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 300));
          final decorate = find.bySemanticsLabel('Decorate Mochi’s room');
          await tester.ensureVisible(decorate);
          await tester.tap(decorate);
          await tester.pump(const Duration(milliseconds: 300));
          expect(t.desktop.room.isEditing, isTrue);
          expect(find.byType(RoomEditorOverlay), findsOneWidget);
          expect(tester.takeException(), isNull, reason: '${theme.name} ${scale}x');
          expect(find.bySemanticsLabel('Done decorating'), findsOneWidget);
          t.desktop.room.end();
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 6));
        }
      }
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.reset();
      handle.dispose();
    });

    testWidgets('closing the window puts the tray away; a holiday’s note waits until decorating is done', (tester) async {
      final state = await open(tester);
      state.openDecorate();
      await tester.pump(const Duration(milliseconds: 300));
      expect(t.desktop.room.isEditing, isTrue);
      t.desktop.settings.setBirthday(11, 20);
      expect(t.desktop.world.toastNow.value?.title, isNot('Happy Birthday!'), reason: 'not over the tray');
      t.desktop.room.end();
      t.desktop.holidays.showPendingToast();
      expect(t.desktop.world.toastNow.value?.title, 'Happy Birthday!');
      state.openDecorate();
      await tester.pump(const Duration(milliseconds: 300));
      state.closeMain();
      await tester.pump(const Duration(milliseconds: 300));
      expect(t.desktop.room.isEditing, isFalse);
      await close(tester);
    });

    testWidgets('the room is drawn with its furniture', (tester) async {
      t.desktop.room.add(FurnitureCatalog.kind('bookshelf')!);
      await open(tester);
      final painter = tester.widget<CustomPaint>(find.descendant(of: find.byType(RoomView), matching: find.byType(CustomPaint)).first).painter;
      expect((painter! as LiveRoomPainter).config.room.items.single.kind, 'bookshelf');
      await close(tester);
    });

    testWidgets('Settings › Fun › Room: what’s placed, put away, Clear Room and Decorate…', (tester) async {
      t.desktop.room
        ..add(FurnitureCatalog.kind('lamp')!)
        ..add(FurnitureCatalog.kind('photo')!)
        ..end();
      final state = await open(tester, page: MainPage.settings, pane: SettingsTab.fun);
      await tester.ensureVisible(find.text('Clear Room'));
      expect(find.text('Floor Lamp'), findsOneWidget);
      expect(find.text('8 of 12 pieces unlocked · 2 of 8 placed'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Remove Floor Lamp'));
      await tester.tap(find.byTooltip('Remove Floor Lamp'));
      await tester.pump();
      expect(t.desktop.settings.room.items.map((i) => i.kind), ['photo']);
      await tester.tap(find.text('Clear Room'));
      await tester.pump();
      expect(t.desktop.settings.room.items, isEmpty);
      expect(find.text('Room furniture'), findsNothing, reason: 'no “Not on Windows yet” row any more');
      await tester.ensureVisible(find.text('Decorate…'));
      await tester.tap(find.text('Decorate…'));
      await tester.pump(const Duration(milliseconds: 300));
      expect((state.page, t.desktop.room.isEditing), (MainPage.home, true));
      t.desktop.room.end();
      await close(tester);
    });
  });
}
