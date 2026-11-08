// Pictures of Sprint 2's "Mochi's life on Windows, part 2" (W14 games, W15 focus, W16 recap, W18 room, W20 holidays,
// W21 purr), drawn by the app itself with its real fonts (not screen captures), for reviewing on a machine without the
// Windows VM.
//
//   MOCHI_SHOTS=/some/folder flutter test tool/render_s2w4_shots_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_desktop/src/core/games.dart';
import 'package:mochi_desktop/src/ui/recap/recap_card.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart' show CompanionVisibility;
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_world/mochi_world.dart' as w;

import '../test/support/fakes.dart';

void main() {
  final out = Directory(Platform.environment['MOCHI_SHOTS'] ?? 'build/shots')..createSync(recursive: true);
  late TestDesktop t;
  final now = DateTime(2026, 11, 8, 18, 30);

  /// A friendship two weeks old: level 2, a few achievements.
  MemoryWorldStore friends() => MemoryWorldStore({
    'v': 1,
    'seed': 0x5EED5,
    'world': {
      'v': 1,
      'progress': {
        'affectionPoints': 42,
        'interactionDays': ['2026-10-28', '2026-10-30', '2026-11-02', '2026-11-05', '2026-11-07'],
        'firstMetAt': DateTime(2026, 10, 25).toUtc().toIso8601String(),
        'unlocked': {
          'firstSession': DateTime(2026, 10, 25, 10).toUtc().toIso8601String(),
          'firstTurn': DateTime(2026, 10, 25, 10, 20).toUtc().toIso8601String(),
          'firstGreenBuild': DateTime(2026, 11, 2, 16).toUtc().toIso8601String(),
        },
      },
      'history': <Object?>[],
    },
  });

  setUp(() => t = TestDesktop.make(saved: hostCredentials, clock: () => now, worldStore: friends(), settings: {'lifeStageSeen': 2}));
  tearDown(() => t.dispose());

  setUpAll(() async {
    final nunito = FontLoader('packages/mochi_ui/Nunito');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold', 'ExtraBold']) {
      nunito.addFont(Future.value(ByteData.sublistView(File('../../packages/mochi_ui/fonts/Nunito-$weight.ttf').readAsBytesSync())));
    }
    await nunito.load();
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!Directory('${sdk.path}/artifacts/material_fonts').existsSync() && sdk.parent.path != sdk.path) {
      sdk = sdk.parent;
    }
    final icons = File('${sdk.path}/artifacts/material_fonts/MaterialIcons-Regular.otf');
    if (icons.existsSync()) {
      await (FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())))).load();
    }
  });

  Future<void> save(WidgetTester tester, String name, Size size) async {
    await tester.runAsync(() async {
      final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
      final image = await layer.toImage(Offset.zero & size);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  }

  Future<DesktopAppState> app(
    WidgetTester tester, {
    required Size size,
    Surface surface = Surface.main,
    MainPage page = MainPage.home,
    SettingsTab? pane,
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    await tester.pumpWidget(
      DesktopApp(
        desktop: t.desktop,
        shell: FakeShell(),
        initialSurface: surface,
        initialPage: page,
        initialPane: pane,
        library: Future<PoseLibrary?>.value(),
        strollClock: () => tester.binding.clock.now().microsecondsSinceEpoch / 1e6,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    return tester.state<DesktopAppState>(find.byType(DesktopApp));
  }

  Future<void> frames(WidgetTester tester, Duration duration) async {
    for (var ms = 0; ms < duration.inMilliseconds; ms += 16) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('W14 games, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      t.desktop.settings.games = w.GameRecords(
        catchHighScore: 37,
        catchGamesPlayed: 4,
        catchBestCombo: 11,
        rpsWins: 6,
        rpsLosses: 4,
        rpsDraws: 2,
      );
      await app(tester, size: SurfaceSizes.games, page: MainPage.games);
      await save(tester, 'w14-catch-ready-${theme.name}', SurfaceSizes.games);
      final games = t.desktop.games..startCatch();
      final game = games.session.game..autoSpawn = false;
      await frames(tester, const Duration(milliseconds: 200));
      // A run of catches, a golden cookie on its way and one on the floor.
      for (var i = 0; i < 7; i++) {
        game.drop(w.TreatKind.cookie, game.petX, y: 0.25);
        await frames(tester, const Duration(milliseconds: 260));
      }
      game.drop(w.TreatKind.fish, 0.2, y: 0.8);
      game.drop(w.TreatKind.berry, 0.78, y: 0.55);
      game.drop(w.TreatKind.golden, 0.62, y: 0.95);
      game.drop(w.TreatKind.cookie, game.petX, y: 0.2);
      await frames(tester, const Duration(milliseconds: 300));
      await save(tester, 'w14-catch-playing-${theme.name}', SurfaceSizes.games);
      for (final x in [0.05, 0.95, 0.9]) {
        game.drop(w.TreatKind.cookie, x, y: 0.4);
      }
      await frames(tester, const Duration(seconds: 3));
      await save(tester, 'w14-catch-over-${theme.name}', SurfaceSizes.games);
      games.tab = GameTab.rps;
      await tester.pump(const Duration(milliseconds: 300));
      await save(tester, 'w14-rps-ready-${theme.name}', SurfaceSizes.games);
      games.pick(w.RPSChoice.scissors);
      await frames(tester, const Duration(milliseconds: 700));
      await save(tester, 'w14-rps-shake-${theme.name}', SurfaceSizes.games);
      await frames(tester, const Duration(milliseconds: 1500));
      await save(tester, 'w14-rps-result-${theme.name}', SurfaceSizes.games);
      await frames(tester, const Duration(seconds: 2));
      games.tab = GameTab.catchTreats;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
    });
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('W15 focus in the popover, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      final state = await app(tester, size: SurfaceSizes.popover, surface: Surface.pet);
      t.desktop.focus.begin();
      state.openPopover();
      await frames(tester, const Duration(milliseconds: 900));
      t.desktop.world.tick();
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester, 'w15-popover-focus-${theme.name}', SurfaceSizes.popover);
      t.desktop.focus.skip();
      t.desktop.world.tick();
      await frames(tester, const Duration(milliseconds: 1500));
      t.desktop.world.tick();
      await tester.pump(const Duration(milliseconds: 100));
      await save(tester, 'w15-popover-break-${theme.name}', SurfaceSizes.popover);
      t.desktop.focus.stop();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
    });
  }

  testWidgets('W15 Settings › Fun › Focus buddy', (tester) async {
    await app(tester, size: SurfaceSizes.settings, page: MainPage.settings, pane: SettingsTab.fun);
    await tester.ensureVisible(find.text('Focus buddy'));
    await tester.pump(const Duration(milliseconds: 300));
    await save(tester, 'w15-settings-focus', SurfaceSizes.settings);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  /// A day's work in "web" and "api": turns, tests, an error bounced back, a milestone, a focus block.
  void busyDay() {
    var at = DateTime(2026, 11, 8, 9, 12);
    void claude(String event, {String session = 's1', String project = 'web', String? tool, String? id, String? kind}) {
      final wire = hook(event, session: session, project: project, tool: tool, toolUseId: id, at: at);
      if (kind != null) {
        wire
          ..commandKind = kind
          ..commandReliable = true;
      }
      t.desktop.sessions.apply(wire);
      t.desktop.world.ingest(wire);
      at = at.add(const Duration(minutes: 7));
    }

    claude('SessionStart');
    for (var i = 0; i < 4; i++) {
      claude('UserPromptSubmit');
      claude('PreToolUse', tool: 'Read', id: 'r$i');
      claude('PostToolUse', tool: 'Read', id: 'r$i');
      claude('PreToolUse', tool: 'Bash', id: 'b$i', kind: 'test');
      claude('PostToolUse', tool: 'Bash', id: 'b$i', kind: 'test');
      if (i == 2) claude('PostToolUseFailure', tool: 'Edit', id: 'e$i');
      claude('Stop');
    }
    claude('SessionStart', session: 's2', project: 'api');
    claude('UserPromptSubmit', session: 's2', project: 'api');
    claude('Stop', session: 's2', project: 'api');
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('W16 today’s recap, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      busyDay();
      await app(tester, size: SurfaceSizes.recap, page: MainPage.recap);
      await frames(tester, const Duration(milliseconds: 1500));
      await save(tester, 'w16-recap-${theme.name}', SurfaceSizes.recap);
      if (theme == ThemeMode.light) {
        final screen = tester.state(find.byWidgetPredicate((widget) => widget.runtimeType.toString() == 'RecapScreen'));
        expect(screen, isNotNull);
        await tester.runAsync(() async {
          final look = RecapLook(
            petName: 'Mochi',
            companionName: 'Patch',
            formatTime: (utc) {
              final time = utc.toLocal();
              return '${time.hour > 12 ? time.hour - 12 : time.hour}:${time.minute.toString().padLeft(2, '0')} ${time.hour >= 12 ? 'PM' : 'AM'}';
            },
          );
          final image = await RecapImage.render(t.desktop.recap.recap(), look, now);
          File('${out.path}/w16-recap-exported.png').writeAsBytesSync(image.png);
          final quiet = await RecapImage.render(t.desktop.recap.recap(DateTime(2026, 11, 7)), look, now);
          File('${out.path}/w16-recap-quiet-exported.png').writeAsBytesSync(quiet.png);
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
    });
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('W21 purring, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      await app(tester, size: SurfaceSizes.pet, surface: Surface.pet);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(MochiView)));
      await frames(tester, const Duration(milliseconds: 1400));
      await save(tester, 'w21-desktop-pet-purring-${theme.name}', SurfaceSizes.pet);
      await gesture.up();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
      await app(tester, size: SurfaceSizes.main);
      final room = await tester.startGesture(tester.getCenter(find.bySemanticsLabel(RegExp('^Mochi. Click to pet'))));
      await frames(tester, const Duration(milliseconds: 1400));
      await save(tester, 'w21-room-purring-${theme.name}', SurfaceSizes.main);
      await room.up();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
    });
  }

  for (final day in [DateTime(2026, 11, 8), DateTime(2026, 10, 30), DateTime(2026, 12, 20)]) {
    testWidgets('W20 the taskbar strip on ${day.month}/${day.day}: Patch’s desk decorated, both in costume (2×)', (tester) async {
      final t = TestDesktop.make(clock: () => DateTime(day.year, day.month, day.day, 12), worldStore: friends(), settings: {'lifeStageSeen': 2});
      const ratio = 2.0;
      final companion = CompanionDirector(t.desktop.world);
      t.desktop.settings.companionVisibility = CompanionVisibility.always;
      const unit = 40 * SurfaceSizes.taskbarFill / 66;
      final stage = TaskbarStage(bar: const PixelRect(0, 1032, 1920, 1080), scale: 1, zones: const [(minX: 190.0, maxX: 680.0)]);
      final home = stage.home(unit: unit, near: 400)!;
      final width = stage.homeWidth(home);
      final frame = stage.homeFrame(home, Size(width, stage.box.height));
      final layout = DuoLayout(home: home, originX: frame.left.toDouble());
      final size = Size(width, stage.box.height);
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = size * ratio;
      addTearDown(tester.view.reset);
      final now = DateTime(day.year, day.month, day.day, 12);
      final sample = StrollSample(x: home.petHome, facing: 1, animation: PetAnimation.sit, animationTime: 2, activity: StrollActivity.company);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: ratio),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: ColoredBox(
              color: const Color(0xFF202020),
              child: MochiView(
                world: t.desktop.world,
                sessions: t.desktop.sessions,
                lastActivity: () => t.desktop.sessions.now,
                fill: SurfaceSizes.taskbarFill,
                feet: SurfaceSizes.taskbarFeet,
                detail: RenderDetail.tiny,
                stroll: () => sample,
                companion: companion,
                duo: () => layout,
                burst: true,
                theme: OfficeTheme.cozyDesk,
                accessory: t.desktop.settings.wornByPet(now),
                companionAccessory: t.desktop.settings.wornByCompanion(now),
                deskAccessory: Accessory.plant,
                season: () => t.desktop.holidays.event,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 6));
      t.desktop.world.tick();
      await tester.pump(const Duration(milliseconds: 100));
      await save(tester, 'w20-taskbar-${t.desktop.holidays.event?.name ?? 'none'}', size * ratio);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
      companion.dispose();
      await t.dispose();
    });
  }

  testWidgets('W20 Settings › Fun › Holidays', (tester) async {
    await app(tester, size: SurfaceSizes.settings, page: MainPage.settings, pane: SettingsTab.fun);
    await tester.ensureVisible(find.text('Holidays'));
    await tester.pump(const Duration(milliseconds: 300));
    await save(tester, 'w20-settings-holidays', SurfaceSizes.settings);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  /// A furnished room (the Mac's room:demo), with what the friendship has unlocked.
  void furnish() {
    final room = t.desktop.room;
    for (final (id, x, y) in const [
      ('rug', 0.47, 0.92),
      ('bookshelf', 0.06, 0.87),
      ('plant', 0.16, 0.89),
      ('poster', 0.6, 0.3),
      ('clock', 0.47, 0.3),
      ('lamp', 0.95, 0.87),
      ('photo', 0.37, 0.36),
      ('fishBowl', 0.87, 0.9),
    ]) {
      room.add(FurnitureCatalog.kind(id)!, position: (x, y));
    }
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('W18 decorating, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      furnish();
      final state = await app(tester, size: SurfaceSizes.popover, surface: Surface.pet);
      state.openPopover();
      await frames(tester, const Duration(milliseconds: 900));
      await save(tester, 'w18-popover-furnished-${theme.name}', SurfaceSizes.popover);
      t.desktop.room.begin();
      t.desktop.room.selection = t.desktop.settings.room.items[3].id;
      await frames(tester, const Duration(milliseconds: 300));
      await save(tester, 'w18-popover-decorating-${theme.name}', SurfaceSizes.popover);
      t.desktop.room.end();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
      final window = await app(tester, size: SurfaceSizes.main);
      window.openDecorate();
      final room = t.desktop.room;
      final shelf = t.desktop.settings.room.items[1];
      room.lift(shelf, FurnitureCatalog.kind('bookshelf')!, anchor: const Offset(260, 236));
      await frames(tester, const Duration(milliseconds: 300));
      await save(tester, 'w18-window-dragging-${theme.name}', SurfaceSizes.main);
      room.cancelDrag();
      room.end();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 8));
    });
  }

  testWidgets('W18 Settings › Fun › Room', (tester) async {
    furnish();
    await app(tester, size: SurfaceSizes.settings, page: MainPage.settings, pane: SettingsTab.fun);
    await tester.ensureVisible(find.text('Clear Room'));
    await tester.pump(const Duration(milliseconds: 300));
    await save(tester, 'w18-settings-room', SurfaceSizes.settings);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('W14 games at 2× text', (tester) async {
    await app(tester, size: SurfaceSizes.games, page: MainPage.games, scale: 2);
    await save(tester, 'w14-catch-ready-2x', SurfaceSizes.games);
    t.desktop.games.tab = GameTab.rps;
    await tester.pump(const Duration(milliseconds: 300));
    await save(tester, 'w14-rps-ready-2x', SurfaceSizes.games);
    t.desktop.games.tab = GameTab.catchTreats;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
