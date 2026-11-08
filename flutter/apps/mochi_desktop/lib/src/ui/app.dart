import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';
import 'package:mochi_wire/mochi_wire.dart' show HookStatus;

import '../core/desktop_settings.dart' show DesktopStyle;
import '../core/hotkeys.dart';
import '../core/pet_cues.dart';
import '../core/toasts.dart';
import '../desktop.dart';
import '../platform/displays.dart';
import '../platform/process_cpu.dart';
import '../platform/taskbar.dart';
import '../platform/image_export.dart';
import '../platform/win32_taskbar.dart' show Win32PetWindow, Win32TaskbarInfo;
import 'perf_meter.dart';
import 'pet/companion_director.dart';
import 'pet/pet_director.dart' show PetMood;
import '../update/updater.dart';
import 'pet/pet_surface.dart';
import 'pet/taskbar_stroll.dart';
import 'games/games_screen.dart';
import 'recap/recap_screen.dart';
import '../core/games.dart' show GameTab;
import 'popover/frame_meter.dart';
import 'popover/popover_stage.dart';
import 'popover/popover_view.dart';
import 'screens/home_screen.dart';
import 'widgets/resize_edges.dart';
import 'screens/pairing_screen.dart';
import 'screens/settings_screen.dart';
import 'shell.dart';
import 'tray_glyph.dart';
import 'widgets/title_bar.dart';

export 'screens/settings_screen.dart' show SettingsNavigation, SettingsTab;

/// The main window's pages: Mochi's own (home, pairing), Settings, and the fun features' windows on the Mac (Games).
enum MainPage {
  home('Mochi'),
  pairing('Pair a Phone'),
  settings('Settings'),
  games('Games'),
  recap('Today’s Recap');

