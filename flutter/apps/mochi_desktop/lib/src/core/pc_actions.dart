// What Ask Mochi may do on this PC (docs/SPRINT_2.md W9, docs/W9_SAFETY_REVIEW.md): the Dart port of the Mac's
// MacActions.swift. Open an installed app or switch to it, list the programs on the taskbar, bring a window forward,
// press music keys, change the volume, and start one of the user's own Task Scheduler tasks.
//
// The rules that hold here (the Settings switch and the five-per-request limit are in ask_mochi.dart and ask_brain.dart):
// - Window titles are matched on this PC and never leave it: no result text, step line or log carries a title.
//   `list_apps` and `focus_window` say program names only ("Visual Studio Code"), never what a window is called.
// - The brain's words only ever choose among things Mochi found itself: an app from the Start menu's list (the runner
//   launches it by the id it listed), a window from the taskbar's list, one of the three music keys, a volume, a task of the
//   user's `\Mochi\` folder by its exact name. Nothing is typed, clicked or closed; no path or command line is ever built
//   from them.
// - Volume stays between 0 and 100.
//
// Native calls are behind [PcPlatform] (lib/src/platform/pc_platform.dart on Windows, a fake in the tests).

import 'dart:math' as math;

import 'quick_commands.dart';

/// What an action says, in words, and whether it worked.
class PcResult {
  const PcResult(this.text, {this.ok = true});

  final String text;
  final bool ok;
}

/// An app in the Start menu: its name, and the id the runner launches it by (only for [PcPlatform.launch]).
class PcApp {
  const PcApp(this.name, this.id);

  final String name;
  final String id;
}

/// A window on the taskbar. The title is read only to be matched here; it is never put in a result.
class PcWindow {
  const PcWindow({required this.hwnd, required this.program, required this.title});

  final int hwnd;

  /// The program's name ("Google Chrome").
  final String program;
  final String title;
}

enum PcTaskState { ok, noFolder, failed }

class PcTasks {
  const PcTasks(this.state, [this.names = const []]);

  final PcTaskState state;
  final List<String> names;
}

enum PcTaskRun { started, noFolder, notFound, failed }

/// The native side. Every method answers, never throws.
abstract interface class PcPlatform {
  /// The windows an Alt+Tab would list (minimised ones too), front to back, Mochi's own and the shell's left out.
  List<PcWindow> windows();

  /// Restores [hwnd] if it is minimised and brings it to the front. False when Windows would not.
  bool raise(int hwnd);

  /// The Start menu's apps (null: they could not be read).
  Future<List<PcApp>?> apps();

  /// Opens the app with this id (an id from [apps], nothing else).
  Future<bool> launch(String id);

  /// `playPause`, `next` or `previous`.
  Future<bool> mediaKey(String key);

  /// The default output's level, 0 to 1 (null: it can't be read).
  Future<double?> volume();

  Future<bool> setVolume(double level);

  Future<bool> setMuted(bool muted);

  /// The names of the tasks in the user's `\Mochi\` folder, and nothing else.
  Future<PcTasks> tasks();

  /// Starts the task with exactly this name in `\Mochi\`; it doesn't wait for it to finish.
  Future<PcTaskRun> runTask(String name);
}

/// Nothing (the macOS development build).
class NoPcPlatform implements PcPlatform {
  const NoPcPlatform();

  @override
  List<PcWindow> windows() => const [];

  @override
  bool raise(int hwnd) => false;

  @override
  Future<List<PcApp>?> apps() async => null;

  @override
  Future<bool> launch(String id) async => false;

  @override
  Future<bool> mediaKey(String key) async => false;

  @override
  Future<double?> volume() async => null;

  @override
  Future<bool> setVolume(double level) async => false;

  @override
  Future<bool> setMuted(bool muted) async => false;

  @override
  Future<PcTasks> tasks() async => const PcTasks(PcTaskState.failed);

  @override
  Future<PcTaskRun> runTask(String name) async => PcTaskRun.failed;
}

/// What Ask Mochi can do on the PC; the brain's tools and the quick commands both call it.
abstract interface class PcActions {
  /// The Start menu's app names (cached for a minute), for the quick commands' matching.
  Future<List<String>> installedNames();

  /// The names of the programs with taskbar windows now.
  List<String> runningNames();

  Future<PcResult> openApp(String name);

  PcResult listApps();

  Future<PcResult> focusWindow({String? app, String? title});

  /// [key]: `playPause`, `next` or `previous`.
  Future<PcResult> media(String key);

  /// A level 0 to 100, or [change]: up, down, mute or unmute (up when it is anything else).
  Future<PcResult> volume({int? level, String? change});

  Future<PcResult> runTask(String name);

  Future<PcResult> listTasks();
}

/// The matching and arithmetic, with no native calls (the Mac's `tokens`, `bestWindow` and volume steps).
abstract final class PcMatch {
  static const Set<String> _skipped = {'the', 'my', 'window', 'app', 'a'};

