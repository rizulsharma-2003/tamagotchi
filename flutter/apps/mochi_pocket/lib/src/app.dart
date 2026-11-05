import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';

import 'model/app_settings.dart';
import 'model/pocket_model.dart';
import 'scene/pose_library.dart';
import 'screens/home_screen.dart';
import 'screens/pairing_screen.dart';
import 'services/alert_notifier.dart';
import 'services/link_opener.dart';
import 'services/platform_bridge.dart';
import 'theme.dart';
import 'voice/updates_reader.dart';
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
    this.library,
    this.scan,
  });

  final PocketModel model;
  final PlatformBridge bridge;
  final AlertNotifier notifier;

  /// This phone's appearance and voice choices.
  final AppSettings settings;

  /// Reads "Waiting for you" aloud.
  final UpdatesReader reader;
  final LinkOpener opener;

  /// The recorded animations; loaded from the assets when not given.
  final Future<PoseLibrary?>? library;

  /// Replaces the camera scanner (tests).
  final Future<String?> Function(BuildContext context)? scan;

  @override
  State<MochiApp> createState() => _MochiAppState();
}

class _MochiAppState extends State<MochiApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey();
  late final AppLifecycleListener _lifecycle = AppLifecycleListener(onResume: widget.model.resume);
  StreamSubscription<String>? _links;
  PoseLibrary? _library;
  bool _askedForNotifications = false;

  PocketModel get model => widget.model;

  @override
  void initState() {
    super.initState();
    _lifecycle;
    model.addListener(_modelChanged);
    unawaited(_loadLibrary());
    unawaited(_start());
  }

  /// Once paired (scanned, pasted or opened), ask once for permission to show the Mac's alerts.
  void _modelChanged() {
    if (model.paired) unawaited(_askForNotifications());
  }

  Future<void> _loadLibrary() async {
    try {
      final library = await (widget.library ?? PoseLibrary.load(rootBundle));
      if (mounted) setState(() => _library = library);
    } on Object catch (error) {
      debugPrint('Mochi: the animations could not be loaded (${error.runtimeType})');
    }
  }

  Future<void> _start() async {
    await model.load();
    _links = widget.bridge.links.listen(_opened);
    final initial = await widget.bridge.initialLink();
    if (initial != null) await _opened(initial);
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
          PairingPhase.unpaired => PairingScreen(model: model, library: _library, scan: widget.scan),
          PairingPhase.paired => HomeScreen(
            model: model,
            library: _library,
            opener: widget.opener,
            notifier: widget.notifier,
            settings: widget.settings,
            reader: widget.reader,
          ),
        },
      ),
    ),
  );
}
