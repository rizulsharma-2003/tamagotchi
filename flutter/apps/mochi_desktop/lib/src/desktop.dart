import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_wire/mochi_wire.dart';

import 'core/agent/agent_command.dart' show AgentConnections, AgentZone;
import 'core/agent/agent_controller.dart';
import 'core/agent/cloud_token_vault.dart';
import 'core/ask_attach.dart' show DropPayload;
import 'core/ask_brain.dart' show BrainSetup;
import 'core/ask_mochi.dart';
import 'core/brain_session.dart' show BrainEnvironment, ProcessBrain;
import 'core/claude_cli.dart';
import 'core/desktop_settings.dart';
import 'core/desktop_world.dart';
import 'core/fresh_lines.dart';
import 'core/focus.dart';
import 'core/games.dart';
import 'core/holidays.dart';
import 'core/json_store.dart';
import 'core/mischief.dart';
import 'core/hook_setup.dart';
import 'core/hotkeys.dart';
import 'core/notifications.dart' show AttentionLevel;
import 'core/jump_list.dart';
import 'core/pc_rhythm.dart';
import 'core/pc_actions.dart';
import 'core/pet_cues.dart';
import 'core/purr.dart';
import 'core/reacts.dart';
import 'core/screen_peek.dart';
import 'core/recap.dart';
import 'core/room.dart';
import 'core/reactions.dart';
import 'core/session_store.dart';
import 'core/sessions.dart';
import 'core/sounds.dart';
import 'core/streaks.dart';
import 'core/toasts.dart';
import 'core/turn_summaries.dart';
import 'demo.dart';
import 'link/agent_phone.dart';
import 'link/link_host.dart';
import 'link/phone_sync.dart';
import 'platform/cloud_token_vault.dart';
import 'platform/credential_vault.dart';
import 'platform/file_drop.dart';
import 'platform/pc_platform.dart';
import 'platform/foreground_window.dart';
import 'platform/screen_capture.dart';
import 'platform/reacts_readers.dart';
import 'platform/runner_system.dart';
import 'platform/startup.dart';
import 'platform/system.dart';
import 'platform/time_zone.dart';
import 'platform/win32_alerts.dart';
import 'platform/win32_install.dart';
import 'platform/win32_usage.dart';
import 'update/self_install.dart';
import 'update/update_feed.dart';
import 'update/update_keys.dart';
import 'update/update_manifest.dart';
import 'update/update_signing.dart';
import 'update/updater.dart';

/// This app's version, shown on the other devices and in Settings (pubspec.yaml's `version`, before the `+`;
/// scripts/release-windows.sh sets both).
const String appVersion = '0.2.8';

