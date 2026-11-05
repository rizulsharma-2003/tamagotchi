/// Coarse buckets for tool names (Swift `ToolCategoryClassifier`). Only the tool's name is used, never its input.
abstract final class ToolCategoryClassifier {
  static String category(String tool) => switch (tool) {
    'Read' || 'NotebookRead' || 'LS' => 'read',
    'Grep' || 'Glob' || 'ToolSearch' || 'LSP' => 'search',
    'Edit' || 'MultiEdit' || 'Write' || 'NotebookEdit' => 'edit',
    'Bash' || 'BashOutput' || 'KillShell' || 'KillBash' || 'PowerShell' || 'Monitor' => 'shell',
    'WebFetch' || 'WebSearch' => 'web',
    'Task' || 'Agent' || 'SendMessage' || 'TaskStop' || 'Workflow' => 'agent',
    'TodoWrite' || 'TaskCreate' || 'TaskUpdate' || 'TaskList' || 'EnterPlanMode' || 'ExitPlanMode' => 'plan',
    'AskUserQuestion' => 'ask',
    'Skill' || 'SlashCommand' => 'skill',
    _ => tool.startsWith('mcp__') ? 'mcp' : 'other',
  };
}

/// What [CommandClassifier] found in a shell command.
class CommandKindResult {
  const CommandKindResult(this.kind, {required this.reliable});

  /// "test", "build" or null.
  final String? kind;

  /// The command's exit status honestly reflects that build or test.
  final bool reliable;

  @override
  bool operator ==(Object other) => other is CommandKindResult && other.kind == kind && other.reliable == reliable;

  @override
  int get hashCode => Object.hash(kind, reliable);

  @override
  String toString() => 'CommandKindResult($kind, reliable: $reliable)';
}

enum _Separator { start, and, or, semicolon, pipe, background }

class _Segment {
  _Segment(this.separator, this.text);

  final _Separator separator;
  final String text;
}

/// Recognizes build and test commands in a Bash or PowerShell tool call without keeping the command text (Swift
/// `CommandClassifier`), plus the Windows spellings (`gradlew.bat`, `npm.cmd`, `.\build.ps1` is not guessed at).
abstract final class CommandClassifier {
  static CommandKindResult classify(String command) {
    final segments = _split(command);
    int? matchIndex;
    String? matchKind;
    for (var index = 0; index < segments.length; index++) {
      final kind = _kind(segments[index].text);
      if (kind == null) continue;
      // A test anywhere in the command wins over a build.
      if (matchKind == null || (kind == 'test' && matchKind == 'build')) {
        matchKind = kind;
        matchIndex = index;
      }
    }
    if (matchKind == null || matchIndex == null) return const CommandKindResult(null, reliable: false);
    // The exit status reflects the matched command only when it isn't piped or backgrounded and everything after it
    // is chained with `&&`.
    var reliable = true;
    for (final later in segments.skip(matchIndex + 1)) {
      if (later.separator != _Separator.and) reliable = false;
    }
    final own = segments[matchIndex].separator;
    if (own == _Separator.pipe || own == _Separator.background) reliable = false;
    if (command.contains('pipefail')) reliable = false;
    return CommandKindResult(matchKind, reliable: reliable);
  }

  /// Splits on top-level `&&`, `||`, `;`, `|`, `&` and newlines, ignoring quoted text.
  static List<_Segment> _split(String command) {
    final segments = <_Segment>[];
    final chars = command.runes.take(4096).map(String.fromCharCode).toList();
    var current = StringBuffer();
    var separator = _Separator.start;
    String? quote;
    void flush(_Separator next) {
      final trimmed = current.toString().trim();
      if (trimmed.isNotEmpty) segments.add(_Segment(separator, trimmed));
      current = StringBuffer();
      separator = next;
    }

    var i = 0;
    while (i < chars.length) {
      final c = chars[i];
      if (quote != null) {
        if (c == quote) quote = null;
        current.write(c);
        i++;
        continue;
      }
      final next = i + 1 < chars.length ? chars[i + 1] : null;
      switch (c) {
        case "'" || '"':
          quote = c;
          current.write(c);
        case '&' when next == '&':
          flush(_Separator.and);
          i++;
        case '|' when next == '|':
          flush(_Separator.or);
          i++;
        case '|':
          flush(_Separator.pipe);
        case '&':
          // `2>&1` and `&>` are redirections, not backgrounding.
          if ((i > 0 && chars[i - 1] == '>') || next == '>') {
            current.write(c);
          } else {
            final trimmed = current.toString().trim();
            if (trimmed.isNotEmpty) segments.add(_Segment(_Separator.background, trimmed));
            current = StringBuffer();
            separator = _Separator.semicolon;
          }
        case ';' || '\n':
          flush(_Separator.semicolon);
        default:
          current.write(c);
      }
      i++;
    }
    flush(_Separator.semicolon);
    return segments;
  }

