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
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_desktop/src/core/games.dart';
import 'package:mochi_desktop/src/ui/app.dart';
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
      t.desktop.settings.games = w.GameRecords(catchHighScore: 37, catchGamesPlayed: 4, catchBestCombo: 11, rpsWins: 6, rpsLosses: 4, rpsDraws: 2);
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