  /// Lowercased words of [text] (letters and digits), without the filler words.
  static List<String> tokens(String text) => [
    for (final word in text.toLowerCase().split(RegExp(r'[^\p{L}\p{N}]', unicode: true)))
      if (word.isNotEmpty && !_skipped.contains(word)) word,
  ];

  /// How many of [wanted] a title has: a word it contains, or one inside its words run together ("vs" in "vscode").
  static int score(List<String> wanted, String title) {
    final have = tokens(title);
    final squashed = have.join();
    return wanted.where((token) => have.contains(token) || squashed.contains(token)).length;
  }

  /// The window whose title matches [query] best: all its words, or all but one of three or more. The first of equals
  /// wins (the one in front). Null when none matches.
  static PcWindow? bestWindow(String query, Iterable<PcWindow> windows) {
    final wanted = tokens(query);
    if (wanted.isEmpty) return null;
    PcWindow? best;
    var bestScore = 0;
    for (final window in windows) {
      if (window.title.isEmpty) continue;
      final score = PcMatch.score(wanted, window.title);
      if ((score == wanted.length || (wanted.length >= 3 && score >= wanted.length - 1)) && score > bestScore) {
        best = window;
        bestScore = score;
      }
    }
    return best;
  }

  /// Whether a Start menu entry is something to open: not an uninstaller, installer or repair tool by name, and not a
  /// script or installer by what it starts. (The runner applies the same rule before it lists; this is the second check.)
  static bool openable(String name, {String id = ''}) {
    final lowered = name.toLowerCase();
    for (final word in const ['uninstall', 'setup', 'installer', 'repair', 'reset', 'remove']) {
      if (lowered.contains(word)) return false;
    }
    final target = id.toLowerCase();
    for (final end in const ['.bat', '.cmd', '.ps1', '.vbs', '.js', '.wsf', '.hta', '.msi', '.reg']) {
      if (target.endsWith(end)) return false;
    }
    return true;
  }

  /// A level for the volume: 0 to 100.
  static int clampLevel(int level) => level.clamp(0, 100);

  /// The level one step of [change] reaches from [current] (0 to 1): the Mac's plus or minus 10 points.
  static double step(String? change, double current) => switch (change) {
    'down' => math.max(0, current - 0.1),
    _ => math.min(1, current + 0.1),
  };

  /// A task name that is only a name: no folder or path part, nothing that walks out of `\Mochi\`.
  static bool plainTaskName(String name) {
    if (name.trim().isEmpty || name.length > 256 || name == '.' || name == '..') return false;
    return !name.contains(RegExp(r'[\\/\x00-\x1f]'));
  }

  /// [name] as the brain wrote it, cut to a length that fits a sentence.
  static String clip(String name) {
    final trimmed = name.trim();
    return trimmed.length > 40 ? '${trimmed.substring(0, 39)}…' : trimmed;
  }
}

