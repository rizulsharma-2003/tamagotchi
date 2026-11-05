// Finding and running the Claude Code CLI (`claude`), for Ask Mochi and turn summaries: the Dart counterpart of
// TamagotchiCore's ClaudeCodeLocator and the App's BrainSession/TurnSummaryRunner process handling.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Finds the installed Claude Code CLI. Apps started from the Start menu or Finder don't get the shell's PATH, so the
/// usual install locations are checked as well as PATH.
abstract final class ClaudeLocator {
  /// `MOCHI_CLAUDE_BIN` pins the CLI (pointing at nothing, it simulates "not installed").
  static const String pinKey = 'MOCHI_CLAUDE_BIN';

  static List<String> candidates(Map<String, String> environment, {required bool windows}) {
    final paths = <String>[];
    if (windows) {
      final profile = environment['USERPROFILE'] ?? '';
      final appData = environment['APPDATA'] ?? '$profile\\AppData\\Roaming';
      final local = environment['LOCALAPPDATA'] ?? '$profile\\AppData\\Local';
      paths.addAll([
        // The native installer (`irm https://claude.ai/install.ps1 | iex`).
        '$profile\\.local\\bin\\claude.exe',
        '$local\\Programs\\claude\\claude.exe',
        // npm's global shim.
        '$appData\\npm\\claude.cmd',
      ]);
      final extensions = (environment['PATHEXT'] ?? '.EXE;.CMD;.BAT').toLowerCase().split(';').where((e) => e.isNotEmpty).toList();
      for (final directory in (environment['PATH'] ?? environment['Path'] ?? '').split(';')) {
        if (directory.trim().isEmpty) continue;
        for (final extension in ['.exe', ...extensions.where((e) => e != '.exe')]) {
          paths.add('${directory.trim()}\\claude$extension');
        }
      }
    } else {
      final home = environment['HOME'] ?? '';
      paths.addAll([
        '$home/.local/bin/claude',
        '$home/.claude/local/claude',
        '/opt/homebrew/bin/claude',
        '/usr/local/bin/claude',
        '$home/.npm-global/bin/claude',
        '$home/.bun/bin/claude',
        '$home/.volta/bin/claude',
      ]);
      for (final directory in (environment['PATH'] ?? '').split(':')) {
        if (directory.isNotEmpty) paths.add('$directory/claude');
      }
    }
    final seen = <String>{};
    return paths.where((path) => seen.add(windows ? path.toLowerCase() : path)).toList();
  }

  static String? locate({Map<String, String>? environment, bool? windows, bool Function(String path)? exists}) {
    final env = environment ?? Platform.environment;
    final isWindows = windows ?? Platform.isWindows;
    final present = exists ?? (path) => File(path).existsSync();
    final pinned = env[pinKey];
    if (pinned != null && pinned.isNotEmpty) return present(pinned) ? pinned : null;
    for (final path in candidates(env, windows: isWindows)) {
      if (present(path)) return path;
    }
    return null;
  }

  /// The app's environment minus anything that would tie a helper run to another Claude session (when the app itself
  /// was started from one), with a PATH that finds the usual tools (Swift `BrainSession.environment()`).
  static Map<String, String> cleanEnvironment(Map<String, String> environment, {required bool windows}) {
    final clean = Map<String, String>.of(environment)
      ..removeWhere(
        (key, _) =>
            key.startsWith('CLAUDE') ||
            key.startsWith('MOCHI_') ||
            key.startsWith('VSCODE_') ||
            key == '__CFBundleIdentifier' ||
            key == 'TERM_PROGRAM',
      );
    if (!windows) {
      final home = environment['HOME'] ?? '';
      clean['PATH'] = ['$home/.local/bin', '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':');
    }
    clean['NO_COLOR'] = '1';
    return clean;
  }
}

/// How one `claude` run ended.
class ClaudeRun {
  const ClaudeRun({required this.exitCode, required this.output, this.errorTail = '', this.timedOut = false});

  final int exitCode;

  /// Everything it wrote to stdout.
  final String output;

  /// The last part of stderr, for telling "please log in" from a crash. Never shown raw.
  final String errorTail;
  final bool timedOut;

  bool get ok => exitCode == 0 && !timedOut;
}

/// Runs the Claude Code CLI once: arguments, the prompt on stdin, stdout back. Tests pass their own.
abstract interface class ClaudeRunner {
  Future<ClaudeRun> run(List<String> arguments, {required String input, Duration timeout});
}

/// The real one: a child process in a private, empty working folder with a cleaned environment.
class ProcessClaudeRunner implements ClaudeRunner {
  ProcessClaudeRunner({required this.executable, required this.workingDirectory, required this.environment});

  final String executable;
  final String workingDirectory;
  final Map<String, String> environment;

  /// npm's `claude.cmd` shim needs cmd.exe; the native `claude.exe` runs directly, with Dart quoting each argument.
  bool get _viaShell {
    final lower = executable.toLowerCase();
    return lower.endsWith('.cmd') || lower.endsWith('.bat');
  }

  @override
  Future<ClaudeRun> run(List<String> arguments, {required String input, Duration timeout = const Duration(seconds: 90)}) async {
    Directory(workingDirectory).createSync(recursive: true);
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: _viaShell,
    );
    final out = StringBuffer();
    final err = StringBuffer();
    final reading = Future.wait([
      process.stdout.transform(utf8.decoder).forEach((chunk) {
        if (out.length < 1 << 20) out.write(chunk);
      }),
      process.stderr.transform(utf8.decoder).forEach((chunk) {
        err.write(chunk);
        if (err.length > 4000) {
          final text = err.toString();
          err
            ..clear()
            ..write(text.substring(text.length - 2000));
        }
      }),
    ]);
    try {
      process.stdin.write(input);
      await process.stdin.close();
    } on Object {
      // It may have exited already; its exit code says why.
    }
    var timedOut = false;
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        process.kill();
        return -1;
      },
    );
    await reading.timeout(const Duration(seconds: 2), onTimeout: () => const []);
    final tail = err.toString();
    return ClaudeRun(
      exitCode: code,
      output: out.toString(),
      errorTail: tail.length > 600 ? tail.substring(tail.length - 600) : tail,
      timedOut: timedOut,
    );
  }
}
