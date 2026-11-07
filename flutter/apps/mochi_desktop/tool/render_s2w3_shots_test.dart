// Pictures of Sprint 2's "Mochi's life on Windows, part 1" (G1, G2, W11, W12, W13), drawn by the app itself with its real
// fonts (not screen captures): Mochi and Patch from Mochi's world on the taskbar strip mid high five, the desktop pet
// talking, the popover with the friendship row and a bubble in the room, Mochi's window, and Settings › Fun (Talking,
// Growing up) and Characters › Friendship. For reviewing on a machine without the Windows VM.
//
//   MOCHI_SHOTS=/some/folder flutter test tool/render_s2w3_shots_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart' show CompanionVisibility;
import 'package:mochi_desktop/src/core/desktop_world.dart';
import 'package:mochi_desktop/src/platform/taskbar.dart';
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/pet/companion_director.dart';
import 'package:mochi_desktop/src/ui/pet/mochi_view.dart';
import 'package:mochi_desktop/src/ui/pet/stroller.dart';
import 'package:mochi_desktop/src/ui/pet/taskbar_stroll.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_wire/mochi_wire.dart' show WireEvent;
import 'package:mochi_world/mochi_world.dart' as w;

import '../test/support/fakes.dart';

void main() {
  final out = Directory(Platform.environment['MOCHI_SHOTS'] ?? 'build/shots')..createSync(recursive: true);
  late TestDesktop t;
  final now = DateTime(2026, 11, 8, 9, 30);

  /// A friendship two weeks old: level 2, a few achievements, a young cat.
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

  setUp(() => t = TestDesktop.make(saved: hostCredentials, clock: () => now, worldStore: friends(), settings: {'lifeStageSeen': 1}));
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

  Future<void> app(WidgetTester tester, {required Size size, Surface surface = Surface.main, MainPage page = MainPage.home, SettingsTab? pane, double scale = 1}) async {
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
  }

  /// One of Claude Code's hook events, as the bridge hands it over (the sessions and Mochi's world).
  void claude(WireEvent event) {
    t.desktop.sessions.apply(event);
    t.desktop.world.ingest(event);
  }

  /// A live Claude turn in "web", Patch at his desk.
  Future<void> session(WidgetTester tester) async {
    claude(hook('SessionStart', at: now));
    await tester.pump(const Duration(seconds: 9));
    t.desktop.world.tick();
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    for (final scale in [1.0, 2.0]) {
      final suffix = '${theme.name}${scale == 1 ? '' : '-2x'}';

      testWidgets('Settings › Fun and Characters, $suffix', (tester) async {
        t.desktop.settings.themeMode = theme;
        await app(tester, size: SurfaceSizes.settings, page: MainPage.settings, pane: SettingsTab.fun, scale: scale);
        await save(tester, 'settings-fun-$suffix', SurfaceSizes.settings);
        final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
        state.settingsNavigation.tab = SettingsTab.characters;
        await tester.pump(const Duration(milliseconds: 300));
        await tester.ensureVisible(find.text('Friendship'));
        await tester.pump(const Duration(milliseconds: 300));
        await save(tester, 'settings-friendship-$suffix', SurfaceSizes.settings);
        await tester.pumpWidget(const SizedBox());
      });
    }

    testWidgets('the popover and Mochi’s window, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      await app(tester, size: SurfaceSizes.popover, surface: Surface.pet);
      await session(tester);
      tester.state<DesktopAppState>(find.byType(DesktopApp)).openPopover();
      for (var ms = 0; ms < 900; ms += 16) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      t.desktop.world.world.say('Ready when you are!', speaker: w.SpeechSpeaker.companion);
      t.desktop.world.tick();
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester, 'popover-${theme.name}', SurfaceSizes.popover);

      final state = tester.state<DesktopAppState>(find.byType(DesktopApp));
      state.open(MainPage.home);
      tester.view.physicalSize = SurfaceSizes.main;
      await tester.pump(const Duration(milliseconds: 300));
      claude(hook('UserPromptSubmit', at: now));
      await tester.pump(const Duration(seconds: 20));
      t.desktop.world.tick();
      claude(hook('Stop', at: now));
      await tester.pump(const Duration(milliseconds: 1500));
      t.desktop.world.tick();
      await tester.pump(const Duration(milliseconds: 100));
      await save(tester, 'window-high-five-${theme.name}', SurfaceSizes.main);
      await tester.pump(const Duration(seconds: 8));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the desktop pet talking, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      await app(tester, size: SurfaceSizes.pet, surface: Surface.pet);
      t.desktop.world.world.say('Rise and shine!');
      t.desktop.world.tick();
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester, 'desktop-pet-talking-${theme.name}', SurfaceSizes.pet);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the taskbar strip: Mochi and Patch from the world, mid high five, with the confetti (2×)', (tester) async {
    const ratio = 2.0;
    final companion = CompanionDirector(t.desktop.world);
    addTearDown(companion.dispose);
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
    Widget strip(StrollSample sample) => MediaQuery(
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
            deskAccessory: Accessory.plant,
          ),
        ),
      ),
    );
    final sample = StrollSample(x: home.petHome - 30, facing: 1, animation: PetAnimation.sit, animationTime: 2, activity: StrollActivity.company);
    await tester.pumpWidget(strip(sample));
    await tester.pump(const Duration(seconds: 6));
    t.desktop.world.tick();
    await tester.pump(const Duration(milliseconds: 100));
    await save(tester, 'taskbar-calm', size * ratio);
    claude(hook('SessionStart', at: now));
    await tester.pump(const Duration(seconds: 6));
    t.desktop.world.tick();
    claude(hook('UserPromptSubmit', at: now));
    await tester.pump(const Duration(seconds: 20));
    t.desktop.world.tick();
    claude(hook('Stop', at: now));
    for (final (ms, name) in [(900, 'taskbar-high-five-a'), (1500, 'taskbar-high-five-b')]) {
      await tester.pump(Duration(milliseconds: ms));
      t.desktop.world.tick();
      await tester.pump(const Duration(milliseconds: 40));
      await save(tester, name, size * ratio);
    }
    await tester.pump(const Duration(seconds: 8));
    await tester.pumpWidget(const SizedBox());
  });
}