/// The build number (pubspec.yaml's `version`, after the `+`): it decides which copy is newer when updating.
const int appBuild = 10;

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
    ClaudeRunner? Function()? agentClaude,
    File Function()? agentSignInNotes,
    CloudTokenVault? cloudTokens,
    this.agentDebug,
    this.agentDebugAfter = const Duration(seconds: 6),
    this.opener,
    PcActions? pc,
    this.folders,
    StartupItem? startup,
    String? Function()? locateClaude,
    BrainSetup? Function()? brainSetup,
    BridgeServer? bridge,
    DateTime Function()? clock,
    Updater? updater,
    SelfInstaller? installer,
    ToastService? toasts,
    SoundOutput? sound,
    UsageSampler? usage,
    HotkeyRegistrar? hotkeys,
    JumpListService? jumpList,
    WorldStore? worldStore,
    JsonStore Function(String file)? stores,
    double Function()? uptime,
    int? worldSeed,
    bool stage = false,
    bool Function()? fullScreen,
    MediaReader? media,
    MicReader? mic,
    ForegroundApps? foregroundApps,
    ReactsForce? reactsForce,
    Stream<void>? sessionEnding,
    DropSource? drops,
    WindowCapturer? windowCapturer,
    ForegroundWindows? foregroundWindows,
    ScreenshotStore? screenshots,
  }) : _claude = claude,
       _agentClaude = agentClaude ?? claude,
       _agentSignInNotes = agentSignInNotes,
       _cloudTokens = cloudTokens,
       _locateClaude = locateClaude,
       startup = startup ?? const UnsupportedStartup(),
       updater = updater ?? Updater.unsupported(),
       installer = installer ?? SelfInstaller.unsupported(),
       toasts = toasts ?? const UnsupportedToasts(),
       _bridge = bridge ?? BridgeServer(paths) {
    if (jumpList != null) this.jumpList = StartMenuJumpList(service: jumpList, installed: () => this.installer.installed);
    sounds = MochiSounds(output: sound ?? const SilentOutput(), volume: () => settings.soundVolume, clock: clock);
    // Claude's moments: Reactions posts their notifications and sounds (W1) and tells the views; Mochi's world animates
    // them from the hook events themselves.
    reactions = Reactions(settings: settings, sessions: sessions, cue: _claudeCue, toasts: this.toasts, sounds: sounds, clock: clock);
    rhythm = PcRhythm(settings: settings, sampler: usage);
    world = DesktopWorld(
      settings: settings,
      rhythm: rhythm,
      sounds: sounds,
      toasts: this.toasts,
      store: worldStore,
      freshLines: HaikuLineWriter(claude).call,
      reducedMotion: () => motion.reduced,
      clock: clock,
      uptime: uptime,
      seed: worldSeed,
    );
    games = DesktopGames(settings: settings, world: world);
    final store = stores ?? (_) => MemoryJsonStore();
    focus = DesktopFocus(settings: settings, world: world, rhythm: rhythm, store: store('focus-log.json'));
    reactions.focusing = () => focus.focusing;
    room = RoomEditor(settings: settings, world: world);
    mischief = MischiefGate(
      settings: settings,
      rhythm: rhythm,
      motion: motion,
      supported: stage,
      fullScreen: fullScreen,
      focusing: () => focus.focusing,
      clock: clock,
    );
    reacts = ReactsDirector(
      gate: mischief,
      media: media ?? const NoMedia(),
      mic: mic ?? const NoMic(),
      apps: foregroundApps ?? const NoForegroundApp(),
      force: reactsForce,
      clock: clock,
    );
    // Mochi's sounds are muted while a call has the microphone (X7).
    sounds.muted = () => reacts.calling;
    holidays = DesktopHolidays(settings: settings, world: world, store: store('seasons.json'), clock: clock, decorating: () => room.isEditing);
    purr = PurrSession(settings: settings, sounds: sounds, rhythm: rhythm, pet: () => interact('pet'), time: world.now, clock: clock);
    recap = DesktopRecap(settings: settings, world: world, focus: focus, toasts: this.toasts, store: store('journal.json'), clock: clock);
    streaks = StreakWatch(store: store('streaks.json'), recapStreak: () => recap.recap().streak, clock: clock);
    recap.afterRecord = streaks.observe;
    this.hotkeys = Hotkeys(
      registrar: hotkeys ?? const UnsupportedHotkeys(),
      chosen: settings.shortcut,
      onPressed: (shortcut) {
        if (!_shortcuts.isClosed) _shortcuts.add(shortcut);
      },
    );
    ask = AskMochi(
      sessions: sessions,
      runner: claude,
      cue: cue,
      opener: opener,
      pc: pc,
      pcAllowed: () => settings.pcControl,
      model: () => settings.model,
      petName: () => settings.petName,
      clock: clock,
      brainSetup: brainSetup,
      messagingAllowed: () => settings.messageSessions,
      log: _askLog,
      screenshots: screenshots,
    );
    // "What's on my screen?" (X17): the window you were using before Mochi's came up, a picture of only that window when
    // you press the button, and only while Settings › Assistant has it on.
    foreground = ForegroundMemory(foregroundWindows ?? const NoForegroundWindow());
    ask.peek = ScreenPeek(
      memory: foreground,
      capturer: windowCapturer ?? const NoWindowCapturer(),
      enabled: () => settings.showScreen,
      petName: () => settings.petName,
    );
    settings.addListener(_screenSwitch);
    // A picture left by a request that never ended (a crash, a power cut) goes at startup.
    screenshots?.sweep();
    // Files, text and links dropped on Mochi (X13, X14) wait in the Ask box for the user; Ask Mochi opens with them.
    if (drops != null) {
      _subscriptions.add(drops.hovering.listen((over) => ask.draft.hovering = over));
      _subscriptions.add(drops.drops.listen(_dropped));
    }
    phone = PhoneSync(
      host: link,
      sessions: sessions,
      settings: settings,
      ask: ask,
      summariesFlagFile: paths.summariesFlagFile,
      cue: cue,
      summarize: _summarize,
      clock: clock,
      away: () => rhythm.away,
      resting: () => rhythm.resting,
      friendship: () => world.world.progress.friendshipLevel,
    );
    // Mochi's agent (W23a): mail, meetings and tasks from your Claude connectors, told as Settings › Agent says. Nothing runs
    // while it's off. "What's pending?" (typed or from a phone) asks it.
    agent = AgentController(
      settings: settings,
      store: store('agent.json'),
      runner: _agentClaude,
      phone: LinkAgentPhone(link),
      say: (line, seconds) {
        world.world.say(line, duration: seconds.toDouble());
        world.noteChanged();
      },
      opener: opener,
      clock: clock,
      zone: () => AgentZone(TimeZoneName.current(), DateTime.now().timeZoneOffset),
      signInNotes: _agentSignInNotes,
      tokenVault: _cloudTokens,
      log: _askLog,
      lookingAtMochi: () => reactions.lookingAtMochi(),
    );
    ask.agentNews = agent.answer;
    addExitHook(agent.stop);
    // Ask Mochi's brain: approvals also show on the phones, a delivered prompt's follow-up is Mochi's bubble, and quitting
    // (or Windows ending the session) declines a pending card and stops the helper session.
    ask.brain
      ?..phones = phone
      ..announce = (line) {
        world.world.say(line, duration: 6);
        world.noteChanged();
      };
    ask.tricks.addAll({
      'focus_start': (minutes) {
        minutes == null ? focus.begin() : focus.beginMinutes(minutes);
        return AskOutcome('Focus time${minutes == null ? '' : ': $minutes minutes'}. I\'ll nap till your break.');
      },
      'focus_stop': (_) {
        focus.stop();
        return const AskOutcome('Focus stopped.');
      },
    });
    addExitHook(ask.shutdown);
    // Windows ending the session (a log off or a shutdown): whatever Mochi moved goes back first (X2).
    _ending = sessionEnding?.listen((_) {
      runExitHooks();
      final waiting = runExitTasks();
      if (waiting != null) unawaited(waiting);
    });
  }

  StreamSubscription<void>? _ending;

  final List<void Function()> _exitHooks = [];

  /// [hook] runs when the app quits or Windows ends the session: whatever must be put back before the process goes (the
  /// window nudges, X2). It must be quick and synchronous.
  void addExitHook(void Function() hook) => _exitHooks.add(hook);

  void removeExitHook(void Function() hook) => _exitHooks.remove(hook);

  final List<Future<void>? Function()> _exitTasks = [];

  /// [task] runs when the app quits, and quitting waits for the future it returns (at most [exitWait]; null: nothing to
  /// wait for): what must be put back and can only be done by asking the runner (desktop icon play, X5). Windows ending
  /// the session starts it without waiting.
  void addExitTask(Future<void>? Function() task) => _exitTasks.add(task);

  void removeExitTask(Future<void>? Function() task) => _exitTasks.remove(task);

  /// The longest quitting waits for the exit tasks.
  static const Duration exitWait = Duration(milliseconds: 1500);

  /// Starts the exit tasks: a future that ends when they have (or after [exitWait]), or null when none has anything to
  /// wait for (quitting then doesn't wait at all).
  Future<void>? runExitTasks() {
    final running = <Future<void>>[];
    for (final task in List.of(_exitTasks)) {
      try {
        final waiting = task();
        if (waiting != null) running.add(waiting.catchError((Object error) => debugPrint('Mochi: an exit task failed (${error.runtimeType})')));
      } on Object catch (error) {
        debugPrint('Mochi: an exit task failed (${error.runtimeType})');
      }
    }
    if (running.isEmpty) return null;
    return Future.wait(running)
        .timeout(exitWait)
        .then<void>(
          (_) {},
          onError: (Object _) => debugPrint('Mochi: quitting before an exit task finished (its journal finishes it at the next start)'),
        );
  }

  /// Runs the exit hooks now (quitting, or the session ending).
  void runExitHooks() {
    for (final hook in List.of(_exitHooks)) {
      try {
        hook();
      } on Object catch (error) {
        debugPrint('Mochi: an exit hook failed (${error.runtimeType})');
      }
    }
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

    // The agent's own `claude`: the same program with its environment (connectors ready before the model looks; never an API key).
    ClaudeRunner? agentClaude() {
      claude();
      final found = executable;
      if (found == null) return null;
      return AgentClaude.runner(
        executable: found,
        workingDirectory: paths.assistantDirectory,
        baseEnvironment: environment,
        windows: Platform.isWindows,
      );
    }

    // Mochi's brain needs a native `claude` (not npm's cmd shim) and the helper that relays its tools; without either the
    // one-off path answers.
    BrainSetup? brainSetup() {
      if (demoMode) return null;
      claude();
      final found = executable;
      if (found == null || !ProcessBrain.canRun(found)) return null;
      final installedHelper = File(paths.installedHelper).existsSync() ? paths.installedHelper : null;
      final helper = HookSetup.findBundledHelper() ?? installedHelper;
      if (helper == null) return null;
      return BrainSetup(
        executable: found,
        helper: helper,
        environment: BrainEnvironment.build(environment, windows: Platform.isWindows),
        workingDirectory: paths.assistantDirectory,
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
    // The PC's state and the global shortcuts come through the runner (Windows only).
    final system = Platform.isWindows ? RunnerSystem() : null;
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
      agentClaude: agentClaude,
      agentSignInNotes: demoMode ? null : () => AgentConnections.signInNotesFile(environment, windows: Platform.isWindows),
      cloudTokens: demoMode ? MemoryCloudTokenVault() : platformCloudTokenVault(paths),
      agentDebug: environment['MOCHI_DESKTOP_AGENT'],
      brainSetup: brainSetup,
      opener: const SystemUrlOpener(),
      pc: systemPcActions(),
      folders: const SystemFolderOpener(),
      startup: startup,
      locateClaude: () {
        claude();
        return executable;
      },
      updater: updater,
      installer: installer,
      toasts: windows && system != null
          ? Win32Toasts(system: system, installed: () => installer.installed, executable: Platform.resolvedExecutable)
          : null,
      sound: Platform.isWindows ? Win32SoundOutput() : null,
      usage: system == null ? null : Win32Usage(system),
      hotkeys: system,
      jumpList: system,
      worldStore: demoMode ? null : FileWorldStore(paths.join(paths.home, 'world.json')),
      stores: demoMode ? null : (file) => FileJsonStore(paths.join(paths.home, file)),
      // Mischief's native stage is the Windows runner's.
      stage: Platform.isWindows,
      fullScreen: Platform.isWindows ? Win32Usage.fullScreenBusy : null,
      // Reacts to what you do (X7); `MOCHI_DESKTOP_REACTS=music|call|editor` forces a state for checks.
      media: systemMedia(),
      mic: systemMic(),
      foregroundApps: systemForegroundApp(),
      drops: Platform.isWindows && !demoMode ? RunnerDrops() : null,
      windowCapturer: systemWindowCapturer(),
      foregroundWindows: systemForegroundWindow(),
      screenshots: demoMode ? null : FolderScreenshotStore(paths.assistantDirectory),
      reactsForce: ReactsForce.from(environment['MOCHI_DESKTOP_REACTS']),
      // Windows ending the session puts back any window the nudges moved (X2).
      sessionEnding: system?.sessionEnding,
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

  /// Mochi's agent (W23a): Gmail, Google Calendar and Notion through your Claude connectors, told in the bubble, with the
  /// badge and on the phones.
  late final AgentController agent;

  /// `MOCHI_DESKTOP_AGENT=check|brief|connections` (development): runs that once, shortly after the start, whether or not the
  /// agent is on, and logs counts and outcomes only.
  final String? agentDebug;
  final Duration agentDebugAfter;
  Timer? _agentDebugTimer;

  /// The dot on Mochi and the tray: Claude's badge or the agent's, the higher of the two (the Mac's `MenuBarStatus.badge`).
  AttentionLevel? get badgeLevel {
    final claude = reactions.badge?.level, news = agent.badge;
    if (claude == null) return news;
    if (news == null) return claude;
    return claude.index >= news.index ? claude : news;
  }

  /// The last window you were using that isn't Mochi's (X17).
  late final ForegroundMemory foreground;

  final StreamController<void> _askWanted = StreamController.broadcast(sync: true);

  /// Something was dropped on Mochi: open Ask Mochi, where it is waiting.
  Stream<void> get askWanted => _askWanted.stream;

  void _dropped(DropPayload payload) {
    ask.draft.hovering = false;
    ask.draft.accept(payload);
    if (!_askWanted.isClosed) _askWanted.add(null);
  }

  /// Ask Mochi's step log: the console in a debug build, and the stroll-debug log (a `stroll-debug` file in Mochi's folder,
  /// checked at each line so the switch works without a restart) in any build. Lines carry no path, name, question,
  /// answer, link or copied text.
  void _askLog(String message) {
    if (kDebugMode) debugPrint('Mochi: $message');
    try {
      final folder = paths.home;
      if (!File('$folder${Platform.pathSeparator}stroll-debug').existsSync()) return;
      File('$folder${Platform.pathSeparator}stroll.log').writeAsStringSync('${DateTime.now().toIso8601String()} $message\n', mode: FileMode.append);
    } on Object {
      // Diagnostics only.
    }
  }

  /// Mochi's window or popover went away: a picture taken but not sent, and the drop notice, don't outlive the opening.
  void windowClosed() => ask.windowClosed();

  void _screenSwitch() => ask.peek?.settingsChanged();

  /// Mochi's window or popover is coming up: remember which window had the focus (X17). Called on that event only.
  void noteForeground() => foreground.note();

  /// Whether Mochi's own window has the focus now (null: it can't be told).
  bool? mochiFocused() => foreground.mochiFocused();

  /// How Mochi answers Claude's moments: animations, the badge, Windows notifications and sounds (Settings ›
  /// Notifications).
  late final Reactions reactions;
  late final MochiSounds sounds;

  /// Windows notifications.
  final ToastService toasts;

  /// The PC's rhythm: Mochi naps while it rests (Settings › Characters › Naps), and the phones hear only while you're
  /// away (Settings › Phones).
  late final PcRhythm rhythm;

  /// Mochi's world (the Mac's CompanionWorld): what Mochi and Patch do, friendship and achievements, speech and growing
  /// up.
  late final DesktopWorld world;

  /// The mini-games (W14): Catch the Treats and rock-paper-scissors, and their records.
  late final DesktopGames games;

  /// The focus buddy (W15): a Pomodoro timer Mochi naps through, and the blocks it kept for the recap.
  late final DesktopFocus focus;

  /// The daily recap (W16): the week of real events it counts, and the evening announcement.
  late final DesktopRecap recap;

  /// Days in a row with Claude Code on this PC: milestones get fireworks (X10).
  late final StreakWatch streaks;

  /// Press and hold Mochi to keep it purring (W21).
  late final PurrSession purr;

  /// Holidays (W20): the occasion showing, its greeting once, the treat, the candles and the taskbar's decoration.
  late final DesktopHolidays holidays;

  /// Decorating Mochi's room (W18): the furniture's tray, dragging, and what's selected.
  late final RoomEditor room;

  /// Mischief, the Windows extras (Settings › Mischief): whether each may run right now.
  late final MischiefGate mischief;

  /// Reacts to what you do (X7: music, calls, an editor coming to the front), read only while Mischief allows it.
  late final ReactsDirector reacts;

  /// The Start menu's jump list (X16; null where there is none), built once at startup for the installed copy.
  StartMenuJumpList? jumpList;

  /// The global shortcuts (Settings › Desktop Pet and Assistant).
  late final Hotkeys hotkeys;

  // Delivered as they come (a click on a notification and a shortcut arrive from Windows, never during a build).
  final StreamController<ToastTarget> _opens = StreamController.broadcast(sync: true);
  final StreamController<MochiShortcut> _shortcuts = StreamController.broadcast(sync: true);

  /// A Windows notification was clicked: open where it points.
  Stream<ToastTarget> get opens => _opens.stream;

  /// One of Mochi's shortcuts was pressed.
  Stream<MochiShortcut> get shortcuts => _shortcuts.stream;

  /// The primary session just before the event being applied (whether that event is about the session Mochi follows).
  String? _previousPrimary;

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
  final ClaudeRunner? Function() _agentClaude;
  final File Function()? _agentSignInNotes;
  final CloudTokenVault? _cloudTokens;
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

  /// One of this PC's own moments (petting, play and treats here or from a phone, Ask Mochi, updates): Mochi's world
  /// plays it, and the views hear about it.
  void cue(PetCue cue) {
    world.cue(cue);
    if (!_cues.isClosed) _cues.add(cue);
  }

  /// One of Claude's moments, as Reactions allowed it: the views hear about it (the world reacted to the event itself).
  void _claudeCue(PetCue cue) {
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
    agent.start();
    final debug = agentDebug;
    if (debug != null && const {'check', 'brief', 'connections'}.contains(debug)) {
      _agentDebugTimer = Timer(agentDebugAfter, () => unawaited(agent.debugRun(debug)));
    }
    _prune = Timer.periodic(const Duration(minutes: 1), (_) {
      sessions.prune();
      reactions.pruned();
    });
    _startUpdates();
    rhythm.start();
    world.start();
    mischief.start();
    reacts.start();
    recap.start();
    holidays.start();
    await toasts.start((target) {
      if (!_opens.isClosed) _opens.add(target);
    });
    settings.addListener(_shortcutsChanged);
    await hotkeys.start();
    // Once, quick and local (the runner does it on the UI thread); only the installed copy has a Start-menu entry.
    unawaited(jumpList?.buildOnce());
  }

  void _shortcutsChanged() => unawaited(hotkeys.apply());

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
    var delivered = 0;
    for (final line in drained.lines) {
      try {
        final event = EventValidator.decode(line);
        sessions.apply(event, delivery: Delivery.late);
        world.ingest(event, late: true);
        delivered++;
      } on WireRejection {
        // Too old or malformed: skip it.
      }
    }
    world.noteSpoolDrained(delivered: delivered, dropped: drained.dropped);
  }

  /// A hook event as the bridge delivers it (tests: the whole way, from the phones to Mochi's world).
  @visibleForTesting
  void receive(WireEvent event) => _live(event);

  void _live(WireEvent event) {
    phone.record(event);
    _previousPrimary = sessions.primary?.id;
    sessions.apply(event);
    _previousPrimary = null;
    world.ingest(event);
  }

  /// Every applied event: live ones get Mochi's reaction, as Settings › Notifications allows (late ones from the spool
  /// only update the badge).
  void _transition(SessionTransition transition) => reactions.handle(transition, previousPrimary: _previousPrimary);

  /// "Milestone" in the popover (the Mac's): a milestone you reached, recorded as a real event for the session Mochi
  /// follows, so it's celebrated (graduation the first time), notified as Settings › Notifications says, and shared.
  void markMilestone() {
    final now = sessions.now;
    final primary = sessions.primary;
    final event = WireEvent(
      id: 'manual-${now.microsecondsSinceEpoch}',
      ts: now.microsecondsSinceEpoch / 1e6,
      origin: WireOrigin.report,
      event: 'Report',
    )..report = const WireReport(kind: 'milestone', status: 'reached', label: 'Marked by you');
    if (primary != null && primary.isLive) {
      event
        ..session = primary.id
        ..project = primary.project
        ..projectKey = primary.projectKey;
    }
    _live(event);
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
    runExitHooks();
    final waiting = runExitTasks();
    if (waiting != null) await waiting;
    unawaited(_ending?.cancel());
    _prune?.cancel();
    _greeting?.cancel();
    updater.stop();
    _agentDebugTimer?.cancel();
    agent.dispose();
    phone.stop();
    settings.removeListener(_shortcutsChanged);
    settings.removeListener(_screenSwitch);
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _bridge.dispose();
    link.dispose();
    motion.dispose();
    games.dispose();
    purr.dispose();
    holidays.dispose();
    room.dispose();
    reacts.dispose();
    mischief.dispose();
    recap.dispose();
    streaks.dispose();
    focus.dispose();
    world.dispose();
    rhythm.dispose();
    hotkeys.dispose();
    toasts.dispose();
    await _cues.close();
    await _opens.close();
    await _shortcuts.close();
    await _askWanted.close();
  }
}
