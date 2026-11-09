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
// network, lib/src/demo.dart), MOCHI_DESKTOP_OPEN=main|pairing|settings|tray (what shows at launch),
// MOCHI_DESKTOP_PANE=general|characters|…|about (the Settings pane it opens at; in the demo, Settings opens paired
// unless MOCHI_DESKTOP_DEMO_PAIR=0), MOCHI_DESKTOP_INSTALL_ROOT (install somewhere else: tests), MOCHI_DESKTOP_INSTALL=never
// (never offer to install), MOCHI_UPDATE_CHANNEL=windows-test (the relay's test feed). A file named
// `stroll-debug` in Mochi's folder makes the taskbar stroll write what it sees (the taskbar, its free stretches, UI
// Automation's timings, click-through) to `stroll.log` there.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mochi_art/mochi_art.dart';
import 'package:mochi_ui/mochi_ui.dart';

import 'src/demo.dart';
import 'src/desktop.dart';
import 'src/ui/app.dart';
import 'src/ui/shell.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  final desktop = MochiDesktop.system();
  // A verified update is waiting from last time: the helper installs it and starts the new Mochi (before any window).
  if (await desktop.updater.applyPendingAtLaunch()) exit(0);
  // Mochi's in-scene lettering (the sleepy z, ? and !) in the app's rounded face.
  MochiArtText.family = mochiFontFamily;
  registerMochiFontLicense();
  final shell = NativeShell();
  await shell.init();
  final environment = Platform.environment;
  // Just installed ("Install Mochi" started this copy): Settings › About says where it lives and how it updates.
  final installed = arguments.contains('--installed');
  // Started from Downloads (or anywhere but its install folder): the main window, with the offer to install.
  final offerInstall =
      !kDebugMode && environment['MOCHI_DESKTOP_INSTALL'] != 'never' && desktop.installer.supported && !desktop.installer.installed && !desktop.settings.installDeclined;
  final open = environment['MOCHI_DESKTOP_OPEN'] ?? (installed ? 'settings' : (offerInstall ? 'main' : null));
  final pane =
      SettingsTab.values.where((tab) => tab.name == environment['MOCHI_DESKTOP_PANE']).firstOrNull ?? (installed ? SettingsTab.about : null);
  // Started from the Start menu's jump list (`--ask`, `--explore`): it runs once Mochi has started. Other arguments are
  // ignored.
  final launched = LaunchRequest.fromArguments(arguments);
  unawaited(
    desktop.start().then((_) async {
      if (launched != null) shell.launch(launched);
      // The demo's pairing screen shows a (made-up) code straight away; its Settings opens paired.
      if (demoMode && open == 'pairing') unawaited(desktop.link.showCode());
      if (demoMode && open == 'settings' && Platform.environment['MOCHI_DESKTOP_DEMO_PAIR'] != '0') {
        await desktop.link.showCode();
        desktop.link.hideCode();
      }
    }),
  );
  final page = switch (open) {
    'pairing' => MainPage.pairing,
    'settings' => MainPage.settings,
    _ => MainPage.home,
  };
  final surface = page != MainPage.home || open == 'main' ? Surface.main : Surface.pet;
  runApp(DesktopApp(desktop: desktop, shell: shell, initialSurface: surface, initialPage: page, initialPane: pane));
  if (open == 'tray') unawaited(Future<void>.delayed(const Duration(seconds: 2), shell.popUpMenu));
}
