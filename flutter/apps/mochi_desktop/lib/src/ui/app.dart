import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_wire/mochi_wire.dart' show HookStatus;

import '../core/pet_cues.dart';
import '../desktop.dart';
import '../platform/taskbar.dart';
import 'pet/companion_director.dart';
import 'pet/pet_surface.dart';
import 'pet/taskbar_stroll.dart';
import 'popover/popover_view.dart';
import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/settings_screen.dart';
import 'shell.dart';
import 'widgets/title_bar.dart';

export 'screens/settings_screen.dart' show SettingsNavigation, SettingsTab;

enum MainPage { home, pairing, settings }

/// Mochi for Windows: the desktop pet and the main window (one native window in two forms, see shell.dart), in Mochi's
/// clay look, light, dark or following the system.
class DesktopApp extends StatefulWidget {
  const DesktopApp({
    super.key,
    required this.desktop,
    required this.shell,
    this.library,
    this.initialSurface = Surface.pet,
    this.initialPage = MainPage.home,
    this.initialPane,
    this.taskbar,
    this.strollClock,
    this.strollRandom,
  });

  final MochiDesktop desktop;
  final DesktopShell shell;

  /// Where the taskbar is (Win32 on Windows, none elsewhere, a fake in tests).
  final TaskbarInfo? taskbar;

  /// The stroll's clock (seconds) and dice, for tests.
  final double Function()? strollClock;
  final math.Random? strollRandom;

  /// The recorded animations; loaded from the assets when not given.
  final Future<PoseLibrary?>? library;
  final Surface initialSurface;
  final MainPage initialPage;

  /// The Settings pane to open at (General otherwise).
  final SettingsTab? initialPane;

  static const String poseAsset = 'assets/pose_tracks.json.deflate';

  @override
  State<DesktopApp> createState() => DesktopAppState();
}

class DesktopAppState extends State<DesktopApp> {
  late Surface _surface = widget.initialSurface;
  late MainPage _page = widget.initialPage;
  PoseLibrary? _library;
  late DateTime _lastActivity = widget.desktop.sessions.now;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// One clock (seconds) for the stroll and Patch, so a moment together starts when Mochi gets to him.
  late final double Function() _clock = widget.strollClock ?? _monotonic();

  static double Function() _monotonic() {
    final watch = Stopwatch()..start();
    return () => watch.elapsedMicroseconds / 1e6;
  }

  /// Patch, Mochi's coding companion: on the taskbar beside Mochi and in the room in Mochi's window.
  late final CompanionDirector _companion = CompanionDirector(
    sessions: desktop.sessions,
    settings: desktop.settings,
    cues: desktop.cues,
    lastActivity: () => _lastActivity,
    clock: _clock,
    random: widget.strollRandom,
    reducedMotion: () => desktop.motion.reduced,
  );
  late final TaskbarStroll _stroll = TaskbarStroll(
    shell: widget.shell,
    taskbar: widget.taskbar ?? systemTaskbar(),
    settings: desktop.settings,
    motion: desktop.motion,
    cues: desktop.cues,
    companion: _companion,
    idle: () => desktop.sessions.now.difference(_lastActivity),
    clock: _clock,
    random: widget.strollRandom,
    log: _strollLog(),
  );
  late bool _trayRoaming = desktop.settings.roamTaskbar;

  MochiDesktop get desktop => widget.desktop;
  Surface get surface => _surface;
  MainPage get page => _page;

  /// Mochi's stroll along the taskbar (and every change to the window).
  TaskbarStroll get stroll => _stroll;

  /// Patch.
  CompanionDirector get companion => _companion;

