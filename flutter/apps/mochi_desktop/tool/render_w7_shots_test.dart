// Pictures of Sprint 2's W7 and W5 screens, drawn by the app itself with its real fonts (not screen captures): Settings ›
// Desktop Pet in each style, Settings › Agent with Copy Cloud Settings, and the classic tray icon's frames on a dark
// and a light taskbar. For reviewing on a machine without the Windows VM.
//
//   MOCHI_SHOTS=/some/folder flutter test tool/render_w7_shots_test.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_desktop/src/core/desktop_settings.dart';
import 'package:mochi_desktop/src/core/notifications.dart' show AttentionLevel;
import 'package:mochi_desktop/src/ui/app.dart';
import 'package:mochi_desktop/src/ui/shell.dart';
import 'package:mochi_desktop/src/ui/tray_glyph.dart';

import '../test/support/fakes.dart';

void main() {
  final out = Directory(Platform.environment['MOCHI_SHOTS'] ?? 'build/shots')..createSync(recursive: true);
  late TestDesktop t;

  // Made outside the tests' fake clock (its timers are the desktop's own), and put away after each.
  setUp(() => t = TestDesktop.make(saved: hostCredentials));
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

  Map<String, Object?> peer(String id, String role, String platform, String name, {bool online = true}) => {
    'id': id,
    'role': role,
    'platform': platform,
    'name': name,
    'online': online,
  };

  for (final (style, theme, scale) in [
    (DesktopStyle.roam, ThemeMode.light, 1.0),
    (DesktopStyle.spot, ThemeMode.dark, 1.0),
    (DesktopStyle.icon, ThemeMode.light, 1.0),
    (DesktopStyle.roam, ThemeMode.dark, 2.0),
  ]) {
    testWidgets('Settings › Desktop Pet, ${style.name}, ${theme.name}, ${scale}x', (tester) async {
      t.desktop.settings
        ..themeMode = theme
        ..petStyle = style;
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.desktop,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await save(tester, 'desktop-pet-${style.name}-${theme.name}${scale == 1 ? '' : '-2x'}', SurfaceSizes.settings);
      if (scale == 1) {
        await tester.drag(find.byType(SingleChildScrollView).last, const Offset(0, -500));
        await tester.pump(const Duration(milliseconds: 300));
        await save(tester, 'desktop-pet-${style.name}-${theme.name}-lower', SurfaceSizes.settings);
      }
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final theme in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('Settings › Agent, ${theme.name}', (tester) async {
      t.desktop.settings.themeMode = theme;
      await tester.runAsync(() async {
        await t.desktop.link.start();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        t.socket.sync(
          devices: [
            peer('dev_pc', 'host', 'windows', 'TEST-PC'),
            peer('dev_droid', 'pocket', 'android', 'realme RMX3242'),
            peer('dev_cloud', 'cloud', 'cloud', 'Mochi Cloud', online: false),
          ],
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
      tester.view.physicalSize = SurfaceSizes.settings;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        DesktopApp(
          desktop: t.desktop,
          shell: FakeShell(),
          initialSurface: Surface.main,
          initialPage: MainPage.settings,
          initialPane: SettingsTab.agent,
          library: Future<PoseLibrary?>.value(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await save(tester, 'agent-${theme.name}', SurfaceSizes.settings);
      final button = find.ancestor(of: find.text('Copy Cloud Settings'), matching: find.byWidgetPredicate((widget) => widget is FilledButton));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump(const Duration(milliseconds: 300));
      await save(tester, 'agent-${theme.name}-confirm', SurfaceSizes.settings);
      await tester.tap(find.text('Replace'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await save(tester, 'agent-${theme.name}-copied', SurfaceSizes.settings);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('the classic tray icon’s frames', (tester) async {
    final frames = [
      for (final light in [false, true]) ...[
        GlyphFrame(mood: GlyphMood.content, light: light),
        GlyphFrame(mood: GlyphMood.content, blink: true, light: light),
        GlyphFrame(mood: GlyphMood.watching, bulb: true, light: light),
        GlyphFrame(mood: GlyphMood.watching, bulb: false, light: light),
        GlyphFrame(mood: GlyphMood.waiting, badge: AttentionLevel.attention, light: light),
        GlyphFrame(mood: GlyphMood.celebrating, bounce: 2.4, sparkle: 1, light: light),
        GlyphFrame(mood: GlyphMood.concerned, badge: AttentionLevel.alert, light: light),
        GlyphFrame(mood: GlyphMood.sleeping, light: light),
        GlyphFrame(mood: GlyphMood.paused, light: light),
        GlyphFrame(mood: GlyphMood.offline, light: light),
      ],
    ];
    await tester.runAsync(() async {
      const cell = 96.0, icon = 48.0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (final (index, frame) in frames.indexed) {
        final x = (index % 10) * cell, y = (index ~/ 10) * cell;
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), Paint()..color = frame.light ? const Color(0xFFEEEEEE) : const Color(0xFF1F1F1F));
        canvas.save();
        canvas.translate(x + (cell - icon) / 2, y + (cell - icon) / 2);
        TrayGlyph.draw(canvas, icon, frame);
        canvas.restore();
      }
      final image = await recorder.endRecording().toImage((cell * 10).toInt(), (cell * 2).toInt());
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${out.path}/tray-icon-frames.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });
}