  const MainPage(this.title);
  final String title;
}

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
    this.displays,
    this.strollClock,
    this.strollRandom,
    this.images,
  });

  final MochiDesktop desktop;
  final DesktopShell shell;

  /// Where saved and copied pictures go (the recap card); the system's when not given.
  final ImageExport? images;

  /// Where the taskbar is (Win32 on Windows, none elsewhere, a fake in tests).
  final TaskbarInfo? taskbar;

  /// The displays, for the desktop pet's place on each (Win32 on Windows, none elsewhere, a fake in tests).
  final Displays? displays;

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

  /// One clock (seconds) for the stroll and Mochi's world, so a moment carries on from where the stroll had Mochi.
  late final double Function() _clock = widget.strollClock ?? desktop.world.now;

  /// Patch, Mochi's coding companion: on the taskbar beside Mochi and in the room in Mochi's window.
  late final CompanionDirector _companion = CompanionDirector(desktop.world);
  late final TaskbarStroll _stroll = TaskbarStroll(
    shell: widget.shell,
    taskbar: widget.taskbar ?? systemTaskbar(),
    settings: desktop.settings,
    motion: desktop.motion,
    cues: desktop.cues,
    companion: _companion,
    rhythm: desktop.rhythm,
    displays: widget.displays ?? systemDisplays(),
    idle: () => desktop.sessions.now.difference(_lastActivity),
    clock: _clock,
    random: widget.strollRandom,
    log: _strollLog(),
  );
  late DesktopStyle _trayStyle = desktop.settings.petStyle;

  /// The clipboard and Downloads, for the recap's picture (Mochi's window owns what it puts on the clipboard).
  late final ImageExport _images =
      widget.images ??
      ImageExport.system(
        owner: () => switch (widget.shell.petWindow) {
          final Win32PetWindow window => window.hwnd,
          _ => 0,
        },
      );

  /// The classic tray icon (while Mochi lives there).
  late final TrayGlyphController _tray = TrayGlyphController(
    shell: widget.shell,
    settings: desktop.settings,
    folder: desktop.paths.join(desktop.paths.home, 'tray'),
    mood: () => PetMood.of(
      desktop.sessions,
      now: desktop.sessions.now,
      lastActivity: _lastActivity,
      rhythm: desktop.rhythm,
      asleep: desktop.world.asleep,
    ),
    cues: desktop.cues,
    motion: desktop.motion,
    rhythm: desktop.rhythm,
    badge: () => desktop.reactions.badge?.level,
    offline: () => desktop.bridgeProblem.value != null,
    sessionOpen: () => desktop.sessions.live.isNotEmpty,
    lightTaskbar: Platform.isWindows ? Win32TaskbarInfo.lightTheme : null,
  );

  /// The classic tray icon's controller (tests).
  TrayGlyphController get tray => _tray;

  /// Development: the popover's frame times, with the stroll's debug log on.
  late final FrameMeter? _meter = switch (_stroll.log) {
    final log? => FrameMeter(log),
    null => null,
  };

  /// Development: with a `perf-debug` file in Mochi's folder, what each state costs goes to `perf.log` there.
  PerfMeter? _perf;

  /// What Mochi is doing, for the perf meter.
  String perfState() {
    final state = _perfState();
    return desktop.rhythm.unseen ? 'screen off: $state' : state;
  }

  String _perfState() {
    switch (_surface) {
      case Surface.hidden:
        return 'hidden';
      case Surface.main:
        return 'main window';
      case Surface.popover:
        return _popoverClosing ? 'popover closing' : 'popover';
      case Surface.pet:
        final mood = _stroll.mood == PetMood.napping ? 'napping' : 'calm';
        final patch = _stroll.home != null ? ' with Patch' : '';
        return switch (_stroll.placement) {
          PetPlacement.taskbar => '${_stroll.moving ? 'roaming' : mood}$patch',
          PetPlacement.standing => 'standing, $mood',
          PetPlacement.hidden => 'out of the way (full screen)',
          PetPlacement.away => 'placing',
        };
    }
  }

  void _startPerf() {
    final folder = desktop.paths.home;
    if (!File('$folder${Platform.pathSeparator}perf-debug').existsSync()) return;
    final file = File('$folder${Platform.pathSeparator}perf.log');
    _perf = PerfMeter(
      state: perfState,
      cpu: processCpuMicroseconds,
      log: (line) {
        try {
          file.writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
        } on Object {
          // Diagnostics only.
        }
      },
    );
  }

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
    if (Platform.isWindows) _warmUpTimer = Timer.periodic(const Duration(seconds: 5), (_) => _warmUp());
    // Development: with the stroll's debug log on, Flutter's errors go there too (a release build has no console).
    final log = _stroll.log;
    if (log != null) {
      // The PC's rhythm, the badge and Windows notifications too, every 15 seconds (development only).
      _rhythmLog = Timer.periodic(const Duration(seconds: 15), (_) {
        final reactions = desktop.reactions;
        log('rhythm: ${desktop.rhythm.activity} resting=${desktop.rhythm.resting} away=${desktop.rhythm.away} '
            'napping=${desktop.rhythm.nap.asleep} · toasts ${desktop.toasts.availability.name}, ${reactions.bannersPosted} shown · '
            'sounds ${desktop.sounds.played} · badge ${reactions.badge?.kind.name}');
      });
      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        log('error: ${details.exceptionAsString()} ${details.stack.toString().split('\n').take(6).join(' | ')}');
        previous?.call(details);
      };
    }
    unawaited(_loadLibrary());
    _startPerf();
    _subscriptions.add(widget.shell.actions.listen(handle));
    _subscriptions.add(desktop.cues.listen(_noteActivity));
    _subscriptions.add(desktop.opens.listen(openFromNotification));
    _subscriptions.add(desktop.shortcuts.listen(shortcut));
    // With Mochi's window or popover open you're looking already: no badge or Windows notification (the Mac's popover).
    desktop.reactions.lookingAtMochi = () => _surface == Surface.main || _surface == Surface.popover;
    desktop.sessions.addListener(_sessionsChanged);
    desktop.sessions.addListener(_tray.refresh);
    desktop.reactions.addListener(_tray.refresh);
    desktop.settings.addListener(_settingsChanged);
    desktop.updater.addListener(_updatesChanged);
    desktop.focus.addListener(_focusChanged);
    unawaited(widget.shell.setStyle(_trayStyle));
    _updatesChanged();
    if (_page == MainPage.settings) widget.shell.mainSize = settingsSize();
    unawaited(_stroll.show(_surface));
  }

  Future<void> _loadLibrary() async {
    try {
      final library = await (widget.library ?? PoseLibrary.load(rootBundle, DesktopApp.poseAsset));
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

  bool _trayUpdate = false;
  bool _trayFocus = false;

  /// "Start Focus" or "Stop Focus" in the tray as a session starts or ends.
  void _focusChanged() {
    final running = desktop.focus.running;
    if (running == _trayFocus) return;
    _trayFocus = running;
    unawaited(widget.shell.setFocusing(running));
  }

  /// "Restart to Update" in the tray while a verified update waits.
  void _updatesChanged() {
    final ready = desktop.updater.phase == UpdatePhase.ready;
    if (ready == _trayUpdate) return;
    _trayUpdate = ready;
    unawaited(widget.shell.setUpdateReady(ready));
  }

  /// "Install Mochi": copies this copy into the install folder, then the installed copy takes over (this one quits).
  Future<void> installMochi() async {
    final installer = desktop.installer;
    if (!await installer.install()) return;
    if (await installer.relaunchInstalled() != null) return;
    await _quit();
  }

  /// "Restart to Update": the helper installs the waiting update once Mochi has quit, then starts it again.
  Future<void> restartToUpdate() async {
    if (await desktop.updater.restartToUpdate() != null) {
      open(MainPage.settings, pane: SettingsTab.about);
      return;
    }
    await _quit();
  }

  /// "Mochi on the desktop" switched while the main window is closed; where Mochi lives ticks in the tray.
  void _settingsChanged() {
    if (desktop.settings.petStyle != _trayStyle) {
      _trayStyle = desktop.settings.petStyle;
      unawaited(widget.shell.setStyle(_trayStyle));
    }
    // The popover's own switches take effect when it closes.
    if (_surface == Surface.main || _surface == Surface.popover) return;
    final wanted = desktop.settings.showPet ? Surface.pet : Surface.hidden;
    if (wanted != _surface) _show(wanted);
  }

  /// The tray menu, the pet's menu and the window's close button.
  void handle(ShellAction action) {
    _stroll.log?.call('action: ${action.name} (showing ${_surface.name})');
    switch (action) {
      case ShellAction.showMain:
        open(MainPage.home);
      case ShellAction.pair:
        open(MainPage.pairing);
      case ShellAction.settings:
        open(MainPage.settings);
      case ShellAction.focus:
        desktop.focus.toggle();
      case ShellAction.games:
        openGames();
      case ShellAction.recap:
        openRecap();
      case ShellAction.decorate:
        openDecorate();
      // On the taskbar (roaming it, or playing in its spot) is where you'll see Mochi: the pet shows too.
      case ShellAction.roamTaskbar:
        desktop.settings
          ..petStyle = DesktopStyle.roam
          ..showPet = true;
      case ShellAction.playInSpot:
        desktop.settings
          ..petStyle = DesktopStyle.spot
          ..showPet = true;
      case ShellAction.trayIcon:
        desktop.settings.petStyle = DesktopStyle.icon;
      case ShellAction.closeWindow:
        if (_surface == Surface.main) {
          closeMain();
        } else if (_surface == Surface.popover) {
          closePopover();
        } else {
          _show(Surface.hidden);
        }
      case ShellAction.dismissPopover:
        // Windows can take the focus away for a moment while the window changes form: only a click elsewhere after
        // it opened closes it.
        final opened = _popoverOpenedAt;
        if (_surface == Surface.popover && (opened == null || _clock() - opened > popoverSettle)) closePopover();
      case ShellAction.restartToUpdate:
        unawaited(restartToUpdate());
      case ShellAction.windowResized:
        unawaited(_rememberSize());
      case ShellAction.quit:
        unawaited(_quit());
    }
  }

  /// Which Settings pane is open (kept while Settings is closed, so it opens where you left it).
  late final SettingsNavigation settingsNavigation = SettingsNavigation(widget.initialPane ?? SettingsTab.general);

  /// Settings (or a fun feature's page) was opened from Mochi's window (Escape goes back to it), not from the tray, the
  /// popover or the pet.
  bool _settingsFromWindow = false;

  /// Shows [page] in the main window; Settings and the games at their own sizes, Settings at [pane] if given.
  void open(MainPage page, {SettingsTab? pane}) {
    if (pane != null) settingsNavigation.tab = pane;
    if (page != MainPage.home && page != MainPage.pairing && (_page != page || _surface != Surface.main)) {
      _settingsFromWindow = _surface == Surface.main && _page == MainPage.home;
    }
    // Decorating happens in the room: leaving it for another page puts the tray away.
    if (page != MainPage.home) desktop.room.end();
    widget.shell.mainSize = switch (page) {
      MainPage.settings => settingsSize(),
      MainPage.games => _fit(SurfaceSizes.games),
      MainPage.recap => _fit(SurfaceSizes.recap),
      MainPage.home || MainPage.pairing => mainWindowSize(),
    };
    setState(() => _page = page);
    _show(Surface.main);
  }

  /// The Mac's "Games…": the Games window, at [tab] if given.
  void openGames([GameTab? tab]) {
    desktop.games.show(tab);
    open(MainPage.games);
  }

  /// The Mac's "Today's Recap…": the card for today.
  void openRecap() => open(MainPage.recap);

  /// The Mac's "Decorate the Room…" (W18): Mochi's window, with the room's tray out (the popover's Decorate decorates
  /// the popover's room instead, as on the Mac).
  void openDecorate() {
    open(MainPage.home);
    desktop.room.begin();
  }

  /// Escape in Settings (or a fun feature's page): back to Mochi's window if it was opened from there, else back to
  /// the desktop.
  void closeSettings() => _settingsFromWindow ? open(MainPage.home) : closeMain();

  /// Settings › Phones › Pair a Phone…: the pairing page, with a fresh code.
  void pairPhone() {
    open(MainPage.pairing);
    if (desktop.link.code == null && !desktop.link.working) unawaited(desktop.link.showCode());
  }

  /// Mochi's own window (home and pairing): the size you last gave it, or the default.
  Size mainWindowSize() => _fit(desktop.settings.mainWindowSize ?? SurfaceSizes.main);

  /// The Settings window's size: the size you last gave it, else the Mac's, or as much of a small screen as fits
  /// (Windows' work area).
  Size settingsSize() => _fit(desktop.settings.settingsWindowSize ?? SurfaceSizes.settings);

  /// [wanted], no smaller than the window's minimum and no bigger than the screen's work area.
  Size _fit(Size wanted) {
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

  /// You resized the window by its edge: Mochi remembers the size, for this page's kind of window.
  Future<void> _rememberSize() async {
    if (_surface != Surface.main) return;
    final size = await widget.shell.size();
    if (size == null || size.width < SurfaceSizes.mainMinimum.width - 1 || size.height < SurfaceSizes.mainMinimum.height - 1) return;
    widget.shell.mainSize = size;
    if (_page == MainPage.games || _page == MainPage.recap) return;
    if (_page == MainPage.settings) {
      if (desktop.settings.settingsWindowSize != size) desktop.settings.settingsWindowSize = size;
    } else if (desktop.settings.mainWindowSize != size) {
      desktop.settings.mainWindowSize = size;
    }
  }

  /// Back to the desktop pet (or nothing, with the pet turned off). Mochi keeps running in the tray.
  void closeMain() => _show(desktop.settings.showPet ? Surface.pet : Surface.hidden);

  /// The popover (the Mac's menu-bar popover): clicking Mochi on the taskbar opens it above where Mochi is; clicking
  /// again (anywhere outside it, Mochi's spot included) or Escape closes it, and Mochi is back where it was.
  void openPopover() {
    if (_surface != Surface.pet) return;
    _popoverOpenedAt = _clock();
    // Where it goes and what it comes out of, worked out before Mochi leaves the taskbar.
    _popover = _stroll.popover = _stroll.popoverGeometry(SurfaceSizes.popover);
    _popoverClosing = false;
    _show(Surface.popover);
  }

  /// The popover's geometry while it's up, and whether it's on its way out.
  PopoverGeometry? _popover;
  bool _popoverClosing = false;

  /// The popover's stage (for tests).
  bool get popoverClosing => _popoverClosing;
  PopoverGeometry? get popoverGeometry => _popover;

  /// When the popover opened (the stroll's clock), and how long a lost focus doesn't count as a click elsewhere.
  double? _popoverOpenedAt;
  static const double popoverSettle = 0.6;

  /// Back to the taskbar (or nothing, if the desktop pet was switched off in the popover): the popover genies back into
  /// Mochi's spot as Mochi leaps home (popover_stage.dart), and then the window is the pet's again.
  void closePopover() {
    if (_surface != Surface.popover || _popoverClosing) return;
    _stroll.popoverClosing();
    setState(() => _popoverClosing = true);
  }

  /// Mochi leaps back to its spot on the taskbar when the popover closes (if it's going back there).
  bool get _leapBack => _popover?.mochi != null && desktop.settings.showPet && desktop.settings.roamTaskbar;

  Future<void> _popoverClosed() async {
    if (_surface != Surface.popover) return;
    if (_leapBack) await _stroll.returnFromPopover();
    if (!mounted || _surface != Surface.popover) return;
    _show(desktop.settings.showPet ? Surface.pet : Surface.hidden);
  }

  /// "Ask Mochi" in the popover: Mochi's window with the question box ready.
  void openAsk() {
    _askFirst = true;
    open(MainPage.home);
  }

  bool _askFirst = false;
  Timer? _rhythmLog;

  /// The session a Windows notification was about: its card is outlined in Mochi's window.
  String? _focusSession;
  String? get focusSession => _focusSession;

  /// A Windows notification was clicked: the session's card in Mochi's window, Mochi's window, or the Agent's card.
  void openFromNotification(ToastTarget target) {
    switch (target.kind) {
      case ToastTargetKind.session:
        final id = target.sessionId;
        _focusSession = id != null && desktop.sessions.registry[id] != null ? id : null;
        open(MainPage.home);
      case ToastTargetKind.main:
        _focusSession = null;
        open(MainPage.home);
      case ToastTargetKind.agent:
        open(MainPage.settings, pane: SettingsTab.agent);
      case ToastTargetKind.recap:
        openRecap();
    }
  }

  /// One of Mochi's global shortcuts: show or hide the desktop pet (the Mac's ⌃⌥⌘P), or Ask Mochi (the Mac's ⌥Space:
  /// the question box, or closing it again).
  void shortcut(MochiShortcut shortcut) {
    switch (shortcut) {
      case MochiShortcut.pet:
        desktop.settings.showPet = !desktop.settings.showPet;
      case MochiShortcut.ask:
        if (_surface == Surface.main && _page == MainPage.home) {
          closeMain();
        } else {
          openAsk();
        }
    }
  }

  void _show(Surface surface) {
    if (surface != Surface.popover) {
      _popover = null;
      _popoverClosing = false;
    }
    if (surface == Surface.main || surface == Surface.popover) {
      desktop.reactions.acknowledge();
    } else {
      _focusSession = null;
    }
    if (surface != Surface.main && surface != Surface.popover) desktop.room.end();
    // You're looking at Mochi: no badges from the world, and Mochi can say good morning.
    desktop.world.setWindowVisible(surface == Surface.main || surface == Surface.popover);
    setState(() => _surface = surface);
    if (surface == Surface.pet && !_warm && Platform.isWindows) _warmUpTimer ??= Timer.periodic(const Duration(seconds: 5), (_) => _warmUp());
    final shown = _stroll.show(surface);
    if (surface == Surface.popover) _popoverReady = shown;
    unawaited(shown);
  }

  /// Completes once the window is in place for the popover.
  Future<void>? _popoverReady;

  Widget _popoverPanel(bool hidePet) => PopoverView(
    desktop: desktop,
    companion: _companion,
    lastActivity: () => _lastActivity,
    hidePet: hidePet,
    onClose: closePopover,
    onOpenMain: () => open(MainPage.home),
    onAsk: openAsk,
    onSettings: () => open(MainPage.settings),
    onSetUpClaude: () => open(MainPage.settings, pane: SettingsTab.claude),
    onGames: openGames,
    onRecap: openRecap,
  );

  /// The popover is drawn once out of sight soon after launch, on Windows (see [_PopoverWarmUp]).
  Timer? _warmUpTimer;
  bool _warmingUp = false;
  bool _warm = false;

  void _warmUp() {
    // Done, or there's no pet to warm up for (it starts again when the pet shows).
    if (_warm || _surface == Surface.hidden) {
      _warmUpTimer?.cancel();
      _warmUpTimer = null;
      return;
    }
    // While Mochi stands on the taskbar (its walk would stutter once).
    if (_surface == Surface.pet && !_warmingUp && _library != null && !_stroll.moving && mounted) setState(() => _warmingUp = true);
  }

  void _warmedUp() {
    _warmUpTimer?.cancel();
    if (mounted) {
      setState(() {
        _warmingUp = false;
        _warm = true;
      });
    }
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
    desktop.sessions.removeListener(_tray.refresh);
    desktop.reactions.removeListener(_tray.refresh);
    _tray.dispose();
    desktop.settings.removeListener(_settingsChanged);
    _warmUpTimer?.cancel();
    desktop.updater.removeListener(_updatesChanged);
    desktop.focus.removeListener(_focusChanged);
    _rhythmLog?.cancel();
    _stroll.dispose();
    _companion.dispose();
    _meter?.dispose();
    _perf?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.settings, desktop.motion, desktop.reactions, _stroll, _companion]),
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
        Surface.pet => Stack(
          children: [
            Positioned.fill(
              child: PetSurface(
                desktop: desktop,
                stroll: _stroll,
                lastActivity: () => _lastActivity,
                onAction: handle,
                onDragStart: () => unawaited(_drag()),
                onHide: () => desktop.settings.showPet = false,
                onNativeMenu: () => unawaited(widget.shell.popUpMenu()),
                onOpenPopover: openPopover,
                companion: _companion,
              ),
            ),
            if (_warmingUp) _PopoverWarmUp(panel: _popoverPanel(false), onDone: _warmedUp),
          ],
        ),
        Surface.popover => PopoverStage(
          geometry: _popover ?? _stroll.popoverGeometry(SurfaceSizes.popover),
          closing: _popoverClosing,
          leapBack: _leapBack,
          desktop: desktop,
          companion: _companion,
          library: _library,
          onOpened: _stroll.popoverOpened,
          ready: _popoverReady,
          meter: _meter,
          onClosed: () => unawaited(_popoverClosed()),
          panel: (hidePet) => _popoverPanel(hidePet),
        ),
        Surface.main => _MainSurface(state: this),
        Surface.hidden => const SizedBox.shrink(),
      },
    ),
  );
}