  /// Development: with a `stroll-debug` file in Mochi's folder, the stroll writes what it sees to `stroll.log` there.
  void Function(String)? _strollLog() {
    final folder = desktop.paths.home;
    if (!File('$folder${Platform.pathSeparator}stroll-debug').existsSync()) return null;
    final file = File('$folder${Platform.pathSeparator}stroll.log');
    return (message) {
      try {
        file.writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append);
      } on Object {
        // Diagnostics only.
      }
    };
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadLibrary());
    _subscriptions.add(widget.shell.actions.listen(handle));
    _subscriptions.add(desktop.cues.listen(_noteActivity));
    desktop.sessions.addListener(_sessionsChanged);
    desktop.settings.addListener(_settingsChanged);
    unawaited(widget.shell.setRoaming(_trayRoaming));
    if (_page == MainPage.settings) widget.shell.mainSize = settingsSize();
    unawaited(_stroll.show(_surface));
  }

  Future<void> _loadLibrary() async {
    try {
      final library = await (widget.library ?? PoseLibrary.load(rootBundle, DesktopApp.poseAsset));
      _companion.library = library;
      if (mounted) setState(() => _library = library);
    } on Object catch (error) {
      debugPrint('Mochi: the animations could not be loaded (${error.runtimeType})');
    }
  }

  void _noteActivity(PetCue _) => _lastActivity = desktop.sessions.now;

  void _sessionsChanged() {
    final last = desktop.sessions.lastEventAt;
    if (last != null && last.isAfter(_lastActivity)) _lastActivity = last;
  }

  /// "Mochi on the desktop" switched while the main window is closed; "Roam along the taskbar" ticks in the tray.
  void _settingsChanged() {
    if (desktop.settings.roamTaskbar != _trayRoaming) {
      _trayRoaming = desktop.settings.roamTaskbar;
      unawaited(widget.shell.setRoaming(_trayRoaming));
    }
    // The popover's own switches take effect when it closes.
    if (_surface == Surface.main || _surface == Surface.popover) return;
    final wanted = desktop.settings.showPet ? Surface.pet : Surface.hidden;
    if (wanted != _surface) _show(wanted);
  }

  /// The tray menu, the pet's menu and the window's close button.
  void handle(ShellAction action) {
    switch (action) {
      case ShellAction.showMain:
        open(MainPage.home);
      case ShellAction.pair:
        open(MainPage.pairing);
      case ShellAction.settings:
        open(MainPage.settings);
      case ShellAction.toggleRoaming:
        desktop.settings.roamTaskbar = !desktop.settings.roamTaskbar;
      case ShellAction.backToTaskbar:
        desktop.settings
          ..roamTaskbar = true
          ..showPet = true;
      case ShellAction.closeWindow:
        if (_surface == Surface.main) {
          closeMain();
        } else if (_surface == Surface.popover) {
          closePopover();
        } else {
          _show(Surface.hidden);
        }
      case ShellAction.dismissPopover:
        if (_surface == Surface.popover) closePopover();
      case ShellAction.quit:
        unawaited(_quit());
    }
  }

  /// Which Settings pane is open (kept while Settings is closed, so it opens where you left it).
  late final SettingsNavigation settingsNavigation = SettingsNavigation(widget.initialPane ?? SettingsTab.general);

  /// Settings was opened from Mochi's window (Escape goes back to it), not from the tray or the pet.
  bool _settingsFromWindow = false;

  /// Shows [page] in the main window; Settings at its own, larger size, at [pane] if given.
  void open(MainPage page, {SettingsTab? pane}) {
    if (pane != null) settingsNavigation.tab = pane;
    if (page == MainPage.settings && (_page != MainPage.settings || _surface != Surface.main)) {
      _settingsFromWindow = _surface == Surface.main;
    }
    widget.shell.mainSize = page == MainPage.settings ? settingsSize() : SurfaceSizes.main;
    setState(() => _page = page);
    _show(Surface.main);
  }

  /// Escape in Settings: back to Mochi's window if Settings was opened from it, else back to the desktop.
  void closeSettings() => _settingsFromWindow ? open(MainPage.home) : closeMain();

  /// Settings › Phones › Pair a Phone…: the pairing page, with a fresh code.
  void pairPhone() {
    open(MainPage.pairing);
    if (desktop.link.code == null && !desktop.link.working) unawaited(desktop.link.showCode());
  }

  /// The Settings window's size: the Mac's, or as much of a small screen as fits (Windows' work area).
  Size settingsSize() {
    const wanted = SurfaceSizes.settings;
    if (!Platform.isWindows || !_stroll.taskbar.available) return wanted;
    final reading = _stroll.taskbar.read();
    if (reading == null) return wanted;
    final width = reading.workArea.width / reading.scale - 32;
    final height = reading.workArea.height / reading.scale - 32;
    return Size(
      math.max(SurfaceSizes.mainMinimum.width, math.min(wanted.width, width)),
      math.max(SurfaceSizes.mainMinimum.height, math.min(wanted.height, height)),
    );
  }

  /// Back to the desktop pet (or nothing, with the pet turned off). Mochi keeps running in the tray.
  void closeMain() => _show(desktop.settings.showPet ? Surface.pet : Surface.hidden);

  /// The popover (the Mac's menu-bar popover): clicking Mochi on the taskbar opens it above where Mochi is; clicking
  /// again (anywhere outside it, Mochi's spot included) or Escape closes it, and Mochi is back where it was.
  void openPopover() {
    if (_surface == Surface.pet) _show(Surface.popover);
  }

  /// Back to the taskbar (or nothing, if the desktop pet was switched off in the popover).
  void closePopover() {
    if (_surface == Surface.popover) _show(desktop.settings.showPet ? Surface.pet : Surface.hidden);
  }

  /// "Ask Mochi" in the popover: Mochi's window with the question box ready.
  void openAsk() {
    _askFirst = true;
    open(MainPage.home);
  }

  bool _askFirst = false;

  void _show(Surface surface) {
    setState(() => _surface = surface);
    unawaited(_stroll.show(surface));
  }

  /// Whether Mochi's window should open on the question box (once).
  bool _takeAskFirst() {
    final ask = _askFirst;
    _askFirst = false;
    return ask;
  }

  /// Moves the pet with the mouse until it's dropped (window_manager's drag returns then): off the taskbar, Mochi
  /// stays where it's dropped.
  Future<void> _drag() async {
    _stroll.dragStarted();
    try {
      await widget.shell.startDragging();
    } finally {
      _stroll.dragEnded(await widget.shell.position());
    }
  }

  Future<void> _quit() async {
    await desktop.dispose();
    await widget.shell.quit();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    desktop.sessions.removeListener(_sessionsChanged);
    desktop.settings.removeListener(_settingsChanged);
    _stroll.dispose();
    _companion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.settings, desktop.motion, _stroll, _companion]),
    builder: (context, _) => MaterialApp(
      title: 'Mochi',
      debugShowCheckedModeBanner: false,
      color: Colors.transparent,
      themeMode: desktop.settings.themeMode,
      theme: mochiTheme(Brightness.light, formFactor: MochiFormFactor.desktop),
      darkTheme: mochiTheme(Brightness.dark, formFactor: MochiFormFactor.desktop),
      // The system's "animation effects off" calms every animation in the app, Mochi's included.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: MediaQuery.disableAnimationsOf(context) || desktop.motion.reduced),
        child: child!,
      ),
      home: switch (_surface) {
        Surface.pet => PetSurface(
          desktop: desktop,
          stroll: _stroll,
          library: _library,
          lastActivity: () => _lastActivity,
          onAction: handle,
          onDragStart: () => unawaited(_drag()),
          onHide: () => desktop.settings.showPet = false,
          onNativeMenu: () => unawaited(widget.shell.popUpMenu()),
          onOpenPopover: openPopover,
          companion: _companion,
        ),
        Surface.popover => PopoverView(
          desktop: desktop,
          companion: _companion,
          library: _library,
          lastActivity: () => _lastActivity,
          onClose: closePopover,
          onOpenMain: () => open(MainPage.home),
          onAsk: openAsk,
          onSettings: () => open(MainPage.settings),
          onSetUpClaude: () => open(MainPage.settings, pane: SettingsTab.claude),
        ),
        Surface.main => _MainSurface(state: this),
        Surface.hidden => const SizedBox.shrink(),
      },
    ),
  );
}

