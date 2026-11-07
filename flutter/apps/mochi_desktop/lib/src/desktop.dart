import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'core/ask_mochi.dart';
import 'core/claude_cli.dart';
import 'core/desktop_settings.dart';
import 'core/hook_setup.dart';
import 'core/pet_cues.dart';
import 'core/session_store.dart';
import 'core/sessions.dart';
import 'core/turn_summaries.dart';
import 'demo.dart';
import 'link/link_host.dart';
import 'link/phone_sync.dart';
import 'platform/credential_vault.dart';
import 'platform/startup.dart';
import 'platform/system.dart';
import 'platform/win32_install.dart';
import 'update/self_install.dart';
import 'update/update_feed.dart';
import 'update/update_keys.dart';
import 'update/update_manifest.dart';
import 'update/update_signing.dart';
import 'update/updater.dart';

/// This app's version, shown on the other devices and in Settings (pubspec.yaml's `version`, before the `+`;
/// scripts/release-windows.sh sets both).
const String appVersion = '0.1.0';

/// The build number (pubspec.yaml's `version`, after the `+`): it decides which copy is newer when updating.
const int appBuild = 1;

/// Everything Mochi for Windows does, wired together: hook events from the bridge into the sessions, the sessions into
/// Mochi's moods and the phones, phone commands into Ask Mochi. The windows and the tray only show it.
class MochiDesktop {
  MochiDesktop({
    required this.paths,
    required this.settings,
    required this.sessions,
    required this.hooks,
    required this.link,
    required this.motion,
    required ClaudeRunner? Function() claude,
    this.opener,
    this.folders,
    StartupItem? startup,
    String? Function()? locateClaude,
    BridgeServer? bridge,
    DateTime Function()? clock,
    Updater? updater,
    SelfInstaller? installer,
  }) : _claude = claude,
       _locateClaude = locateClaude,
       startup = startup ?? const UnsupportedStartup(),
       updater = updater ?? Updater.unsupported(),
       installer = installer ?? SelfInstaller.unsupported(),
       _bridge = bridge ?? BridgeServer(paths) {
    ask = AskMochi(
      sessions: sessions,
      runner: claude,
      cue: cue,
      opener: opener,
      model: () => settings.model,
      petName: () => settings.petName,
      clock: clock,
    );
    phone = PhoneSync(
      host: link,
      sessions: sessions,
      settings: settings,
      ask: ask,
      summariesFlagFile: paths.summariesFlagFile,
      cue: cue,
      summarize: _summarize,
      clock: clock,
    );
  }

  /// The real app on this computer.
  factory MochiDesktop.system() {
    final paths = BridgePaths.resolve();
    BridgePaths.ensurePrivateDirectory(paths.home);
    final settings = DesktopSettings(FileSettingsDocument(paths.settingsFile));
    final environment = Platform.environment;
    String? executable;
    var searched = false;
    ClaudeRunner? claude() {
      if (!searched || executable == null) {
        executable = ClaudeLocator.locate();
        searched = true;
      }
      final found = executable;
      if (found == null) return null;
      return ProcessClaudeRunner(
        executable: found,
        workingDirectory: paths.assistantDirectory,
        environment: ClaudeLocator.cleanEnvironment(environment, windows: Platform.isWindows),
      );
    }

    final name = computerName();
    final startup = systemStartup();
    final link = LinkHost(
      vault: demoMode ? MemoryVault() : platformVault(paths),
      api: demoMode ? const DemoLinkApi() : const RelayLinkApi(),
      connect: (credentials) => RelayLink(
        credentials,
        platform: Platform.isWindows ? 'windows' : Platform.operatingSystem,
        app: appVersion,
        connect: demoMode ? (url, headers) => DemoSocket(credentials.device) : null,
        // Connection events only: the client never logs values or secrets.
        onLog: kDebugMode ? (message) => debugPrint('Mochi Link: $message') : null,
      ),
      hostName: name,
      platform: Platform.isWindows ? 'windows' : Platform.operatingSystem,
      phonesHintFile: demoMode ? null : paths.join(paths.linkDirectory, 'phones'),
      log: kDebugMode ? (message) => debugPrint('Mochi: $message') : null,
    );
    // Installing and updating itself: Mochi for Windows only (not the macOS development build or the demo).
    final layout = InstallLayout.resolve();
    final windows = Platform.isWindows && !demoMode;
    final installer = windows
        ? SelfInstaller(
            layout: layout,
            executable: Platform.resolvedExecutable,
            version: appVersion,
            system: Win32InstallSystem(),
            startup: startup,
            startupFor: (exe) => RunKeyStartup(registry: Win32StartupRegistry(), executable: exe),
          )
        : SelfInstaller.unsupported();
    final updater = windows
        ? Updater(
            files: UpdateFiles(paths),
            layout: layout,
            installed: installer.installed,
            currentVersion: appVersion,
            currentBuild: appBuild,
            // `MOCHI_UPDATE_CHANNEL=windows-test` tries a release on the relay's test feed first.
            feed: RelayUpdateFeed(credentials: link.ensureRoom, platform: environment['MOCHI_UPDATE_CHANNEL'] ?? 'windows'),
            publicKey: UpdateSigning.base64UrlDecode(windowsUpdatePublicKey),
            autoDownload: () => settings.autoUpdate,
            windowsVersion: windowsVersion(Platform.operatingSystemVersion),
            helper: HookSetup.findBundledHelper,
          )
        : Updater.unsupported();
    return MochiDesktop(
      paths: paths,
      settings: settings,
      sessions: SessionStore(),
      hooks: HookSetup(
        paths: paths,
        settingsFile: ClaudeHookInstaller.defaultSettingsFile(),
        style: Platform.isWindows ? HookCommandStyle.exec : HookCommandStyle.shell,
        bundledHelper: HookSetup.findBundledHelper(),
        managedSettingsFile: ClaudeHookInstaller.defaultManagedSettingsFile(),
      ),
      link: link,
      motion: SystemMotion(),
      claude: claude,
      opener: const SystemUrlOpener(),
      folders: const SystemFolderOpener(),
      startup: startup,
      locateClaude: () {
        claude();
        return executable;
      },
      updater: updater,
      installer: installer,
    );
  }