/// The real thing: [PcMatch] and the Mac's logic over a [PcPlatform].
class PcActionsImpl implements PcActions {
  PcActionsImpl(this.platform, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final PcPlatform platform;
  final DateTime Function() _clock;

  List<PcApp> _installed = const [];
  DateTime? _installedAt;

  /// The most task names `list_tasks` lists.
  static const int mostTasks = 60;

  /// How long the app list is kept, as on the Mac.
  static const Duration appsKept = Duration(seconds: 60);

  /// Where to make the task folder, in words.
  static const String howToMakeTheFolder =
      'There is no Mochi folder in Task Scheduler yet. To let me run your tasks: open Task Scheduler, create a folder called '
      'Mochi and put the tasks you want me to run in it.';

  Future<List<PcApp>> _apps() async {
    final at = _installedAt;
    if (at != null && _clock().difference(at) < appsKept) return _installed;
    final found = await platform.apps();
    if (found == null) return _installed;
    _installed = [
      for (final app in found)
        if (app.name.isNotEmpty && PcMatch.openable(app.name, id: app.id)) app,
    ];
    _installedAt = _clock();
    return _installed;
  }

  @override
  Future<List<String>> installedNames() async => [for (final app in await _apps()) app.name];

  @override
  List<String> runningNames() {
    final names = <String>{for (final window in platform.windows()) window.program};
    return names.toList();
  }

  /// The running program a spoken name refers to, and its windows front to back.
  ({String program, List<PcWindow> windows})? _running(String name) {
    final windows = platform.windows();
    final program = QuickCommands.matchApp(QuickCommands.normalize(name), {for (final window in windows) window.program}.toList());
    if (program == null) return null;
    return (program: program, windows: [for (final window in windows) if (window.program == program) window]);
  }

  bool _bringForward(List<PcWindow> windows) {
    if (windows.isEmpty) return false;
    return platform.raise(windows.first.hwnd);
  }

  @override
  Future<PcResult> openApp(String name) async {
    final running = _running(name);
    if (running != null) return _switchedTo(running.program, running.windows);
    final apps = await _apps();
    final match = QuickCommands.matchApp(QuickCommands.normalize(name), [for (final app in apps) app.name]);
    final app = match == null ? null : apps.firstWhere((candidate) => candidate.name == match);
    if (app == null) return PcResult('I couldn\'t find an app called “${PcMatch.clip(name)}”.', ok: false);
    if (!await platform.launch(app.id)) return PcResult('I couldn\'t open ${app.name}.', ok: false);
    return PcResult('Opening ${app.name}.');
  }

  PcResult _switchedTo(String program, List<PcWindow> windows) => _bringForward(windows)
      ? PcResult('Switched to $program.')
      : PcResult('$program is open, but Windows wouldn\'t bring it forward.', ok: false);

  @override
  PcResult listApps() {
    final names = runningNames()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return PcResult(names.isEmpty ? 'No apps with windows are open.' : 'Running: ${names.join(', ')}');
  }

  @override
  Future<PcResult> focusWindow({String? app, String? title}) async {
    final appName = app == null || app.trim().isEmpty ? null : app;
    final running = appName == null ? null : _running(appName);
    final noTitle = title == null || title.trim().isEmpty;
    if (appName != null && running == null && noTitle) return openApp(appName);
    if (noTitle) {
      if (running == null) return const PcResult('Which window should I look for?', ok: false);
      return _switchedTo(running.program, running.windows);
    }
    final found = PcMatch.bestWindow(title, running?.windows ?? platform.windows());
    if (found == null) {
      if (running != null) {
        return _bringForward(running.windows)
            ? PcResult('Switched to ${running.program}, but no window matched.')
            : PcResult('${running.program} is open, but no window matched.', ok: false);
      }
      return const PcResult('I couldn\'t find a matching window.', ok: false);
    }
    return platform.raise(found.hwnd)
        ? PcResult('Here\'s ${found.program}.')
        : const PcResult('I found it, but Windows wouldn\'t bring it forward.', ok: false);
  }

  @override
  Future<PcResult> media(String key) async {
    final pressed = await platform.mediaKey(key);
    if (!pressed) return const PcResult('I couldn\'t press that music key.', ok: false);
    return PcResult(switch (key) {
      'next' => 'Skipped ahead.',
      'previous' => 'Went back a track.',
      _ => 'Pressed play/pause.',
    });
  }

  @override
  Future<PcResult> volume({int? level, String? change}) async {
    const stuck = PcResult('This PC\'s volume can\'t be changed.', ok: false);
    if (level == null) {
      if (change == 'mute') {
        return await platform.setMuted(true) ? const PcResult('Muted.') : const PcResult('This output can\'t be muted.', ok: false);
      }
      if (change == 'unmute') {
        return await platform.setMuted(false)
            ? const PcResult('Sound\'s back on.')
            : const PcResult('This output can\'t be unmuted.', ok: false);
      }
    }
    final double target;
    if (level != null) {
      target = PcMatch.clampLevel(level) / 100;
    } else {
      final current = await platform.volume();
      if (current == null) return stuck;
      target = PcMatch.step(change, current);
    }
    // Sound above nothing is sound on.
    if (target > 0) await platform.setMuted(false);
    if (!await platform.setVolume(target)) return stuck;
    return PcResult('Volume ${(target * 100).round()}%.');
  }

  @override
  Future<PcResult> runTask(String name) async {
    if (name.trim().isEmpty) return const PcResult('Which task should I run?', ok: false);
    if (!PcMatch.plainTaskName(name)) {
      return const PcResult('I only run tasks by their name from your Mochi folder, not from another folder or a path.', ok: false);
    }
    switch (await platform.runTask(name)) {
      case PcTaskRun.started:
        return PcResult('Started “${PcMatch.clip(name)}”.');
      case PcTaskRun.noFolder:
        return const PcResult(howToMakeTheFolder, ok: false);
      case PcTaskRun.notFound:
        return PcResult('There is no task called “${PcMatch.clip(name)}” in your Mochi folder.', ok: false);
      case PcTaskRun.failed:
        return PcResult('The task “${PcMatch.clip(name)}” didn\'t start.', ok: false);
    }
  }

  @override
  Future<PcResult> listTasks() async {
    final tasks = await platform.tasks();
    switch (tasks.state) {
      case PcTaskState.noFolder:
        return const PcResult(howToMakeTheFolder);
      case PcTaskState.failed:
        return const PcResult('I couldn\'t reach Task Scheduler.', ok: false);
      case PcTaskState.ok:
        if (tasks.names.isEmpty) return const PcResult('There are no tasks in your Mochi folder yet.');
        final names = [...tasks.names]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        return PcResult(names.take(mostTasks).join(', '));
    }
  }
}