/// The main window's frame: rounded backdrop, title bar, the page. Settings has its own backdrop (its pane's colours)
/// and the Claude Code status in the title bar.
class _MainSurface extends StatelessWidget {
  const _MainSurface({required this.state});

  final DesktopAppState state;

  @override
  Widget build(BuildContext context) {
    final page = state.page;
    final desktop = state.desktop;
    final settingsPage = page == MainPage.settings;
    void back() => state.open(MainPage.home);
    final title = switch (page) {
      MainPage.home => 'Mochi',
      MainPage.pairing => 'Pair a Phone',
      MainPage.settings => 'Settings',
    };
    final column = Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          MochiTitleBar(
            title: title,
            onDragStart: () => unawaited(state.widget.shell.startDragging()),
            onClose: state.closeMain,
            onBack: page == MainPage.home ? null : back,
            onPair: page == MainPage.pairing || settingsPage ? null : () => state.open(MainPage.pairing),
            onSettings: settingsPage ? null : () => state.open(MainPage.settings),
            trailing: settingsPage ? _ClaudeStatusPill(desktop: desktop, onTap: () => state.settingsNavigation.tab = SettingsTab.claude) : null,
          ),
          Expanded(
            child: switch (page) {
              MainPage.home => HomeScreen(
                desktop: desktop,
                companion: state._companion,
                askFirst: state._takeAskFirst(),
                library: state._library,
                lastActivity: () => state._lastActivity,
                onPair: () => state.open(MainPage.pairing),
                onSettings: () => state.open(MainPage.settings, pane: SettingsTab.claude),
              ),
              MainPage.pairing => PairingScreen(
                link: desktop.link,
                onTestNotification: desktop.phone.sendTestNotification,
                clock: () => desktop.sessions.now,
              ),
              MainPage.settings => SettingsScreen(
                host: SettingsHost(
                  desktop: desktop,
                  navigation: state.settingsNavigation,
                  onPair: state.pairPhone,
                  onHome: back,
                  stroll: state.stroll,
                  patch: state.companion,
                  library: state._library,
                ),
              ),
            },
          ),
        ],
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): switch (page) {
          MainPage.home => state.closeMain,
          MainPage.settings => state.closeSettings,
          MainPage.pairing => back,
        },
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => state.open(MainPage.settings),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => state.open(MainPage.settings),
      },
      child: FocusScope(
        autofocus: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: settingsPage
              ? ListenableBuilder(
                  listenable: state.settingsNavigation,
                  builder: (context, child) => SettingsBackdrop(tab: state.settingsNavigation.tab, child: child!),
                  child: column,
                )
              : MochiBackground(child: column),
        ),
      ),
    );
  }
}

/// Settings' title bar: is Claude Code connected? Click for the Claude Code pane (the Mac's toolbar pill).
class _ClaudeStatusPill extends StatelessWidget {
  const _ClaudeStatusPill({required this.desktop, required this.onTap});

  final MochiDesktop desktop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: desktop.hooks,
    builder: (context, _) {
      final p = context.palette;
      final (text, tint) = switch (desktop.hooks.inspection?.status) {
        HookStatus.installed => ('Connected to Claude Code', p.success),
        HookStatus.needsUpdate => ('Claude Code needs an update', p.warning),
        HookStatus.unreadable => ('Claude Code needs attention', p.danger),
        _ => ('Claude Code not connected', p.warning),
      };
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.xs),
        child: Semantics(
          button: true,
          label: '$text. Open Claude Code settings',
          excludeSemantics: true,
          child: ClayPress(
            onTap: onTap,
            borderRadius: BorderRadius.circular(40),
            child: StatusPill(text: text, icon: Icons.circle, tint: tint),
          ),
        ),
      );
    },
  );
}
