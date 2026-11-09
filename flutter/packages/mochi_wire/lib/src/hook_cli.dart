import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'bridge.dart';
import 'bridge_paths.dart';
import 'event_spool.dart';
import 'hook_sanitizer.dart';
import 'wire_event.dart';
import 'wire_text.dart';

/// `mochi_hook`, the helper Claude Code runs as a hook command (Swift `mactamagotchi-hook`):
///
///     mochi_hook claude-hook [EventName]   reads the hook's JSON on stdin and passes a sanitized summary to the app
///     mochi_hook report <build|test|milestone|commit> <passed|failed|reached> [--label TEXT]
///     mochi_hook ping                      is the app listening?
///     mochi_hook paws                      (started by Mochi itself: PawsRelay, in bin/mochi_hook.dart)
///     mochi_hook --version
///
/// `claude-hook` never writes to stdout and always exits 0, so it can neither block Claude Code nor put anything into
/// Claude's context; when the app isn't running the event goes to the spool (without Claude's words).
class HookCli {
  HookCli({
    required this.environment,
    required this.stdinBytes,
    required this.out,
    required this.err,
    BridgePaths? paths,
    this.stdinIsTerminal = false,
    DateTime Function()? clock,
  }) : paths = paths ?? BridgePaths.resolve(environment: environment),
       _clock = clock ?? DateTime.now;

  final Map<String, String> environment;

  /// The hook's input (read lazily: only `claude-hook` reads it).
  final Stream<List<int>> stdinBytes;
  final bool stdinIsTerminal;
  final StringSink out;
  final StringSink err;
  final BridgePaths paths;
  final DateTime Function() _clock;

  /// What the last delivery did (for tests).
  BridgeOutcome? lastOutcome;

  Future<int> run(List<String> arguments) async {
    switch (arguments.isEmpty ? null : arguments.first) {
      case HelperInfo.hookSubcommand:
        await claudeHook(arguments.length > 1 ? arguments[1] : null);
        return 0;
      case 'report':
        return report(arguments.sublist(1));
      case 'ping':
        return ping();
      case '--version' || 'version':
        out.writeln('${HelperInfo.executableName} ${HelperInfo.version}');
        return 0;
      default:
        out.writeln(
          '${HelperInfo.executableName} ${HelperInfo.version}\n\n'
          'usage:\n'
          '  ${HelperInfo.executableName} claude-hook [EventName]     (used by Claude Code hooks; reads stdin)\n'
          '  ${HelperInfo.executableName} report <build|test|milestone|commit> <passed|failed|reached> [--label TEXT]\n'
          '  ${HelperInfo.executableName} ping',
        );
        return 0;
    }
  }

  Future<void> claudeHook(String? argumentEvent) async {
    final raw = await _readInput(HookPayloadSanitizer.maxParsedBytes + 1);
    final event = HookPayloadSanitizer.sanitize(
      raw,
      argumentEvent: argumentEvent,
      environment: environment,
      includeSummary: File(paths.summariesFlagFile).existsSync(),
      now: _clock(),
    );
    await deliver(event);
  }

  /// Sends [event] to the app; when nothing listens, keeps it in the spool without Claude's words.
  Future<BridgeOutcome> deliver(WireEvent event) async {
    final outcome = await BridgeClient.send(event.encodeLine(), paths.bridgeFile);
    lastOutcome = outcome;
    if (outcome is BridgeUnavailable && event.origin != WireOrigin.ping) {
      EventSpool.append(event.withoutSummary.encodeLine(), paths.spoolFile);
    }
    return outcome;
  }

  Future<int> report(List<String> args) async {
    if (args.length < 2 || !WireReport.kinds.contains(args[0]) || !WireReport.statuses.contains(args[1])) {
      err.writeln('usage: ${HelperInfo.executableName} report <build|test|milestone|commit> <passed|failed|reached> [--label TEXT]');
      return 64;
    }
    String? value(String flag) {
      final index = args.indexOf(flag);
      return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
    }

    final now = _clock();
    final event = WireEvent(id: 'report-${_uuid()}', ts: now.microsecondsSinceEpoch / 1e6, origin: WireOrigin.report, event: 'Report')
      ..report = WireReport(kind: args[0], status: args[1], label: WireText.clean(value('--label'), maxLength: 60))
      ..helperVersion = HelperInfo.version;
    // Commands Claude Code runs inherit its session id, so their reports attach to that session.
    event.session = WireText.identifier(
      value('--session') ?? environment['CLAUDE_CODE_SESSION_ID'] ?? environment['CLAUDE_SESSION_ID'],
      maxLength: 128,
    );
    final projectDirectory = environment['CLAUDE_PROJECT_DIR'];
    final path = projectDirectory != null && projectDirectory.isNotEmpty ? projectDirectory : Directory.current.path;
    event.project = WireText.clean(value('--project'), maxLength: 48) ?? ProjectIdentity.displayName(path);
    event.projectKey = ProjectIdentity.key(path);
    event.projectPath = WirePath.standardize(path);
    final outcome = await deliver(event);
    switch (outcome) {
      case BridgeAccepted():
        break;
      case BridgeRejected(:final reason):
        err.writeln('mochi: report not accepted ($reason)');
      case BridgeUnavailable():
        err.writeln('mochi: the app is not running; the report was saved and will show as late');
    }
    // Never change the exit status of the user's script.
    return 0;
  }

  Future<int> ping() async {
    final event = WireEvent(id: 'ping-${_uuid()}', ts: _clock().microsecondsSinceEpoch / 1e6, origin: WireOrigin.ping, event: 'Ping')
      ..helperVersion = HelperInfo.version;
    final outcome = await deliver(event);
    switch (outcome) {
      case BridgeAccepted():
        out.writeln('Mochi is listening (${paths.bridgeFile})');
        return 0;
      case BridgeRejected(:final reason):
        out.writeln('Mochi answered but refused the ping: $reason');
        return 1;
      case BridgeUnavailable(:final reason):
        out.writeln('Mochi is not reachable: $reason');
        return 1;
    }
  }

  /// Reads stdin up to [limit] bytes but keeps draining past it, so Claude Code is never left blocked writing.
  Future<List<int>> _readInput(int limit) async {
    if (stdinIsTerminal) return const [];
    final data = BytesBuilder(copy: false);
    await for (final chunk in stdinBytes) {
      if (data.length < limit) data.add(chunk.length + data.length > limit ? chunk.sublist(0, limit - data.length) : chunk);
    }
    return data.takeBytes();
  }

  static String _uuid() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
