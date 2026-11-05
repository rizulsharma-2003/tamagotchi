import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../core/pet_cues.dart';
import '../desktop.dart';
import 'pet/pet_surface.dart';
import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'screens/settings_screen.dart';
import 'shell.dart';
import 'widgets/title_bar.dart';

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
  });

  final MochiDesktop desktop;
  final DesktopShell shell;

  /// The recorded animations; loaded from the assets when not given.
  final Future<PoseLibrary?>? library;
  final Surface initialSurface;
  final MainPage initialPage;

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

  MochiDesktop get desktop => widget.desktop;
  Surface get surface => _surface;
  MainPage get page => _page;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLibrary());
    _subscriptions.add(widget.shell.actions.listen(handle));
    _subscriptions.add(desktop.cues.listen(_noteActivity));
    desktop.sessions.addListener(_sessionsChanged);
    desktop.settings.addListener(_settingsChanged);
    unawaited(widget.shell.show(_surface, petPosition: desktop.settings.petPosition));
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

  /// "Mochi on the desktop" switched while the main window is closed.
  void _settingsChanged() {
    if (_surface == Surface.main) return;
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
      case ShellAction.closeWindow:
        if (_surface == Surface.main) {
          closeMain();
        } else {
          _show(Surface.hidden);
        }
      case ShellAction.quit:
        unawaited(_quit());
    }
  }

  void open(MainPage page) {
    setState(() => _page = page);
    _show(Surface.main);
  }

  /// Back to the desktop pet (or nothing, with the pet turned off). Mochi keeps running in the tray.
  void closeMain() => _show(desktop.settings.showPet ? Surface.pet : Surface.hidden);

  void _show(Surface surface) {
    setState(() => _surface = surface);
    unawaited(widget.shell.show(surface, petPosition: desktop.settings.petPosition));
  }

  Future<void> _rememberPetPosition() async {
    final position = await widget.shell.position();
    if (position != null) desktop.settings.petPosition = position;
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.settings, desktop.motion]),
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
          library: _library,
          lastActivity: () => _lastActivity,
          onAction: handle,
          onDragStart: () => unawaited(widget.shell.startDragging()),
          onDragEnd: () => unawaited(_rememberPetPosition()),
          onHide: () => desktop.settings.showPet = false,
        ),
        Surface.main => _MainSurface(state: this),
        Surface.hidden => const SizedBox.shrink(),
      },
    ),
  );
}

/// The main window's frame: rounded clay backdrop, title bar, the page.
class _MainSurface extends StatelessWidget {
  const _MainSurface({required this.state});

  final DesktopAppState state;

  @override
  Widget build(BuildContext context) {
    final page = state.page;
    final desktop = state.desktop;
    void back() => state.open(MainPage.home);
    final title = switch (page) {
      MainPage.home => 'Mochi',
      MainPage.pairing => 'Pair a phone',
      MainPage.settings => 'Settings',
    };
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): page == MainPage.home ? state.closeMain : back,
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () => state.open(MainPage.settings),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () => state.open(MainPage.settings),
      },
      child: FocusScope(
        autofocus: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: MochiBackground(
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  MochiTitleBar(
                    title: title,
                    onDragStart: () => unawaited(state.widget.shell.startDragging()),
                    onClose: state.closeMain,
                    onBack: page == MainPage.home ? null : back,
                    onPair: page == MainPage.pairing ? null : () => state.open(MainPage.pairing),
                    onSettings: page == MainPage.settings ? null : () => state.open(MainPage.settings),
                  ),
                  Expanded(
                    child: switch (page) {
                      MainPage.home => HomeScreen(
                        desktop: desktop,
                        library: state._library,
                        lastActivity: () => state._lastActivity,
                        onPair: () => state.open(MainPage.pairing),
                        onSettings: () => state.open(MainPage.settings),
                      ),
                      MainPage.pairing => PairingScreen(
                        link: desktop.link,
                        onTestNotification: desktop.phone.sendTestNotification,
                        clock: () => desktop.sessions.now,
                      ),
                      MainPage.settings => SettingsScreen(desktop: desktop, onPair: () => state.open(MainPage.pairing)),
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
