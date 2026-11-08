import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';

import 'live/live_updates.dart';
import 'model/app_settings.dart';
import 'model/pocket_model.dart';
import 'scene/phone_world.dart';
import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'services/alert_notifier.dart';
import 'services/link_opener.dart';
import 'services/platform_bridge.dart';
import 'talk/speech_listener.dart';
import 'talk/talk_model.dart';
import 'theme.dart';
import 'voice/updates_reader.dart';
import 'widget/home_widget.dart';
import 'widgets/clay.dart';

/// Mochi for Android: the pairing screen until this phone joins your Mac's room, then the home screen. Pairing links
/// opened from elsewhere (a QR code app, a browser, `adb`) arrive through [bridge].
class MochiApp extends StatefulWidget {
  const MochiApp({
    super.key,
    required this.model,
    required this.bridge,
    required this.notifier,
    required this.settings,
    required this.reader,
    this.opener = const UrlLinkOpener(),
    this.world,
    this.scan,
    this.live,
    this.speech,
    this.talkTo,
    this.homeWidget,
  });

  final PocketModel model;
  final PlatformBridge bridge;
  final AlertNotifier notifier;

  /// This phone's appearance and voice choices.
  final AppSettings settings;

  /// Reads "Waiting for you" aloud.
  final UpdatesReader reader;
  final LinkOpener opener;

  /// Mochi's world, following [model]'s room (made here when not given).
  final PhoneWorld? world;

  /// Replaces the camera scanner (tests).
  final Future<String?> Function(BuildContext context)? scan;

  /// Mochi on the lock screen while Claude works (Settings' sample and switch).
  final LiveUpdates? live;

  /// Hold to talk's speech recognition (none: no talking, only typing).
  final SpeechListener? speech;

  /// Where hold to talk sends what you say: [model]'s computer, unless a development build's test room is given.
  final PocketModel? talkTo;

  /// The home-screen widget (Settings adds it to the home screen).
  final HomeWidget? homeWidget;

  @override
  State<MochiApp> createState() => _MochiAppState();
}

class _MochiAppState extends State<MochiApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey();
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: widget.model.resume, onHide: () => _talk?.paused());
  late final TalkModel? _talk = widget.speech == null ? null : TalkModel(model: widget.talkTo ?? widget.model, listener: widget.speech!);
  StreamSubscription<String>? _links;
  StreamSubscription<String>? _placeSubscription;

  /// Where the app is asked to go ([AppPlace]): the widget's taps, the ongoing notification's buttons.
  final StreamController<String> _places = StreamController.broadcast();

  /// Mochi's world for the room the app shows (the iPhone's `PhoneWorld.shared`): it follows the room from launch and
  /// ticks only while the room can be seen.
  late final PhoneWorld _world = widget.world ?? PhoneWorld(model: widget.model);
  bool _askedForNotifications = false;

  PocketModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    model.addListener(_modelChanged);
    _world;
    unawaited(_start());
  }

  /// Once paired (scanned, pasted or opened), ask once for permission to show the Mac's alerts.
  void _modelChanged() {
    if (model.paired) unawaited(_askForNotifications());
  }

  Future<void> _start() async {
    await model.load();
    _links = widget.bridge.links.listen(_opened);
    _placeSubscription = widget.bridge.places.listen(_places.add);
    final initial = await widget.bridge.initialLink();
    if (initial != null) await _opened(initial);
    final place = await widget.bridge.initialPlace();
    // Once the home screen is there to go from.
    if (place != null) WidgetsBinding.instance.addPostFrameCallback((_) => _places.add(place));
  }

  /// A `mochi://pair` link opened from outside the app.
  Future<void> _opened(String text) async {
    final code = PairingCode.parse(text);
    if (model.paired && code != null && code.room != model.credentials?.room && model.connection != MacConnection.removed) {
      final context = _navigator.currentContext;
      if (context == null) return;
      final change = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('Pair with ${code.name}?'),
          content: Text('This phone is paired with ${model.hostList}. Pairing with ${code.name} replaces that pairing.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Pair')),
          ],
        ),
      );
      if (change != true) return;
    }
    await model.pair(text);
  }

  Future<void> _askForNotifications() async {
    if (_askedForNotifications) return;
    _askedForNotifications = true;
    try {
      await widget.notifier.requestPermission();
    } on Object catch (error) {
      debugPrint('Mochi: notification permission request failed (${error.runtimeType})');
    }
  }

  @override
  void dispose() {
    model.removeListener(_modelChanged);
    _lifecycle.dispose();
    unawaited(_links?.cancel());
    unawaited(_placeSubscription?.cancel());
    unawaited(_places.close());
    _talk?.dispose();
    if (widget.world == null) _world.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.settings, builder: (context, _) => _app(context));

  /// System, Light or Dark (Settings › Appearance) applies at once: the theme, the status and navigation bar icons
  /// (they follow the theme in use, below) and the room's day or night look.
  Widget _app(BuildContext context) => MaterialApp(
    title: 'Mochi',
    debugShowCheckedModeBanner: false,
    navigatorKey: _navigator,
    theme: mochiTheme(Brightness.light),
    darkTheme: mochiTheme(Brightness.dark),
    themeMode: widget.settings.appearance.themeMode,
    home: ListenableBuilder(
      listenable: model,
      builder: (context, _) => AnnotatedRegion<SystemUiOverlayStyle>(
        // Edge to edge: transparent bars, with icons that read on the theme's backdrop.
        value: (context.palette.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark).copyWith(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
        ),
        child: switch (model.phase) {
          PairingPhase.loading => const Scaffold(
            body: PocketBackground(
              child: Center(child: CircularProgressIndicator(semanticsLabel: 'Loading')),
            ),
          ),
          PairingPhase.unpaired => PairingScreen(model: model, scan: widget.scan),
          PairingPhase.paired => HomeScreen(
            model: model,
            world: _world,
            opener: widget.opener,
            notifier: widget.notifier,
            settings: widget.settings,
            reader: widget.reader,
            live: widget.live,
            homeWidget: widget.homeWidget,
            bridge: widget.bridge,
            places: _places.stream,
            talk: _talk,
          ),
        },
      ),
    ),
  );
}