  static const Set<String> _wrappers = {'env', 'time', 'command', 'nice', 'npx', 'bunx', 'xcrun', 'exec', 'caffeinate', 'nohup'};

  /// `C:\tools\gradlew.bat` → `gradlew`; `./node_modules/.bin/jest` → `jest`.
  static String _toolName(String raw) {
    var name = raw.split(RegExp(r'[\\/]')).last.toLowerCase();
    for (final suffix in const ['.exe', '.cmd', '.bat', '.ps1']) {
      if (name.endsWith(suffix)) name = name.substring(0, name.length - suffix.length);
    }
    return name;
  }

  static String? _kind(String segment) {
    final words = segment.split(RegExp(r'[ \t]+')).where((word) => word.isNotEmpty).toList();
    // Drop leading environment assignments and wrapper commands.
    while (words.isNotEmpty) {
      final first = words.first;
      final letter = first.isNotEmpty && RegExp(r'[A-Za-z]').hasMatch(first[0]);
      if (first.contains('=') && !first.startsWith('-') && letter) {
        words.removeAt(0);
      } else if (_wrappers.contains(first) || first == 'sudo') {
        words.removeAt(0);
        while (words.isNotEmpty && words.first.startsWith('-')) {
          words.removeAt(0);
        }
      } else {
        break;
      }
    }
    if (words.isEmpty) return null;
    final tool = _toolName(words.first);
    final args = words.skip(1).where((word) => !word.startsWith('-')).toList();
    final firstArg = args.isEmpty ? '' : args.first;

    switch (tool) {
      case 'swift':
        if (firstArg == 'test') return 'test';
        if (firstArg == 'build') return 'build';
      case 'xcodebuild':
        if (args.contains('test') || args.contains('test-without-building')) return 'test';
        if (args.isEmpty || args.contains('build') || args.contains('archive') || args.contains('build-for-testing')) return 'build';
      case 'npm' || 'yarn' || 'pnpm' || 'bun':
        if (firstArg == 'test' || firstArg == 't') return 'test';
        if (firstArg == 'build') return 'build';
        if ((firstArg == 'run' || firstArg == 'exec') && args.length > 1) {
          final script = args[1];
          if (script.startsWith('test')) return 'test';
          if (script.startsWith('build')) return 'build';
        }
      case 'pytest' || 'jest' || 'vitest' || 'mocha' || 'rspec' || 'phpunit' || 'ctest' || 'tox' || 'nox':
        return 'test';
      case 'python' || 'python3' || 'py':
        if (words.contains('pytest') || words.contains('unittest')) return 'test';
      case 'go' || 'cargo' || 'dotnet' || 'bazel' || 'deno' || 'dart' || 'flutter' || 'mix' || 'tuist':
        if (firstArg == 'test' || firstArg == 'nextest') return 'test';
        if (firstArg == 'build') return 'build';
      case 'mvn' || 'mvnw':
        if (args.contains('test') || args.contains('verify')) return 'test';
        if (args.contains('package') || args.contains('install') || args.contains('compile')) return 'build';
      case 'gradle' || 'gradlew':
        if (args.any((arg) => arg == 'test' || arg == 'check' || arg.endsWith(':test'))) return 'test';
        if (args.any((arg) => arg == 'build' || arg == 'assemble' || arg.startsWith('assemble'))) return 'build';
      case 'msbuild':
        return 'build';
      case 'make' || 'gmake':
        if (firstArg == 'test' || firstArg == 'check') return 'test';
        if (args.isEmpty || firstArg == 'build' || firstArg == 'all') return 'build';
      case 'cmake':
        if (words.contains('--build')) return 'build';
      case 'tsc' || 'webpack':
        return 'build';
      case 'vite' || 'next' || 'nuxt' || 'astro':
        if (firstArg == 'build') return 'build';
      case 'bundle':
        if (args.isNotEmpty && args.first == 'exec' && args.length > 1 && args[1] == 'rspec') return 'test';
      case 'rake':
        if (firstArg == 'test' || firstArg == 'spec') return 'test';
    }
    return null;
  }
}