/// The popover, drawn once out of sight (a picture taken of it and thrown away) a few seconds after Mochi shows on
/// Windows: the first time it's drawn takes several times longer than after (the renderer prepares its shaders and
/// caches, the text is laid out), and the first click on Mochi would otherwise wait for that before the genie starts.
class _PopoverWarmUp extends StatefulWidget {
  const _PopoverWarmUp({required this.panel, required this.onDone});

  final Widget panel;
  final VoidCallback onDone;

  @override
  State<_PopoverWarmUp> createState() => _PopoverWarmUpState();
}

class _PopoverWarmUpState extends State<_PopoverWarmUp> {
  final GlobalKey _key = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_draw()));
  }

  Future<void> _draw() async {
    try {
      final boundary = _key.currentContext?.findRenderObject();
      if (boundary is RenderRepaintBoundary && mounted) {
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final image = await boundary.toImage(pixelRatio: ratio);
        image.dispose();
      }
    } on Object {
      // Only a head start.
    }
    if (mounted) widget.onDone();
  }

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    top: 0,
    width: SurfaceSizes.popover.width,
    height: SurfaceSizes.popover.height,
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: ExcludeFocus(
          child: TickerMode(
            enabled: false,
            child: ClipRect(
              clipper: const _NoArea(),
              child: RepaintBoundary(key: _key, child: widget.panel),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Clips to nothing: painted, never seen.
class _NoArea extends CustomClipper<Rect> {
  const _NoArea();

  @override
  Rect getClip(Size size) => Rect.zero;

  @override
  bool shouldReclip(_NoArea old) => false;
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
    final title = page.title;
    final column = Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          MochiTitleBar(
            title: title,
            onDragStart: () => unawaited(state.widget.shell.startDragging()),
            onClose: state.closeMain,
            onBack: page == MainPage.home ? null : back,
            onPair: page == MainPage.home ? () => state.open(MainPage.pairing) : null,
            onSettings: settingsPage ? null : () => state.open(MainPage.settings),
            trailing: settingsPage
                ? _ClaudeStatusPill(desktop: desktop, onTap: () => state.settingsNavigation.tab = SettingsTab.claude)
                : null,
          ),
          Expanded(
            child: switch (page) {
              MainPage.home => HomeScreen(
                desktop: desktop,
                companion: state._companion,
                askFirst: state._takeAskFirst(),
                lastActivity: () => state._lastActivity,
                onPair: () => state.open(MainPage.pairing),
                onSettings: () => state.open(MainPage.settings, pane: SettingsTab.claude),
                onInstall: () => unawaited(state.installMochi()),
                focusSession: state._focusSession,
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
                  onInstall: () => unawaited(state.installMochi()),
                  onRestartToUpdate: () => unawaited(state.restartToUpdate()),
                  onGames: state.openGames,
                  onRecap: state.openRecap,
                  onDecorate: state.openDecorate,
                ),
              ),
              MainPage.games => GamesScreen(desktop: desktop),
              MainPage.recap => RecapScreen(desktop: desktop, images: state._images),
            },
          ),
        ],
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): switch (page) {
          MainPage.home => state.closeMain,
          MainPage.settings || MainPage.games || MainPage.recap => state.closeSettings,
          MainPage.pairing => back,
        },
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => state.open(MainPage.settings),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => state.open(MainPage.settings),
      },
      child: FocusScope(
        autofocus: true,
        child: ResizeEdges(
          onResize: (edge) => unawaited(state.widget.shell.startResizing(edge)),
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