  final BridgePaths paths;
  final DesktopSettings settings;
  final SessionStore sessions;
  final HookSetup hooks;
  final LinkHost link;
  final SystemMotion motion;
  late final AskMochi ask;
  late final PhoneSync phone;

  /// Opens links (About, the agent) in the browser; null in tests.
  final UrlOpener? opener;

  /// Shows Mochi's folders in File Explorer; null in tests.
  final FolderOpener? folders;

  /// "Start Mochi with Windows" (Settings › General).
  final StartupItem startup;

  /// Mochi's updates (Settings › About, the tray's "Restart to Update").
  final Updater updater;

  /// "Install Mochi": this copy into the install folder, so it can update itself.
  final SelfInstaller installer;
  final ClaudeRunner? Function() _claude;
  final String? Function()? _locateClaude;
  final BridgeServer _bridge;

  final StreamController<PetCue> _cues = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _prune;

  /// Why Claude Code's events can't reach this copy (another copy of Mochi has the bridge), if so.
  final ValueNotifier<String?> bridgeProblem = ValueNotifier(null);

  /// Mochi's moments, for the pet.
  Stream<PetCue> get cues => _cues.stream;

  BridgeServer get bridge => _bridge;

  /// Where Claude Code's `claude` is on this PC (null: not found), for Settings. Looks again each time.
  String? locateClaude() => _locateClaude?.call();

  void cue(PetCue cue) {
    if (!_cues.isClosed) _cues.add(cue);
  }

  Future<void> start() async {
    hooks.refresh();
    _subscriptions.add(_bridge.events.listen(_live));
    _subscriptions.add(sessions.transitions.listen(_transition));
    try {
      await _bridge.start();
    } on StateError catch (error) {
      bridgeProblem.value = error.message;
    } on SocketException catch (error) {
      bridgeProblem.value = "Couldn't listen for Claude Code (${error.message}).";
    }
    _drainSpool();
    await link.start();
    phone.start();
    _prune = Timer.periodic(const Duration(minutes: 1), (_) => sessions.prune());
    _startUpdates();
  }

  /// The installed copy keeps its Settings › Apps entry and the hooks' helper in step with this version, and checks
  /// for updates. Mochi says when one is ready, and after it was updated.
  void _startUpdates() {
    if (installer.installed) {
      installer.refreshAtLaunch();
      if (hooks.helperInstalled) hooks.refreshInstalledHelper();
    }
    updater.onReady = (_) => cue(PetCue.updateReady);
    updater.start();
    // A moment later, so the pet is there to say it.
    if (updater.updatedTo != null) {
      _greeting = Timer(const Duration(seconds: 4), () => cue(PetCue.updated));
    } else if (updater.phase == UpdatePhase.ready) {
      _greeting = Timer(const Duration(seconds: 4), () => cue(PetCue.updateReady));
    }
  }

  Timer? _greeting;

  /// What the helper kept while Mochi wasn't running: it updates the sessions (late), without reactions.
  void _drainSpool() {
    final drained = EventSpool.drain(paths.spoolFile);
    sessions.droppedEvents += drained.dropped;
    for (final line in drained.lines) {
      try {
        sessions.apply(EventValidator.decode(line), delivery: Delivery.late);
      } on WireRejection {
        // Too old or malformed: skip it.
      }
    }
  }

  void _live(WireEvent event) {
    phone.record(event);
    sessions.apply(event);
  }

  /// Claude's moments, live only, as Settings allows (General › Pause reactions, Notifications › On this PC).
  void _transition(SessionTransition transition) {
    if (transition.delivery == Delivery.late || !transition.phaseChanged || settings.pauseReactions) return;
    switch (transition.phase) {
      case SessionPhase.turnCompleted:
        if (settings.celebrateFinished) cue(PetCue.finished);
      case SessionPhase.waitingForUser:
        cue(PetCue.needsYou);
      case SessionPhase.turnFailed:
        if (settings.showSnags) cue(PetCue.snag);
      default:
        break;
    }
  }

  /// Petting, play or treats on this PC (Mochi reacts, and so do the phones).
  void interact(String kind) {
    cue(switch (kind) {
      'pet' => PetCue.pet,
      'play' => PetCue.play,
      _ => PetCue.treat,
    });
    phone.interacted(kind);
  }

  Future<TurnSummary?> _summarize(TurnReport report, List<String> earlier) async {
    final runner = _claude();
    if (runner == null) return null;
    final run = await runner.run(
      TurnSummarizer.arguments,
      input: TurnSummarizer.prompt(report, earlier: earlier),
      timeout: const Duration(seconds: 45),
    );
    if (!run.ok) return null;
    final result = TurnSummarizer.result(run.output);
    return result == null ? null : TurnSummarizer.parse(result);
  }

  bool _disposed = false;

  /// Everything stops (Quit, or the helper taking over for an update). Only once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _prune?.cancel();
    _greeting?.cancel();
    updater.stop();
    phone.stop();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _bridge.dispose();
    link.dispose();
    motion.dispose();
    await _cues.close();
  }
}
