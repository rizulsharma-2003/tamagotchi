// W11 fresh lines (docs/SPRINT_2.md, docs/MOCHI_WORLD.md): now and then Mochi and Patch say a line written for the
// moment instead of one of the hand-written ones. The Mac writes them with Apple Intelligence; here Claude Haiku writes
// them through Claude Code on this PC (`claude -p`, as the turn summaries do), with the Mac's prompt for each moment.
// Only the kind of moment is sent ("Claude just finished a task", "The user is petting the cat"), never a project, a
// file, a command or anything you typed. Settings › Fun › "Fresh lines from Claude Haiku" turns it on (off by default:
// it uses your Claude Code); Mochi's world asks every two hours while it's on, keeps three lines per moment and uses
// one about half the time.
//
// One request covers every moment asked for (the Mac asks its on-device model once per moment; here that would start
// Claude Code a dozen times).

import 'dart:convert';

import 'package:mochi_world/mochi_world.dart';

import 'claude_cli.dart';
import 'turn_summaries.dart' show TurnSummarizer;

class HaikuLineWriter {
  HaikuLineWriter(this._runner);

  /// Claude Code on this PC (null when it isn't found).
  final ClaudeRunner? Function() _runner;

  /// Where Mochi lives here, for its persona.
  static const String home = 'the Windows taskbar';

  /// `claude -p` with Haiku, no tools, no settings or sessions of its own, and [system] as the system prompt.
  static List<String> arguments(String system) => [
    '-p',
    '--model',
    'haiku',
    '--output-format',
    'json',
    '--setting-sources',
    'project',
    '--tools',
    '',
    '--strict-mcp-config',
    '--no-session-persistence',
    '--system-prompt',
    system,
  ];

  /// The system prompt: both voices, from the Mac's prompt for each (one line: `claude.cmd` runs through cmd.exe).
  static String system({required String petName, required String companionName}) {
    final pet = FreshLinePrompt(SpeechOccasion.petted, petName: petName, companionName: companionName, home: home);
    final patch = FreshLinePrompt(SpeechOccasion.promptSubmitted, petName: petName, companionName: companionName, home: home);
    return 'You write lines for two characters. Voice "pet": ${pet.instructions} Voice "companion": ${patch.instructions} '
        'For each moment you are given, write the line its voice says. Reply with JSON only, no code fence: an object whose '
        'keys are the moment ids and whose values are the lines.';
  }

  /// The request: each moment's id, who speaks and what happened (the Mac's prompt), one per line.
  static String request(List<SpeechOccasion> occasions, {required String petName, required String companionName}) => [
    for (final occasion in occasions)
      '- ${occasion.name} (voice "${SpeechLines.speaker(occasion).name}"): '
          '${FreshLinePrompt(occasion, petName: petName, companionName: companionName, home: home).prompt}',
  ].join('\n');

  /// The lines in the model's reply (each cleaned up as the Mac does; unusable ones are left out).
  static Map<SpeechOccasion, List<SpeechLine>> parse(String text, List<SpeechOccasion> asked) {
    final start = text.indexOf('{'), end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return const {};
    Object? json;
    try {
      json = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      return const {};
    }
    if (json is! Map) return const {};
    final lines = <SpeechOccasion, List<SpeechLine>>{};
    for (final occasion in asked) {
      final raw = json[occasion.name];
      final clean = raw is String ? SpeechLines.sanitize(raw) : null;
      if (clean != null) lines[occasion] = [SpeechLine(SpeechLines.speaker(occasion), clean)];
    }
    return lines;
  }

  /// The world's [FreshLineWriter].
  Future<Map<SpeechOccasion, List<SpeechLine>>> call(
    List<SpeechOccasion> occasions, {
    required String petName,
    required String companionName,
  }) async {
    final runner = _runner();
    if (runner == null || occasions.isEmpty) return const {};
    final run = await runner.run(
      arguments(system(petName: petName, companionName: companionName)),
      input: request(occasions, petName: petName, companionName: companionName),
      timeout: const Duration(seconds: 60),
    );
    if (!run.ok) return const {};
    final result = TurnSummarizer.result(run.output);
    return result == null ? const {} : parse(result, occasions);
  }
}
