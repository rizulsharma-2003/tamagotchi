// Mochi for Windows (docs/MOCHI_LINK_PLAN.md 5.4, phase 10): the desktop `host` app. A tray icon and a desktop pet
// that follows your Claude Code sessions through Claude Code hooks, a Mochi Link room your phones pair with, and Ask
// Mochi through `claude -p`.
//
// Developed as a macOS build of the same app (the Windows parts sit behind interfaces):
//
//   cd flutter/apps/mochi_desktop
//   flutter build macos --debug && tool/build_hook.sh     # the hook helper goes inside Mochi.app
//   open build/macos/Build/Products/Debug/Mochi.app
//
// On Windows: `flutter build windows` (it compiles the hook helper too, see windows/CMakeLists.txt).
//
// Development switches (environment): MOCHI_DESKTOP_HOME (the app's folder), CLAUDE_CONFIG_DIR (where Claude Code's
// settings.json is), MOCHI_DESKTOP_VAULT=memory (keep no credentials), MOCHI_DESKTOP_DEMO=1 (Mochi Link without the
// network, lib/src/demo.dart), MOCHI_DESKTOP_OPEN=main|pairing|settings|tray (what shows at launch).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart';

import 'src/demo.dart';
import 'src/desktop.dart';
import 'src/ui/app.dart';
import 'src/ui/shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Mochi's in-scene lettering (the sleepy z, ? and !) in the app's rounded face.
  MochiArtText.family = mochiFontFamily;
  final shell = NativeShell();
  await shell.init();
  final desktop = MochiDesktop.system();
  final open = Platform.environment['MOCHI_DESKTOP_OPEN'];
  unawaited(
    desktop.start().then((_) {
      // The demo's pairing screen shows a (made-up) code straight away.
      if (demoMode && open == 'pairing') unawaited(desktop.link.showCode());
    }),
  );
  final page = switch (open) {
    'pairing' => MainPage.pairing,
    'settings' => MainPage.settings,
    _ => MainPage.home,
  };
  final surface = page != MainPage.home || open == 'main' ? Surface.main : Surface.pet;
  runApp(DesktopApp(desktop: desktop, shell: shell, initialSurface: surface, initialPage: page));
  if (open == 'tray') unawaited(Future<void>.delayed(const Duration(seconds: 2), shell.popUpTrayMenu));
}
