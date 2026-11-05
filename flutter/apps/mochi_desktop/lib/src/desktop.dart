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
import 'platform/system.dart';

/// This app's version, shown on the other devices and in Settings.
const String appVersion = '0.1.0';

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
    UrlOpener? opener,
    BridgeServer? bridge,
    DateTime Function()? clock,
  }) : _claude = claude,
       _bridge = bridge ?? BridgeServer(paths) {
    ask = AskMochi(sessions: sessions, runner: claude, cue: cue, opener: opener, model: () => settings.model, clock: clock);
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
      link: LinkHost(
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
        log: kDebugMode ? (message) => debugPrint('Mochi: $message') : null,
      ),
      motion: SystemMotion(),
      claude: claude,
      opener: const SystemUrlOpener(),
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
  final ClaudeRunner? Function() _claude;
  final BridgeServer _bridge;

  final StreamController<PetCue> _cues = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  Timer? _prune;

  /// Why Claude Code's events can't reach this copy (another copy of Mochi has the bridge), if so.
  final ValueNotifier<String?> bridgeProblem = ValueNotifier(null);

  /// Mochi's moments, for the pet.
  Stream<PetCue> get cues => _cues.stream;

  BridgeServer get bridge => _bridge;

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
  }

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

  /// Claude's moments, live only.
  void _transition(SessionTransition transition) {
    if (transition.delivery == Delivery.late || !transition.phaseChanged) return;
    switch (transition.phase) {
      case SessionPhase.turnCompleted:
        cue(PetCue.finished);
      case SessionPhase.waitingForUser:
        cue(PetCue.needsYou);
      case SessionPhase.turnFailed:
        cue(PetCue.snag);
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

  Future<void> dispose() async {
    _prune?.cancel();
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
